"""Codex rollout JSONL, supplemented by SQLite turn telemetry.

Input is normalized to exclude cache reads/writes. Rollout cumulative snapshots
are differenced. When both sources describe a turn, rollout takes precedence;
missing turn identity requires session-level precedence.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime

from .. import activity, db, pricing
from ._util import changed, expand, iter_jsonl, sqlite_ro, stat_key, user_text

NAME = "codex"
DETAIL = "~/.codex/logs_2.sqlite 或 ~/.codex/sessions/"
_VERSION = 4
_JSONL = "codex_jsonl"
_SQLITE = "codex_sqlite"
_FIELDS = re.compile(
    r"(?<![\w])(?:codex\.turn\.token_usage\.)?"
    r"(input_tokens|cached_input_tokens|cache_write_input_tokens|output_tokens)=(\d+)"
)
_MODEL = re.compile(r"\bmodel=[\"']?([\w./:\-]+)")
_THREAD = re.compile(r"\bthread\.id=[\"']?([\w\-]+)")
_TURN = re.compile(r"\bturn\.id=[\"']?([\w\-]+)")
_ALIASES = (
    ("input_tokens", "input"), ("output_tokens", "output"),
    ("cached_input_tokens", "cache_read"),
    ("cache_write_input_tokens", "cache_creation_input_tokens", "cache_write"),
)
_TOOL_CALL_TYPES = {
    "function_call", "custom_tool_call", "mcp_call", "local_shell_call",
    "shell_call", "computer_call", "apply_patch_call",
}
_TOOL_OUTPUT_TYPES = {
    "function_call_output", "custom_tool_call_output", "mcp_call_output",
    "local_shell_call_output", "shell_call_output", "computer_call_output",
    "apply_patch_call_output",
}


def sqlite_path() -> str:
    return expand(os.environ.get("CODEX_LOGS_DB") or "~/.codex/logs_2.sqlite")


def legacy_dir() -> str:
    return expand(os.environ.get("CODEX_SESSIONS_DIR") or "~/.codex/sessions")


def detect() -> bool:
    return os.path.isfile(sqlite_path()) or os.path.isdir(legacy_dir())


def _timestamp(value) -> int:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value * 1000 if value < 1e12 else value)
    if isinstance(value, str):
        try:
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
        except ValueError:
            pass
    return 0


def _counts(raw):
    """Validate counters before permitting a source to replace existing data."""
    if not isinstance(raw, dict) or not any(k in raw for keys in _ALIASES for k in keys):
        return None
    values = []
    for keys in _ALIASES:
        value = next((raw[k] for k in keys if k in raw), 0)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            return None
        values.append(value)
    return tuple(values)


def _normalized(counts):
    inp, out, cached, written = counts
    return max(inp - cached - written, 0), out, cached, written


def _put(conn, prices, key, sid, turn, model, ts, counts, kind,
         project="", quality="exact"):
    inp, out, cached, written = _normalized(counts)
    cost, _ = pricing.cost_for(prices, model, inp, out, cached, written)
    exists = conn.execute("SELECT 1 FROM usage_events WHERE tool=? AND src_key=?", (NAME, key)).fetchone()
    db.put_event(conn, NAME, key, session_id=sid, project=project, ts=ts or 1,
                 model=model, input=inp, output=out, cache_read=cached,
                 cache_write=written, cost=cost, replace=True,
                 time_quality=quality if ts > 0 else "unallocated",
                 cost_source="estimate", source_kind=kind, source_scope=turn)
    return (0, 1) if exists else (1, 0)


def _covered_by_jsonl(conn, sid, turn):
    sql = "SELECT 1 FROM usage_events WHERE tool=? AND session_id=? AND source_kind=?"
    args = [NAME, sid, _JSONL]
    if turn:
        sql += " AND (source_scope=? OR source_scope='')"
        args.append(turn)
    return conn.execute(sql + " LIMIT 1", args).fetchone() is not None


def _jsonl_counts(conn, sid, turn):
    row = conn.execute(
        "SELECT COALESCE(SUM(input+cache_read+cache_write),0),COALESCE(SUM(output),0),"
        "COALESCE(SUM(cache_read),0),COALESCE(SUM(cache_write),0) FROM usage_events "
        "WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
        (NAME, sid, _JSONL, turn)).fetchone()
    return tuple(row)


def _raw_row(row):
    return (row["input"] + row["cache_read"] + row["cache_write"],
            row["output"], row["cache_read"], row["cache_write"])


def _remaining(total, known):
    # Subtract the four disjoint event categories, not inclusive input against
    # an independently subtracted cache counter.
    inp, out, cached, written = (max(a - b, 0) for a, b in
                                zip(_normalized(total), _normalized(known)))
    return inp + cached + written, out, cached, written


def _sqlite_body(body):
    # Select a single populated span, never combine two nested turns.
    spans = re.findall(r"\bturn\{([^{}]*)\}", body)
    candidates = [span for span in spans if "codex.turn.token_usage.input_tokens=" in span]
    return candidates[-1] if candidates else body


def _scan_sqlite(conn, prices, cursor, full) -> tuple[int, int, int]:
    path = sqlite_path()
    if not os.path.isfile(path):
        return 0, 0, 0
    added = updated = 0
    src = sqlite_ro(path)
    try:
        st = os.stat(path)
        identity = [st.st_dev, st.st_ino, os.path.abspath(path)]
        last = 0 if full or cursor.get("logs2_identity") != identity else cursor.get("logs2_last_id", 0)
        maximum = src.execute("SELECT COALESCE(MAX(id),0) FROM logs").fetchone()[0]
        if maximum < last:
            last = 0
        rows = src.execute(
            "SELECT id,ts,ts_nanos,feedback_log_body FROM logs WHERE id>? "
            "AND feedback_log_body LIKE '%codex.turn.token_usage.input_tokens=%' ORDER BY id", (last,))
        for row in rows:
            last = row["id"]
            body = _sqlite_body(row["feedback_log_body"] or "")
            counts = _counts({key: int(value) for key, value in _FIELDS.findall(body)})
            if counts is None or not any(counts):
                continue
            thread = _THREAD.search(body)
            turn_match = _TURN.search(body)
            turn = turn_match.group(1) if turn_match else ""
            sid = thread.group(1) if thread else turn or str(row["id"])
            model_match = _MODEL.search(body)
            model = model_match.group(1) if model_match else ""
            ts_raw = row["ts"] or 0
            ts = int(ts_raw / 1e6) if ts_raw > 1e14 else _timestamp(ts_raw)
            if 0 < ts_raw < 1e11:
                ts += int((row["ts_nanos"] or 0) // 1_000_000)
            key = f"logs2|{row['id']}"
            old = conn.execute("SELECT * FROM usage_events WHERE tool=? AND src_key=?", (NAME, key)).fetchone()
            # A replaced source may reuse row IDs belonging to another session.
            if old and (old["session_id"] != sid or
                        (old["source_scope"] and old["source_scope"] != turn)):
                key = f"logs2|{sid}|{turn}|{row['id']}"
            if _covered_by_jsonl(conn, sid, turn):
                unscoped = conn.execute(
                    "SELECT 1 FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope='' LIMIT 1",
                    (NAME, sid, _JSONL)).fetchone()
                if not turn or unscoped:
                    conn.execute("DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?", (NAME, key, sid))
                    continue
                # A still-growing rollout may contain only part of this turn.
                # Keep the verified remainder, rather than lose later calls.
                counts = _remaining(counts, _jsonl_counts(conn, sid, turn))
                if not any(counts):
                    conn.execute("DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
                                 (NAME, sid, _SQLITE, turn))
                    conn.execute("DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?", (NAME, key, sid))
                    continue
            if turn:
                same = conn.execute(
                    "SELECT * FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=? ORDER BY id LIMIT 1",
                    (NAME, sid, _SQLITE, turn)).fetchone()
                if same:
                    # Several log lines carry one turn total. Reuse its first
                    # source key and retain the largest complete snapshot.
                    if same["src_key"] != key:
                        conn.execute("DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?", (NAME, key, sid))
                    key = same["src_key"]
                    existing = _raw_row(same)
                    if sum(counts[:2]) < sum(existing[:2]):
                        continue
            a, u = _put(conn, prices, key, sid, turn, model, ts, counts, _SQLITE)
            added += a
            updated += u
        cursor["logs2_last_id"] = last
        cursor["logs2_identity"] = identity
    finally:
        src.close()
    return added, updated, 1


def _rollout_events(path):
    sid = os.path.basename(path)[:-6]
    project = os.path.dirname(path)
    model = turn = ""
    sid_from_meta = False
    previous = None
    fallback_seen = set()
    title = None
    for lineno, obj in iter_jsonl(path):
        if not isinstance(obj, dict):
            continue
        if title is None:
            text = user_text(obj)
            if text:
                title = text
        payload = obj.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        kind = obj.get("type")
        if kind == "session_meta":
            # A subagent/fork rollout replays the parent session_meta: only the
            # first (own) meta may set the sid, otherwise the child's usage is
            # attributed to the parent and the child's SQLite telemetry is
            # counted again because JSONL coverage is looked up under the child.
            if not sid_from_meta and payload.get("id"):
                sid = str(payload.get("id"))
                sid_from_meta = True
            project = str(payload.get("cwd") or project)
            continue
        if kind == "turn_context":
            model = str(payload.get("model") or model)
            turn = str(payload.get("turn_id") or turn)
            continue
        if kind == "event_msg" and payload.get("type") == "task_started":
            turn = str(payload.get("turn_id") or "")
            continue
        if kind == "event_msg" and payload.get("type") in ("task_complete", "turn_aborted"):
            turn = ""
            continue
        ts = _timestamp(obj.get("timestamp"))
        quality = "exact"
        event_turn = str(payload.get("turn_id") or obj.get("turn_id") or turn)
        if kind == "event_msg" and payload.get("type") == "token_count":
            info = payload.get("info")
            if not isinstance(info, dict):
                continue
            total = _counts(info.get("total_token_usage"))
            last = _counts(info.get("last_token_usage"))
            if total is not None:
                if previous is None:
                    counts = total
                    # A partial export can start with lifetime usage. Keep it
                    # without pretending it all occurred in the current turn.
                    if last is not None and last != total:
                        quality, event_turn = "unallocated", ""
                elif any(current < before for current, before in zip(total, previous)):
                    # Compaction may reset counters: establish a new baseline,
                    # rather than produce negative deltas or recharge context.
                    previous = total
                    continue
                else:
                    counts = tuple(current - before for current, before in zip(total, previous))
                previous = total
            elif last is not None:
                counts = last
                fingerprint = (event_turn, ts, counts)
                if fingerprint in fallback_seen:
                    continue
                fallback_seen.add(fingerprint)
                # A later cumulative snapshot already includes these calls.
                previous = tuple(a + b for a, b in zip(previous or (0, 0, 0, 0), counts))
            else:
                continue
        else:
            raw = obj.get("tokens") if isinstance(obj.get("tokens"), dict) else obj.get("usage")
            counts = _counts(raw)
            if counts is None:
                continue
            sid = str(obj.get("thread_id") or obj.get("session_id") or sid)
            model = str(obj.get("model") or obj.get("modelId") or model)
        if not any(counts):
            continue
        yield {"key": f"legacy|{path}|{lineno}", "sid": sid, "turn": event_turn,
               "model": model, "ts": ts, "counts": counts, "project": project,
               "quality": quality}
    if title:
        yield {"key": None, "title": title, "sid": sid, "project": project}


def _scan_rollout_activity(conn, path):
    sid = os.path.basename(path)[:-6]
    turn = ""
    added = updated = 0
    for lineno, obj in iter_jsonl(path):
        if not isinstance(obj, dict):
            continue
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        kind = obj.get("type")
        if kind == "session_meta":
            sid = str(payload.get("id") or sid)
            continue
        if kind == "turn_context":
            turn = str(payload.get("turn_id") or turn)
            continue
        if kind == "event_msg" and payload.get("type") == "task_started":
            turn = str(payload.get("turn_id") or turn)
            continue
        if kind != "response_item":
            continue
        item_type = payload.get("type")
        ts = _timestamp(obj.get("timestamp")) or None
        call_id = str(payload.get("call_id") or payload.get("id") or "")
        if item_type in _TOOL_CALL_TYPES:
            raw_name = payload.get("name")
            if not raw_name:
                if item_type in ("local_shell_call", "shell_call"):
                    raw_name = "shell"
                elif item_type == "apply_patch_call":
                    raw_name = "apply_patch"
                elif item_type == "computer_call":
                    raw_name = "computer"
            if not raw_name:
                continue
            arguments = payload.get("arguments")
            if arguments is None:
                arguments = payload.get("input") if "input" in payload else payload.get("action")
            source_key = f"{os.path.realpath(path)}|response|{payload.get('id') or call_id or lineno}"
            change = activity.put(
                conn, NAME, source_key, raw_name=str(raw_name), session_id=sid,
                turn_id=turn, call_id=call_id, started_at=ts,
                source_kind="codex_rollout", arguments=arguments, allow_skill_path=True)
            added += change["added"]
            updated += change["updated"]
            if str(raw_name) == "exec" and isinstance(arguments, str):
                for index, inner in enumerate(activity.inferred_codex_tools(arguments)):
                    child = activity.put(
                        conn, NAME, f"{source_key}|inner|{index}", raw_name=inner,
                        session_id=sid, turn_id=turn, parent_call_id=call_id,
                        started_at=ts, source_kind="codex_exec_payload",
                        confidence="derived")
                    added += child["added"]
                    updated += child["updated"]
        elif item_type in _TOOL_OUTPUT_TYPES:
            status = activity.status_from(payload.get("status"))
            output = payload.get("output")
            if status == "unknown" and isinstance(output, dict):
                status = "error" if output.get("is_error") or output.get("error") else "success"
            if status == "unknown":
                status = "success"
            updated += db.complete_activity_event(conn, NAME, call_id, status=status, ended_at=ts)
    return added, updated


def _replace_sqlite_scope(conn, prices, event, previous_jsonl):
    sid, turn = event["sid"], event["turn"]
    if not turn:
        conn.execute("DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=?",
                     (NAME, sid, _SQLITE))
        return
    conn.execute("DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=''",
                 (NAME, sid, _SQLITE))
    same = conn.execute(
        "SELECT * FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
        (NAME, sid, _SQLITE, turn)).fetchone()
    if same:
        total = tuple(a + b for a, b in zip(_raw_row(same), previous_jsonl))
        remaining = _remaining(total, _jsonl_counts(conn, sid, turn))
        if any(remaining):
            _put(conn, prices, same["src_key"], sid, turn, same["model"], same["ts"],
                 remaining, _SQLITE, project=same["project"], quality=same["time_quality"])
        else:
            conn.execute("DELETE FROM usage_events WHERE tool=? AND src_key=?", (NAME, same["src_key"]))


def _scan_legacy(conn, prices, cursor, full) -> tuple[int, int, int, int, int]:
    base = legacy_dir()
    if not os.path.isdir(base):
        return 0, 0, 0, 0, 0
    added = updated = files = activity_added = activity_updated = 0
    for dirpath, _dirs, names in os.walk(base):
        for name in sorted(names):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            if not full and not changed(cursor, path):
                continue
            try:
                snapshot = stat_key(path)
            except OSError:
                continue
            files += 1
            for event in _rollout_events(path):
                if not event["key"]:   # 会话标题事件：首个真实用户消息
                    db.set_session_title(conn, NAME, event["sid"], event["title"])
                    continue
                # Only a validated, nonempty payload authorizes replacement.
                previous_jsonl = _jsonl_counts(conn, event["sid"], event["turn"])
                a, u = _put(conn, prices, event["key"], event["sid"], event["turn"],
                            event["model"], event["ts"], event["counts"], _JSONL,
                            project=event["project"], quality=event["quality"])
                _replace_sqlite_scope(conn, prices, event, previous_jsonl)
                added += a
                updated += u
            aa, au = _scan_rollout_activity(conn, path)
            activity_added += aa
            activity_updated += au
            cursor[path] = snapshot
    return added, updated, files, activity_added, activity_updated


def scan(conn, prices, full: bool = False) -> dict:
    cursor = db.get_scan_cursor(conn, NAME)
    full = full or cursor.get("parser_version") != _VERSION or activity.needs_backfill(cursor)
    # Roll back source deletion, insertion and cursor movement together, even
    # if the caller catches scanner errors and continues with another tool.
    conn.execute("SAVEPOINT codex_scan")
    try:
        # JSONL 先扫（主源），SQLite 后扫补缺：同一趟内去重查询就能看到
        # 最新的 JSONL 归因，归因变更无需等下一次全量扫描才收敛。
        a2, u2, f2, aa2, au2 = _scan_legacy(conn, prices, cursor, full)
        a1, u1, f1 = _scan_sqlite(conn, prices, cursor, full)
        ambiguous = conn.execute(
            "SELECT old.id FROM usage_events old WHERE old.tool=? AND old.source_kind='' "
            "AND old.src_key LIKE 'logs2|%' AND EXISTS "
            "(SELECT 1 FROM usage_events new WHERE new.tool=old.tool AND new.session_id=old.session_id AND new.source_kind=?)",
            (NAME, _JSONL)).fetchall()
        if ambiguous:
            conn.executemany("UPDATE usage_events SET time_quality='unallocated' WHERE id=?", [(r[0],) for r in ambiguous])
        cursor["parser_version"] = _VERSION
        activity.mark_current(cursor)
        conn.execute("INSERT OR REPLACE INTO scan_state(tool,cursor) VALUES (?,?)", (NAME, json.dumps(cursor)))
        conn.execute("RELEASE SAVEPOINT codex_scan")
    except Exception:
        conn.execute("ROLLBACK TO SAVEPOINT codex_scan")
        conn.execute("RELEASE SAVEPOINT codex_scan")
        raise
    result = {"added": a1 + a2, "updated": u1 + u2, "files": f1 + f2,
              "activity_added": aa2, "activity_updated": au2}
    if ambiguous:
        result["warning"] = f"保留 {len(ambiguous)} 条无法核实与 JSONL 对应关系的旧 Codex 日志；已标记时间未知，可能存在重复历史。"
    return result
