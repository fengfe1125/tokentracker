"""Snapshot scanners against synthetic provider databases and a controlled clock."""
from contextlib import closing
import json
import os
import sqlite3
import tempfile
import threading
import unittest
from datetime import datetime
from unittest.mock import patch

from tokentracker import db, pricing
from tokentracker.scanners import hermes, opencode


class AggregateScannerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conn = db.connect(os.path.join(self.tmp.name, "usage.db"))
        self.addCleanup(self.conn.close)
        self.start = int(datetime(2026, 8, 27).timestamp()*1000)
        self.paths = {}
        for name in ("opencode", "hermes"):
            path = os.path.join(self.tmp.name, name + ".db")
            self.paths[name] = path
            with closing(sqlite3.connect(path)) as conn, conn:
                if name == "opencode":
                    conn.execute("CREATE TABLE session (id TEXT,directory TEXT,title TEXT,model TEXT,tokens_input INT,tokens_output INT,tokens_reasoning INT,tokens_cache_read INT,tokens_cache_write INT,cost REAL,time_created INT,time_updated INT)")
                    conn.execute("INSERT INTO session VALUES ('s','p','title','gpt-5',1000,0,0,0,0,0,1,1)")
                else:
                    conn.executescript("CREATE TABLE sessions(id TEXT,display_name TEXT); INSERT INTO sessions VALUES ('s','p'); CREATE TABLE session_model_usage(session_id TEXT,model TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_write_tokens INT,reasoning_tokens INT,estimated_cost_usd REAL,actual_cost_usd REAL,first_seen INT,last_seen INT,api_call_count INT,billing_provider TEXT,billing_base_url TEXT,billing_mode TEXT,task TEXT)")
                    conn.execute("INSERT INTO session_model_usage VALUES ('s','gpt-5',1000,0,0,0,0,NULL,0,1,1,1,'p','url','m','t')")
        self.addCleanup(patch.stopall)
        patch.object(opencode, "db_path", return_value=self.paths["opencode"]).start()
        patch.object(hermes, "db_files", return_value=[self.paths["hermes"]]).start()

    def scan_at(self, scanner, ms, full=False):
        with patch("tokentracker.db.time.time", return_value=ms/1000):
            return scanner.scan(self.conn, pricing.DEFAULT_PRICES, full=full)

    def update(self, name, value):
        with closing(sqlite3.connect(self.paths[name])) as conn, conn:
            if name == "opencode":
                conn.execute("UPDATE session SET tokens_input=?,time_updated=time_updated+1", (value,))
            else:
                conn.execute("UPDATE session_model_usage SET input_tokens=?,last_seen=last_seen+1", (value,))

    def test_baseline_preserved_and_only_new_delta_in_today(self):
        for scanner in (opencode, hermes):
            with self.subTest(scanner=scanner.NAME):
                self.scan_at(scanner, self.start-3600000)
                # An unchanged observation today narrows the next delta's interval.
                self.scan_at(scanner, self.start+1000)
                self.update(scanner.NAME, 1100)
                self.scan_at(scanner, self.start+2000)
                self.scan_at(scanner, self.start+3000, full=True)
                with patch.object(db, "_range_bounds", return_value=(self.start,self.start+86400000)):
                    today = db.stats(self.conn, "day", scanner.NAME)[1]
                self.assertEqual(today["tokens"], 100)
                self.assertEqual(today["estimated_tokens"], 100)
                self.assertEqual(today["unallocated"]["tokens"], 1000)
                self.assertEqual(db.stats(self.conn,"all",scanner.NAME)[1]["tokens"], 1100)
                self.assertEqual(db.stats(self.conn,"all",scanner.NAME)[1]["cost"], 0)

    def test_cross_month_interval_and_counter_reset(self):
        for scanner in (opencode, hermes):
            with self.subTest(scanner=scanner.NAME):
                self.scan_at(scanner, self.start-40*86400000)
                self.update(scanner.NAME,1100)
                self.scan_at(scanner,self.start+1000)
                with patch.object(db,"_range_bounds",return_value=(self.start,self.start+86400000)):
                    self.assertEqual(db.stats(self.conn,"day",scanner.NAME)[1]["tokens"],0)
                    self.assertEqual(db.stats(self.conn,"day",scanner.NAME)[1]["unallocated"]["tokens"],1100)
                self.update(scanner.NAME,10)
                result = self.scan_at(scanner,self.start+2000)
                self.assertEqual(result["counter_resets"],1)
                self.update(scanner.NAME,30)
                self.scan_at(scanner,self.start+3000)
                self.assertEqual(db.stats(self.conn,"all",scanner.NAME)[1]["tokens"],1120)

    def test_adopt_legacy_baseline_without_counting_it_twice(self):
        for scanner, key in ((opencode,"s"),(hermes,"s|gpt-5|p|url|m|t")):
            db.put_event(self.conn,scanner.NAME,key,session_id="s",input=1000,time_quality="unallocated")
            self.scan_at(scanner,self.start)
            self.update(scanner.NAME,1100)
            self.scan_at(scanner,self.start+1000)
            self.assertEqual(db.stats(self.conn,"all",scanner.NAME)[1]["tokens"],1100)

    def test_hermes_legacy_profile_is_matched_before_root_is_scanned(self):
        root = self.paths["hermes"]
        profile = os.path.join(self.tmp.name, "profile.db")
        with closing(sqlite3.connect(root)) as src, closing(sqlite3.connect(profile)) as dst:
            src.backup(dst)
        self.update("hermes", 100)
        with closing(sqlite3.connect(profile)) as conn, conn:
            conn.execute("UPDATE session_model_usage SET input_tokens=900")
        db.put_event(self.conn, "hermes", "s|gpt-5|p|url|m|t", session_id="s",
                     project="p", model="gpt-5", input=900, cost=0,
                     time_quality="unallocated", cost_source="legacy")
        with patch.object(hermes, "db_files", return_value=[root, profile]):
            self.scan_at(hermes, self.start)
            self.scan_at(hermes, self.start+1000)
        self.assertEqual(db.stats(self.conn, "all", "hermes")[1]["tokens"], 1000)
        legacy = self.conn.execute("SELECT source_scope FROM usage_events WHERE src_key='s|gpt-5|p|url|m|t'").fetchone()
        self.assertEqual(legacy[0], os.path.realpath(profile))

    def test_hermes_ambiguous_decreased_profiles_preserve_legacy_with_warning(self):
        root = self.paths["hermes"]
        profile = os.path.join(self.tmp.name, "profile.db")
        with closing(sqlite3.connect(root)) as src, closing(sqlite3.connect(profile)) as dst:
            src.backup(dst)
        self.update("hermes", 100)
        with closing(sqlite3.connect(profile)) as conn, conn:
            conn.execute("UPDATE session_model_usage SET input_tokens=200")
        db.put_event(self.conn, "hermes", "s|gpt-5|p|url|m|t", session_id="s",
                     project="p", model="gpt-5", input=900, cost=0, time_quality="unallocated")
        with patch.object(hermes, "db_files", return_value=[root, profile]):
            result = self.scan_at(hermes, self.start)
        self.assertIn("warning", result)
        legacy = self.conn.execute("SELECT source_scope,input,time_quality FROM usage_events WHERE src_key='s|gpt-5|p|url|m|t'").fetchone()
        self.assertEqual(tuple(legacy), ("", 900, "unallocated"))

    def snapshot(self, conn, inp, cost, at, source="native"):
        return db.put_snapshot(conn, "test", "fixture.db", "s", session_id="s",
                               project="p", model="m", input=inp, native_cost=cost,
                               cost_source=source, observed_at=at,
                               prices={"models": {"m": {"input": 1, "output": 0}}})

    def test_native_cost_arrival_creates_unallocated_adjustment(self):
        self.snapshot(self.conn, 1_000_000, None, self.start-1000)
        self.snapshot(self.conn, 1_100_000, 2, self.start+1000)
        self.snapshot(self.conn, 1_200_000, 2.2, self.start+2000)
        self.assertAlmostEqual(db.stats(self.conn)[1]["cost"], 2.2)
        rows = [dict(r) for r in self.conn.execute("SELECT * FROM usage_events WHERE cost_source='native_adjustment'")]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["tokens"] if "tokens" in rows[0] else rows[0]["input"], rows[0]["time_quality"]), (0, "unallocated"))
        self.assertAlmostEqual(rows[0]["cost"], .9)

    def test_native_source_switch_reconciles_history_without_negative_today(self):
        self.snapshot(self.conn, 1_000_000, 3, self.start, source="provider_estimate")
        self.snapshot(self.conn, 1_100_000, 2, self.start+1000)
        self.assertAlmostEqual(db.stats(self.conn)[1]["cost"], 2)
        adjustment = self.conn.execute("SELECT cost,time_quality FROM usage_events WHERE cost_source='native_adjustment'").fetchone()
        self.assertIsNotNone(adjustment)
        self.assertAlmostEqual(adjustment[0], -1.1)
        self.assertEqual(adjustment[1], "unallocated")
        with patch.object(db, "_range_bounds", return_value=(self.start,self.start+86400000)):
            self.assertAlmostEqual(db.stats(self.conn, "day")[1]["cost"], .1)

    def test_old_snapshot_without_accounted_cost_uses_existing_ledger(self):
        self.snapshot(self.conn, 1_000_000, None, self.start)
        row = self.conn.execute("SELECT values_json FROM aggregate_snapshots").fetchone()
        old = json.loads(row[0])
        old.pop("accounted_cost", None)
        old.pop("native_source", None)
        self.conn.execute("UPDATE aggregate_snapshots SET values_json=?", (json.dumps(old),))
        self.snapshot(self.conn, 1_100_000, 2, self.start+1000)
        self.assertAlmostEqual(db.stats(self.conn)[1]["cost"], 2)

    def test_native_counter_reset_starts_new_cost_baseline(self):
        self.snapshot(self.conn, 1_000_000, 2, self.start)
        self.snapshot(self.conn, 10, .01, self.start+1000)
        self.snapshot(self.conn, 30, .03, self.start+2000)
        self.assertEqual(db.stats(self.conn)[1]["tokens"], 1_000_020)
        self.assertAlmostEqual(db.stats(self.conn)[1]["cost"], 2.02)

    def test_native_arrival_accounts_for_prices_filled_between_scans(self):
        db.put_snapshot(self.conn,"test","fixture.db","s",session_id="s",project="p",
                        model="m",input=1_000_000,prices={},observed_at=self.start)
        db.reprice(self.conn,{"models":{"m":{"input":1}}})
        self.snapshot(self.conn,1_100_000,2,self.start+1000)
        self.assertAlmostEqual(db.stats(self.conn)[1]["cost"],2)

    def test_concurrent_connections_serialize_snapshot_read_and_write(self):
        path = os.path.join(self.tmp.name, "concurrent.db")
        with closing(db.connect(path)) as conn:
            self.snapshot(conn, 100, 0, 1)
            conn.commit()
        first_read, second_read = threading.Event(), threading.Event()
        release_first, first_done = threading.Event(), threading.Event()
        errors = []
        class Cursor:
            def __init__(self, cursor, name):
                self.cursor, self.name = cursor, name
            def fetchone(self):
                result = self.cursor.fetchone()
                if self.name == "A":
                    first_read.set()
                    if not release_first.wait(5):
                        raise RuntimeError("A was not released")
                else:
                    second_read.set()
                    if not first_done.wait(5):
                        raise RuntimeError("A did not commit")
                return result
        class Connection:
            def __init__(self, conn, name):
                self.conn, self.name = conn, name
            def __getattr__(self, name):
                return getattr(self.conn, name)
            def execute(self, sql, args=()):
                cursor = self.conn.execute(sql, args)
                return Cursor(cursor, self.name) if sql.startswith("SELECT * FROM aggregate_snapshots") else cursor
        def worker(name, count, timestamp):
            try:
                with closing(db.connect(path)) as conn:
                    self.snapshot(Connection(conn, name), count, 0, timestamp)
                    conn.commit()
            except Exception as exc:
                errors.append(repr(exc))
            finally:
                if name == "A":
                    first_done.set()
        a = threading.Thread(target=worker, args=("A",110,2))
        b = threading.Thread(target=worker, args=("B",120,3))
        a.start()
        self.assertTrue(first_read.wait(5))
        b.start()
        read_too_early = second_read.wait(.1)
        release_first.set()
        a.join(8)
        b.join(8)
        self.assertFalse(a.is_alive() or b.is_alive())
        self.assertEqual(errors, [])
        self.assertFalse(read_too_early)
        with closing(db.connect(path)) as conn:
            self.assertEqual(db.stats(conn)[1]["tokens"], 120)
