"""Metadata-only Agent Activity regressions using invented local fixtures."""
import json
import glob
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from tokentracker import db
from tokentracker.scanners import claude, codex, dsh, hermes, kimi, opencode, pi
from tokentracker.scanners._util import iter_jsonl, stat_key

PRICES = {"models": {}}
TS = "2026-09-08T01:00:00Z"
TS_MS = 1788829200000


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


class ActivityCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tt_activity_")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.conn = db.connect(str(self.root / "usage.db"))
        self.addCleanup(self.conn.close)

    def activities(self, agent=None):
        sql = "SELECT * FROM agent_activity_events"
        args = ()
        if agent:
            sql += " WHERE agent=?"
            args = (agent,)
        return [dict(r) for r in self.conn.execute(sql + " ORDER BY id", args)]

    def test_store_is_metadata_only_idempotent_and_separates_evidence(self):
        db.put_activity_event(self.conn, "codex", "one", raw_name="exec", call_id="c1",
                              confidence="exact", status="unknown", skill_name="research",
                              skill_confidence="derived", started_at=TS_MS)
        db.put_activity_event(self.conn, "codex", "one", raw_name="exec", call_id="c1",
                              confidence="exact", status="success", ended_at=TS_MS + 20)
        columns = {r[1] for r in self.conn.execute("PRAGMA table_info(agent_activity_events)")}
        self.assertFalse(columns & {"arguments", "input", "output", "prompt", "result"})
        self.assertEqual(len(self.activities()), 1)
        self.assertEqual(self.activities()[0]["status"], "success")
        self.assertEqual(db.activity_summary(self.conn, group="tool", confidence="exact")[0]["calls"], 1)
        self.assertEqual(db.activity_summary(self.conn, group="skill", confidence="derived")[0]["name"], "research")
        self.assertEqual(db.activity_summary(self.conn, group="skill", confidence="exact"), [])

    def test_cross_agent_names_are_canonical_and_timeline_cursor_keeps_timestamp_ties(self):
        for index, (agent, raw) in enumerate((("claude", "Bash"), ("codex", "shell"),
                                              ("kimi", "bash")), 1):
            db.put_activity_event(
                self.conn, agent, f"row-{index}", raw_name=raw,
                session_id="s", started_at=TS_MS, status="success")
        combined = db.activity_summary(self.conn, group="tool")
        self.assertEqual([(row["name"], row["calls"]) for row in combined], [("shell", 3)])
        native = db.activity_summary(self.conn, agent="claude", group="tool")
        self.assertEqual(native[0]["name"], "Bash")

        first = db.activity_timeline(self.conn, limit=2)
        second = db.activity_timeline(
            self.conn, limit=2, before=first["next_before"],
            before_id=first["next_before_id"])
        self.assertEqual(len(first["rows"]), 2)
        self.assertEqual(len(second["rows"]), 1)
        self.assertEqual(len({row["id"] for row in first["rows"] + second["rows"]}), 3)
        with patch.object(db, "_range_bounds", return_value=(TS_MS - 1, TS_MS + 1000)):
            self.assertEqual(len(db.activity_timeline(self.conn, range_key="day")["rows"]), 3)
            self.assertEqual(db.activity_timeline(
                self.conn, range_key="day", before=TS_MS - 1)["rows"], [])

    def test_v2_upgrade_creates_backup_and_activity_table(self):
        path = str(self.root / "legacy-v2.db")
        with closing(sqlite3.connect(path)) as legacy, legacy:
            legacy.executescript("CREATE TABLE usage_events(id INTEGER PRIMARY KEY,tool TEXT NOT NULL,session_id TEXT NOT NULL DEFAULT '',project TEXT NOT NULL DEFAULT '',ts INTEGER NOT NULL,model TEXT NOT NULL DEFAULT '',input INTEGER NOT NULL DEFAULT 0,output INTEGER NOT NULL DEFAULT 0,cache_read INTEGER NOT NULL DEFAULT 0,cache_write INTEGER NOT NULL DEFAULT 0,cost REAL,src_key TEXT NOT NULL,time_quality TEXT NOT NULL DEFAULT 'exact',interval_start INTEGER,cost_source TEXT NOT NULL DEFAULT 'estimate',source_kind TEXT NOT NULL DEFAULT '',source_scope TEXT NOT NULL DEFAULT '',UNIQUE(tool,src_key)); PRAGMA user_version=2;")
        upgraded = db.connect(path)
        try:
            self.assertEqual(upgraded.execute("PRAGMA user_version").fetchone()[0], 3)
            self.assertIsNotNone(upgraded.execute("SELECT 1 FROM sqlite_master WHERE name='agent_activity_events'").fetchone())
        finally:
            upgraded.close()
        self.assertEqual(len(glob.glob(path + ".v2.backup-*.db")), 1)

    def test_v2_marker_preserves_compatible_residual_activity_rows(self):
        path = str(self.root / "residual-v2.db")
        seeded = db.connect(path)
        db.put_activity_event(seeded, "codex", "kept", raw_name="exec",
                              confidence="exact", status="success")
        seeded.execute("PRAGMA user_version=2")
        seeded.commit()
        seeded.close()

        upgraded = db.connect(path)
        try:
            self.assertEqual(upgraded.execute("PRAGMA user_version").fetchone()[0], 3)
            self.assertEqual(upgraded.execute(
                "SELECT COUNT(*) FROM agent_activity_events WHERE src_key='kept'"
            ).fetchone()[0], 1)
        finally:
            upgraded.close()

    def test_v2_marker_rejects_malformed_residual_activity_table(self):
        path = str(self.root / "malformed-v2.db")
        seeded = db.connect(path)
        seeded.execute("DROP TABLE agent_activity_events")
        seeded.execute("CREATE TABLE agent_activity_events(id INTEGER PRIMARY KEY, agent TEXT)")
        seeded.execute("PRAGMA user_version=2")
        seeded.commit()
        seeded.close()

        with self.assertRaisesRegex(RuntimeError, "schema is incompatible"):
            db.connect(path)
        with closing(sqlite3.connect(path)) as unchanged:
            self.assertEqual(unchanged.execute("PRAGMA user_version").fetchone()[0], 2)

    def test_claude_exact_skill_result_and_upgrade_backfill(self):
        base = self.root / "claude"
        path = base / "project" / "session.jsonl"
        write_jsonl(path, [
            {"type": "assistant", "timestamp": TS, "message": {"content": [
                {"type": "tool_use", "id": "c1", "name": "Skill", "input": {"skill": "research"}}]}},
            {"type": "user", "timestamp": TS, "message": {"content": [
                {"type": "tool_result", "tool_use_id": "c1", "content": "secret"}]}},
        ])
        db.set_scan_cursor(self.conn, "claude", {str(path): stat_key(str(path))})
        with patch.object(claude, "root", return_value=str(base)):
            first = claude.scan(self.conn, PRICES)
            second = claude.scan(self.conn, PRICES)
        self.assertEqual((first["activity_added"], second["activity_added"]), (1, 0))
        row = self.activities("claude")[0]
        self.assertEqual((row["skill_name"], row["skill_confidence"], row["status"]),
                         ("research", "exact", "success"))

    def test_kimi_and_dsh_streams_count_calls_once(self):
        kimi_root = self.root / "kimi"
        write_jsonl(kimi_root / "session_s.jsonl", [
            {"kind": "event", "seq": 1, "envelope": {"type": "tool.call.started", "timestamp": TS,
             "payload": {"toolCallId": "k1", "name": "Skill", "args": {"skill": "diagram"}}}},
            {"kind": "event", "seq": 2, "envelope": {"type": "tool.result", "timestamp": TS,
             "payload": {"toolCallId": "k1", "status": "completed", "output": "secret"}}},
        ])
        with patch.object(kimi, "journal_dir", return_value=str(kimi_root)), \
             patch.object(kimi, "cli_dir", return_value=str(self.root / "missing")):
            kimi.scan(self.conn, PRICES)

        dsh_root = self.root / "dsh"
        write_jsonl(dsh_root / "p" / "s" / "session.jsonl.zstd", [
            {"type": "session", "id": "s", "cwd": "/p"},
            {"type": "tool/call", "time": TS_MS, "data": {"name": "bash", "callId": "d1"}},
            {"type": "tool/call/delta", "time": TS_MS, "data": {"name": "bash", "callId": "d1"}},
            {"type": "tool/result", "time": TS_MS + 5, "data": {"callId": "d1", "status": "failed"}},
        ])
        with patch.object(dsh, "root", return_value=str(dsh_root)), \
             patch.object(dsh, "iter_zstd_jsonl", iter_jsonl):
            dsh.scan(self.conn, PRICES)
        self.assertEqual(len(self.activities("kimi")), 1)
        self.assertEqual(self.activities("kimi")[0]["skill_name"], "diagram")
        self.assertEqual(len(self.activities("dsh")), 1)
        self.assertEqual(self.activities("dsh")[0]["status"], "error")

    def test_pi_tool_result_and_skill_capability_unknown(self):
        base = self.root / "pi"
        write_jsonl(base / "session.jsonl", [
            {"type": "session", "id": "p1", "cwd": "/p"},
            {"type": "message", "id": "m1", "timestamp": TS, "message": {"content": [
                {"type": "toolCall", "id": "p-call", "name": "read", "arguments": {"path": "private"}}]}},
            {"type": "message", "id": "m2", "timestamp": TS, "message": {"content": [
                {"type": "toolResult", "toolCallId": "p-call", "content": "secret"}]}},
        ])
        with patch.object(pi, "roots", return_value=[str(base)]):
            pi.scan(self.conn, PRICES)
        self.assertEqual(self.activities("pi")[0]["status"], "success")
        self.assertEqual(db.activity_capabilities()["pi"]["skills"], "unknown")

    def test_codex_exact_outer_derived_inner_and_skill(self):
        sessions = self.root / "codex"
        sessions.mkdir()
        write_jsonl(sessions / "s.jsonl", [
            {"type": "session_meta", "timestamp": TS, "payload": {"id": "s"}},
            {"type": "turn_context", "timestamp": TS, "payload": {"turn_id": "t"}},
            {"type": "response_item", "timestamp": TS, "payload": {"type": "custom_tool_call",
             "id": "item1", "call_id": "c1", "name": "exec",
             "input": "await tools.read_file({path: '/skills/research/SKILL.md'}); await tools.web_search({q:'x'});"}},
            {"type": "response_item", "timestamp": TS, "payload": {"type": "custom_tool_call_output",
             "id": "out1", "call_id": "c1", "output": {"ok": True, "private": "discard"}}},
        ])
        with patch.object(codex, "sqlite_path", return_value=str(self.root / "missing.db")), \
             patch.object(codex, "legacy_dir", return_value=str(sessions)):
            codex.scan(self.conn, PRICES)
        rows = self.activities("codex")
        self.assertEqual([(r["raw_name"], r["confidence"]) for r in rows],
                         [("exec", "exact"), ("read_file", "derived"), ("web_search", "derived")])
        self.assertEqual((rows[0]["skill_name"], rows[0]["skill_confidence"], rows[0]["status"]),
                         ("research", "derived", "success"))
        self.assertTrue(all(r["parent_call_id"] == "c1" for r in rows[1:]))

    def test_opencode_and_hermes_sqlite_activity(self):
        op_path = self.root / "opencode.db"
        with closing(sqlite3.connect(op_path)) as source, source:
            source.execute("CREATE TABLE session (id TEXT,directory TEXT,title TEXT,model TEXT,tokens_input INT,tokens_output INT,tokens_reasoning INT,tokens_cache_read INT,tokens_cache_write INT,cost REAL,time_created INT,time_updated INT)")
            source.execute("INSERT INTO session VALUES ('o','/p','title','m',0,0,0,0,0,0,1,1)")
            source.execute("CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,time_created INT,time_updated INT,data TEXT)")
            data = {"type": "tool", "tool": "skill", "callID": "o1", "state": {
                "status": "completed", "input": {"name": "research"},
                "output": "secret", "time": {"start": TS_MS, "end": TS_MS + 10}}}
            source.execute("INSERT INTO part VALUES ('part1','m','o',?,?,?)", (TS_MS, TS_MS + 10, json.dumps(data)))
        with patch.object(opencode, "db_path", return_value=str(op_path)):
            opencode.scan(self.conn, PRICES)

        he_path = self.root / "hermes.db"
        with closing(sqlite3.connect(he_path)) as source, source:
            source.executescript("CREATE TABLE sessions(id TEXT,display_name TEXT); INSERT INTO sessions VALUES ('h','H'); CREATE TABLE session_model_usage(session_id TEXT,model TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_write_tokens INT,reasoning_tokens INT,estimated_cost_usd REAL,actual_cost_usd REAL,first_seen INT,last_seen INT,api_call_count INT,billing_provider TEXT,billing_base_url TEXT,billing_mode TEXT,task TEXT); INSERT INTO session_model_usage VALUES ('h','m',0,0,0,0,0,NULL,0,1,1,1,'p','u','m','t'); CREATE TABLE messages(id INTEGER PRIMARY KEY,session_id TEXT,role TEXT,tool_call_id TEXT,tool_calls TEXT,tool_name TEXT,effect_disposition TEXT,timestamp REAL);")
            calls = [{"id": "h1", "function": {"name": "skill_view", "arguments": json.dumps({"name": "writer"})}}]
            source.execute("INSERT INTO messages VALUES (1,'h','assistant',NULL,?,NULL,NULL,?)", (json.dumps(calls), TS_MS / 1000))
            source.execute("INSERT INTO messages VALUES (2,'h','tool','h1',NULL,'skill_view','success',?)", ((TS_MS + 3) / 1000,))
        with patch.object(hermes, "db_files", return_value=[str(he_path)]):
            hermes.scan(self.conn, PRICES)
        self.assertEqual(self.activities("opencode")[0]["skill_name"], "research")
        self.assertEqual(self.activities("hermes")[0]["skill_name"], "writer")
        self.assertEqual(self.activities("hermes")[0]["status"], "success")


if __name__ == "__main__":
    unittest.main()
