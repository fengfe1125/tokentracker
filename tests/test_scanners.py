"""Scanner regressions using invented logs and isolated SQLite databases only."""
import json
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from tokentracker import db
from tokentracker.scanners import claude, codex, dsh, kimi, pi
from tokentracker.scanners._util import iter_jsonl


PRICES = {"models": {"test-model": {"input": 2, "output": 10,
                                    "cache_read": .2, "cache_write": 2}}}
TS = "2026-08-25T01:00:00Z"
TS_MS = 1787619600000


def write_jsonl(path, objects):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(obj) + "\n" for obj in objects), encoding="utf-8")


def usage(inp=100, out=10, cached=20, written=0):
    return {"input_tokens": inp, "output_tokens": out,
            "cached_input_tokens": cached, "cache_write_input_tokens": written,
            "total_tokens": inp + out}


def token_event(total, turn="turn-a", last=None, timestamp=TS):
    info = {"total_token_usage": total, "last_token_usage": last or total}
    payload = {"type": "token_count", "info": info}
    if turn is not None:
        payload["turn_id"] = turn
    return {"timestamp": timestamp, "type": "event_msg", "payload": payload}


class ScannerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tt_scanner_tests_")
        self.root = Path(self.tmp.name)
        self.conn = db.connect(str(self.root / "usage.db"))

    def tearDown(self):
        self.conn.close()
        self.tmp.cleanup()

    def rows(self, tool=None):
        if tool:
            return [dict(r) for r in self.conn.execute("SELECT * FROM usage_events WHERE tool=? ORDER BY src_key", (tool,))]
        return [dict(r) for r in self.conn.execute("SELECT * FROM usage_events ORDER BY src_key")]


class JsonlScannerTest(ScannerCase):
    def test_claude_accepts_top_level_usage_and_invalid_message(self):
        source = self.root / "claude"
        write_jsonl(source / "project" / "session.jsonl", [
            {"model": "test-model", "usage": {"input_tokens": 10}, "timestamp": TS},
            {"message": "bad", "usage": {"input_tokens": 20}, "model": "test-model", "timestamp": TS},
        ])
        with patch.object(claude, "root", return_value=str(source)):
            claude.scan(self.conn, PRICES)
        self.assertEqual(sum(r["input"] for r in self.rows()), 30)

    def test_dsh_missing_header_uses_directory_identity(self):
        source = self.root / "dsh"
        event = {"type": "assistant/chunk", "time": TS_MS, "data": {
            "turn": 0, "step": 0, "chunk": {"type": "usage", "usage": {"inputTokens": 10}}}}
        for name in ("session-a", "session-b"):
            write_jsonl(source / "project" / name / "session.jsonl.zstd", [event])
        with patch.object(dsh, "root", return_value=str(source)), patch.object(dsh, "iter_zstd_jsonl", iter_jsonl):
            dsh.scan(self.conn, PRICES)
            dsh.scan(self.conn, PRICES, full=True)
        self.assertEqual(len(self.rows()), 2)
        self.assertEqual(len({r["session_id"] for r in self.rows()}), 2)

    def test_dsh_old_fallback_row_is_rekeyed_only_after_payload_match(self):
        source = self.root / "dsh"
        event = {"type": "assistant/chunk", "time": TS_MS, "data": {
            "turn": 0, "step": 0, "chunk": {"type": "usage", "usage": {"inputTokens": 10}}}}
        write_jsonl(source / "project" / "session-a" / "session.jsonl.zstd", [event])
        db.put_event(self.conn, "dsh", "session|0|0", session_id="session", project="project",
                     ts=TS_MS, input=10)
        with patch.object(dsh, "root", return_value=str(source)), patch.object(dsh, "iter_zstd_jsonl", iter_jsonl):
            dsh.scan(self.conn, PRICES)
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]["session_id"], "project/session-a/session.jsonl.zstd")

    def test_changed_tail_is_revisited_for_all_jsonl_scanners(self):
        examples = [
            (claude, "claude", "project/session.jsonl", "root", lambda n: {"timestamp": TS, "message": {"id": str(n), "model": "test-model", "usage": {"input_tokens": 10}}}),
            (kimi, "kimi", "session_a.jsonl", "journal_dir", lambda n: {"kind": "event", "seq": n, "envelope": {"type": "turn.step.completed", "timestamp": TS, "payload": {"model": "test-model", "usage": {"inputOther": 10}}}}),
            (pi, "pi", "session.jsonl", "roots", lambda n: {"type": "message", "id": str(n), "timestamp": TS, "message": {"model": "test-model", "usage": {"input": 10}}}),
            (dsh, "dsh", "project/session/session.jsonl.zstd", "root", lambda n: {"type": "assistant/chunk", "time": TS_MS, "data": {"turn": 0, "step": n, "chunk": {"type": "usage", "usage": {"inputTokens": 10}}}}),
        ]
        for mod, tool, filename, root_fn, event in examples:
            with self.subTest(tool=tool):
                base = self.root / tool
                path = base / filename
                write_jsonl(path, [event(1)])
                def append_after_eof(path, event=event):
                    yield from iter_jsonl(path)
                    with open(path, "a", encoding="utf-8") as f:
                        f.write(json.dumps(event(2)) + "\n")
                reader_name = "iter_zstd_jsonl" if mod is dsh else "iter_jsonl"
                root_value = [str(base)] if mod is pi else str(base)
                with patch.object(mod, root_fn, return_value=root_value):
                    # Kimi also has a separate legacy source, never use the real home.
                    with patch.object(kimi, "cli_dir", return_value=str(self.root / "absent")):
                        with patch.object(mod, reader_name, append_after_eof):
                            mod.scan(self.conn, PRICES)
                        with patch.object(mod, reader_name, iter_jsonl):
                            mod.scan(self.conn, PRICES)
                self.assertEqual(len(self.rows(tool)), 2)


class CodexScannerTest(ScannerCase):
    def setUp(self):
        super().setUp()
        self.logs = self.root / "logs.db"
        self.sessions = self.root / "sessions"
        self.sessions.mkdir()
        self.patchers = [patch.object(codex, "sqlite_path", return_value=str(self.logs)),
                         patch.object(codex, "legacy_dir", return_value=str(self.sessions))]
        for p in self.patchers:
            p.start()

    def tearDown(self):
        for p in reversed(self.patchers):
            p.stop()
        super().tearDown()

    def rollout(self, events, sid="session-a"):
        path = self.sessions / (sid + ".jsonl")
        write_jsonl(path, [
            {"type": "session_meta", "timestamp": TS, "payload": {"id": sid, "cwd": "/fixture"}},
            {"type": "turn_context", "timestamp": TS, "payload": {"model": "test-model"}},
            *events,
        ])
        return path

    def log(self, row_id, tokens=None, sid="session-a", turn="turn-a"):
        tokens = tokens or usage()
        body = " ".join(f"codex.turn.token_usage.{key}={value}" for key, value in tokens.items())
        body += f" model=test-model thread.id={sid}"
        if turn is not None:
            body += f" turn.id={turn}"
        with closing(sqlite3.connect(self.logs)) as source:
            source.execute("CREATE TABLE IF NOT EXISTS logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, feedback_log_body TEXT)")
            source.execute("INSERT INTO logs VALUES (?, ?, 0, ?)", (row_id, TS_MS // 1000, body))
            source.commit()

    def scan(self, full=False):
        return codex.scan(self.conn, PRICES, full=full)

    def test_sqlite_normalizes_cached_input_before_pricing(self):
        self.log(1, usage(1_000_000, 0, 800_000))
        self.scan()
        row = self.rows()[0]
        self.assertEqual((row["input"], row["cache_read"], row["cost"]), (200_000, 800_000, .56))

    def test_rollout_cumulative_delta_and_repeated_notifications(self):
        self.rollout([token_event(usage()), token_event(usage()),
                      token_event(usage(150, 15, 30), "turn-b", last=usage(50, 5, 10))])
        self.scan()
        self.scan(full=True)
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        self.assertEqual(sum(r["input"] for r in rows), 120)
        self.assertEqual(sum(r["output"] for r in rows), 15)
        self.assertEqual(sum(r["cache_read"] for r in rows), 30)
        self.assertEqual({r["ts"] for r in rows}, {TS_MS})
        self.assertEqual({r["session_id"] for r in rows}, {"session-a"})
        self.assertEqual({r["project"] for r in rows}, {"/fixture"})

    def test_turn_context_and_task_started_supply_missing_turn_id(self):
        self.rollout([{"type": "event_msg", "timestamp": TS, "payload": {"type": "task_started", "turn_id": "turn-b"}},
                      token_event(usage(), turn=None)])
        self.log(1, turn="turn-b")
        self.scan()
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]["source_scope"], "turn-b")

    def test_per_usage_fallback_and_iso_timestamp(self):
        path = self.sessions / "fallback.jsonl"
        write_jsonl(path, [{"usage": usage(100, 10, 20, 5), "model": "test-model", "session_id": "s", "timestamp": TS}])
        self.scan()
        row = self.rows()[0]
        self.assertEqual((row["input"], row["cache_read"], row["cache_write"], row["ts"]), (75, 20, 5, TS_MS))
        self.assertEqual(row["src_key"], f"legacy|{path}|1")

    def test_sqlite_same_turn_is_not_counted_per_log_line(self):
        self.log(1)
        self.log(2)
        self.scan()
        self.assertEqual(len(self.rows()), 1)

    def test_rollout_overrides_same_turn_but_keeps_missing_turn(self):
        self.log(1)
        self.log(2, usage(50, 5, 10), turn="turn-b")
        self.rollout([token_event(usage())])
        self.scan()
        self.assertEqual(len(self.rows()), 2)
        self.assertEqual(sum(r["input"] for r in self.rows()), 120)

    def test_later_rollout_replaces_existing_sqlite_without_duplicates(self):
        self.log(1)
        self.log(2, usage(50, 5, 10), turn="turn-b")
        self.scan()
        self.rollout([token_event(usage())])
        self.scan()
        self.scan(full=True)
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        self.assertEqual(sum(r["input"] for r in rows), 120)

    def test_unavailable_rollout_history_survives_later_sqlite(self):
        path = self.rollout([token_event(usage())])
        self.scan()
        path.unlink()
        self.log(1)
        self.log(2, usage(50, 5, 10), turn="turn-b")
        self.scan()
        self.assertEqual(len(self.rows()), 2)

    def test_unknown_turn_jsonl_takes_session_precedence(self):
        self.log(1, turn=None)
        self.rollout([token_event(usage(), turn=None)])
        self.scan()
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]["source_kind"], "codex_jsonl")

    def test_partial_rollout_keeps_sqlite_remainder_until_it_catches_up(self):
        self.log(1)
        self.scan()
        self.rollout([token_event(usage(50, 5, 10))])
        self.scan()
        self.assertEqual(sum(r["input"] for r in self.rows()), 80)
        self.assertEqual(len(self.rows()), 2)
        self.rollout([token_event(usage(50, 5, 10)), token_event(usage())])
        self.scan()
        self.scan(full=True)
        self.assertEqual(sum(r["input"] for r in self.rows()), 80)
        self.assertEqual({r["source_kind"] for r in self.rows()}, {"codex_jsonl"})

    def test_later_sqlite_supplements_partial_known_turn(self):
        self.rollout([token_event(usage(50, 5, 10))])
        self.scan()
        self.log(1)
        self.scan()
        self.scan(full=True)
        self.assertEqual(sum(r["input"] for r in self.rows()), 80)
        self.assertEqual(len(self.rows()), 2)

    def test_unmapped_old_history_is_retained_with_warning(self):
        db.put_event(self.conn, "codex", "logs2|99", session_id="session-a", ts=TS_MS,
                     model="test-model", input=40, output=5, cost=.00013)
        self.rollout([token_event(usage())])
        result = self.scan()
        self.assertIn("warning", result)
        self.assertEqual(len(self.rows()), 2)
        old = next(r for r in self.rows() if r["src_key"] == "logs2|99")
        self.assertEqual(old["time_quality"], "unallocated")

    def test_last_usage_fallback_then_cumulative_does_not_double_count(self):
        event = token_event(usage(50, 5, 10))
        del event["payload"]["info"]["total_token_usage"]
        self.rollout([event, event, token_event(usage())])
        self.scan()
        self.assertEqual(sum(r["input"] for r in self.rows()), 80)
        self.assertEqual(len(self.rows()), 2)

    def test_cumulative_reset_is_rebaselined_without_negative_usage(self):
        self.rollout([token_event(usage()), token_event(usage(10, 1, 0)),
                      token_event(usage(30, 3, 5))])
        self.scan()
        self.assertEqual(sum(r["input"] for r in self.rows()), 95)
        self.assertTrue(all(r["input"] >= 0 and r["cache_read"] >= 0 for r in self.rows()))

    def test_initial_historical_total_has_unknown_time(self):
        self.rollout([token_event(usage(1000, 100, 200), last=usage())])
        self.scan()
        self.assertEqual(self.rows()[0]["time_quality"], "unallocated")

    def test_codex_append_after_eof_is_read_on_next_scan(self):
        path = self.rollout([token_event(usage())])
        def append_after_eof(path):
            yield from iter_jsonl(path)
            with open(path, "a", encoding="utf-8") as f:
                f.write(json.dumps(token_event(usage(150, 15, 30), "turn-b")) + "\n")
        with patch.object(codex, "iter_jsonl", append_after_eof):
            self.scan()
        self.scan()
        self.assertEqual(len(self.rows()), 2)
        self.assertEqual(sum(r["input"] for r in self.rows()), 120)

    def test_invalid_rollout_never_removes_sqlite_history(self):
        self.log(1)
        self.scan()
        self.rollout([token_event({"input_tokens": "invalid"})])
        self.scan()
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]["input"], 80)

    def test_legacy_database_row_is_corrected_in_place(self):
        self.log(1)
        db.put_event(self.conn, "codex", "logs2|1", session_id="session-a", ts=TS_MS,
                     model="test-model", input=100, output=10, cache_read=20, cost=999)
        self.scan()
        row = self.rows()[0]
        self.assertEqual((row["src_key"], row["input"]), ("logs2|1", 80))
        self.assertNotEqual(row["cost"], 999)

    def test_unavailable_old_sqlite_history_is_preserved(self):
        db.put_event(self.conn, "codex", "logs2|99", session_id="other-session", ts=TS_MS,
                     model="test-model", input=40, output=5, cost=.00013)
        self.rollout([token_event(usage())])
        self.scan()
        self.assertEqual(len(self.rows()), 2)

    def test_failure_rolls_back_source_replacement(self):
        self.log(1)
        self.scan()
        before = self.rows()
        self.rollout([token_event(usage())])
        original = db.put_event
        def failing(conn, tool, key, **kwargs):
            if kwargs.get("source_kind") == "codex_jsonl":
                raise RuntimeError("synthetic write failure")
            return original(conn, tool, key, **kwargs)
        with patch.object(db, "put_event", side_effect=failing):
            with self.assertRaises(RuntimeError):
                self.scan()
        self.assertEqual(self.rows(), before)


if __name__ == "__main__":
    unittest.main()


class TitleExtractionTest(unittest.TestCase):
    """会话标题：各工具 user 消息提取 + 上下文注入过滤。"""

    def test_claude_user_text(self):
        from tokentracker.scanners import _util
        obj = {"type": "user", "message": {"role": "user",
               "content": [{"type": "text", "text": "帮我看看 这个   问题"}]}}
        self.assertEqual(_util.user_text(obj), "帮我看看 这个 问题")
        # 字符串 content
        obj2 = {"type": "user", "message": {"role": "user", "content": "直接字符串"}}
        self.assertEqual(_util.user_text(obj2), "直接字符串")

    def test_context_injection_filtered(self):
        from tokentracker.scanners import _util
        for bad in ("# AGENTS.md instructions for /x", "<environment_context>...</environment_context>",
                    "<system-reminder>x</system-reminder>", "Caveat: ..."):
            obj = {"type": "response_item", "payload": {"role": "user",
                   "content": [{"type": "input_text", "text": bad}]}}
            self.assertEqual(_util.user_text(obj), "", bad)

    def test_codex_response_item(self):
        from tokentracker.scanners import _util
        obj = {"type": "response_item", "payload": {"type": "message", "role": "user",
               "content": [{"type": "input_text", "text": "修复登录 bug"}]}}
        self.assertEqual(_util.user_text(obj), "修复登录 bug")

    def test_assistant_and_nonuser_ignored(self):
        from tokentracker.scanners import _util
        self.assertEqual(_util.user_text({"type": "assistant", "message": {"role": "assistant", "content": "x"}}), "")
        self.assertEqual(_util.user_text({"type": "summary", "summary": "x"}), "")
        self.assertEqual(_util.user_text({}), "")


class ByteCursorTest(unittest.TestCase):
    """字节游标增量读取（cc-switch 思路）：只读新增、防截断、防写入中尾行。"""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        import os
        self.path = os.path.join(self.tmp.name, "s.jsonl")

    def _write(self, lines):
        with open(self.path, "w", encoding="utf-8") as f:
            f.writelines(lines)

    def test_delta_reads_only_new_lines(self):
        from tokentracker.scanners._util import read_jsonl_delta
        self._write(['{"a":1}\n', '{"a":2}\n'])
        items, off = read_jsonl_delta(self.path, 0)
        self.assertEqual(len(items), 2)
        # 追加一行后增量只读新行，行偏移稳定
        with open(self.path, "a", encoding="utf-8") as f:
            f.write('{"a":3}\n')
        items, off2 = read_jsonl_delta(self.path, off)
        self.assertEqual([o for o, _ in items], [off])
        self.assertEqual(items[0][1]["a"], 3)
        self.assertEqual(off2, os.path.getsize(self.path) if (os := __import__("os")) else None)

    def test_incomplete_tail_line_deferred(self):
        from tokentracker.scanners._util import read_jsonl_delta
        self._write(['{"a":1}\n', '{"a":2'])   # 尾行写入中
        items, off = read_jsonl_delta(self.path, 0)
        self.assertEqual(len(items), 1)
        self.assertLess(off, os.path.getsize(self.path))
        with open(self.path, "a", encoding="utf-8") as f:
            f.write('}\n')
        items, off = read_jsonl_delta(self.path, off)
        self.assertEqual(items[0][1]["a"], 2)

    def test_truncation_and_misaligned_offset_force_full(self):
        from tokentracker.scanners._util import read_jsonl_delta
        self._write(['{"a":1}\n'])
        size = os.path.getsize(self.path)
        self.assertEqual(read_jsonl_delta(self.path, size + 100), ([], -1))  # 截断
        self.assertEqual(read_jsonl_delta(self.path, 3), ([], -1))           # 不在行边界
