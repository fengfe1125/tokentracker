"""Temporary SQLite fixtures only: token accounting and reversible upgrades."""
import glob
from contextlib import closing
import os
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from tokentracker import db


OLD_SCHEMA = """
CREATE TABLE usage_events (
 id INTEGER PRIMARY KEY, tool TEXT NOT NULL, session_id TEXT DEFAULT '',
 project TEXT DEFAULT '', ts INTEGER NOT NULL, model TEXT DEFAULT '',
 input INTEGER DEFAULT 0, output INTEGER DEFAULT 0, cache_read INTEGER DEFAULT 0,
 cache_write INTEGER DEFAULT 0, cost REAL, src_key TEXT NOT NULL, UNIQUE(tool,src_key));
CREATE TABLE scan_state(tool TEXT PRIMARY KEY, cursor TEXT);
"""


class DatabaseAccountingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "usage.db")

    def connect(self):
        conn = db.connect(self.path)
        self.addCleanup(conn.close)
        return conn

    def test_four_classes_sum_inside_each_row(self):
        conn = self.connect()
        db.put_event(conn, "t", "a", session_id="s", input=100, output=20, cache_read=30, cache_write=10)
        db.put_event(conn, "t", "b", session_id="s", input=100, output=20, cache_read=50, cache_write=10)
        self.assertEqual(db.window_usage(conn, 0, include_cache=True), 340)
        self.assertEqual(db.quota_usage(conn, "all", include_cache=True)[0], 340)
        self.assertEqual(db.stats(conn)[1]["tokens"], 340)
        self.assertEqual(db.models(conn)[0]["tokens"], 340)
        self.assertEqual(db.sessions(conn)[0]["tokens"], 340)
        self.assertEqual(db.session_detail(conn, "t", "s")["tokens"], 340)
        self.assertEqual(db.daily(conn)[0]["tokens"], 340)

    def old_database(self, fail=False):
        conn = sqlite3.connect(self.path)
        conn.executescript(OLD_SCHEMA)
        conn.execute("INSERT INTO usage_events(tool,session_id,ts,model,input,output,cache_read,cost,src_key) VALUES ('opencode','s',1,'m',1000,0,0,2,'s')")
        conn.execute("INSERT INTO usage_events(tool,session_id,ts,model,input,output,cache_read,cost,src_key) VALUES ('codex','c',1,'gpt-5',1000000,0,800000,1.35,'legacy|x|1')")
        if fail:
            conn.execute("CREATE TRIGGER reject_upgrade BEFORE UPDATE ON usage_events BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        conn.commit()
        conn.close()

    def test_legacy_upgrade_backed_up_and_repeatable(self):
        self.old_database()
        conn = self.connect()
        self.assertGreater(conn.execute("PRAGMA user_version").fetchone()[0], 0)
        backups = glob.glob(self.path + ".v0.backup-*.db")
        self.assertEqual(len(backups), 1)
        with closing(sqlite3.connect(backups[0])) as backup:
            self.assertEqual(backup.execute("SELECT SUM(input) FROM usage_events").fetchone()[0], 1001000)
        self.assertEqual(db.stats(conn, "all", "opencode")[1]["tokens"], 1000)
        self.assertEqual(db.stats(conn, "day", "opencode")[1]["tokens"], 0)
        self.assertEqual(db.stats(conn, "day", "opencode")[1]["unallocated"]["tokens"], 1000)
        row = conn.execute("SELECT * FROM usage_events WHERE tool='codex'").fetchone()
        self.assertEqual(row["input"], 200000)
        self.assertAlmostEqual(row["cost"], .35)
        self.assertEqual(row["cost_source"], "recomputed")
        again = self.connect()
        self.assertEqual(db.stats(again)[1]["tokens"], 1001000)
        self.assertEqual(len(glob.glob(self.path + ".v0.backup-*.db")), 1)

    def test_failed_upgrade_rolls_back_schema_and_values(self):
        self.old_database(fail=True)
        with self.assertRaises(sqlite3.DatabaseError):
            db.connect(self.path)
        with closing(sqlite3.connect(self.path)) as conn:
            self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 0)
            self.assertNotIn("time_quality", [r[1] for r in conn.execute("PRAGMA table_info(usage_events)")])
            self.assertEqual(conn.execute("SELECT SUM(input) FROM usage_events").fetchone()[0], 1001000)

    def test_backup_includes_committed_wal_and_can_be_upgraded_independently(self):
        self.old_database()
        source = sqlite3.connect(self.path)
        self.addCleanup(source.close)
        source.execute("PRAGMA journal_mode=WAL")
        source.execute("UPDATE usage_events SET input=1002 WHERE tool='opencode'")
        source.commit()
        conn = self.connect()
        self.assertEqual(db.stats(conn, "all", "opencode")[1]["tokens"], 1002)
        backup_path = glob.glob(self.path + ".v0.backup-*.db")[0]
        copy = db.connect(backup_path)
        self.addCleanup(copy.close)
        self.assertEqual(db.stats(copy, "all", "opencode")[1]["tokens"], 1002)
        self.assertEqual(db.stats(copy)[1]["tokens"], db.stats(conn)[1]["tokens"])

    def test_scanner_failure_rolls_back_only_the_failed_tool(self):
        from types import SimpleNamespace
        from tokentracker.scanners import run_all
        conn = self.connect()
        def scan_ok(conn, prices, full=False):
            db.put_event(conn,"good","one",input=100)
            return {"added":1}
        def scan_bad(conn, prices, full=False):
            db.put_event(conn,"bad","partial",input=200)
            raise RuntimeError("synthetic source failure")
        modules = {"good":SimpleNamespace(detect=lambda:True,scan=scan_ok),
                   "bad":SimpleNamespace(detect=lambda:True,scan=scan_bad)}
        with patch("tokentracker.scanners.load",side_effect=modules.__getitem__):
            results = run_all(conn,{},tools=["good","bad"])
        self.assertIn("error",results["bad"])
        self.assertEqual(db.stats(conn)[1]["tokens"],100)

    def test_observation_intervals_are_not_forced_into_buckets(self):
        from datetime import datetime
        start = int(datetime(2026, 8, 27).timestamp() * 1000)
        conn = self.connect()
        db.put_event(conn, "t", "past", ts=1, input=1000, time_quality="unallocated")
        db.put_event(conn, "t", "cross-day", ts=start+100, input=100,
                     time_quality="observed", interval_start=start-100)
        db.put_event(conn, "t", "cross-hour", ts=start+3600001, input=10,
                     time_quality="observed", interval_start=start+100)
        with patch.object(db, "_range_bounds", return_value=(start, start+86400000)):
            total = db.stats(conn, "day")[1]
            self.assertEqual(total["tokens"], 10)
            self.assertEqual(total["estimated_tokens"], 10)
            self.assertEqual(total["unallocated"]["tokens"], 1100)
            self.assertEqual(db.daily(conn, "day"), [])
            self.assertEqual(db.time_summary(conn, "day", bucket="hour")["unallocated"]["tokens"], 1110)
        self.assertEqual(db.stats(conn)[1]["tokens"], 1110)
