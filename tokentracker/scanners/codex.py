"""Codex CLI 扫描器。

新版：~/.codex/logs_2.sqlite，logs.feedback_log_body 内嵌结构化字段：
    codex.turn.token_usage.input_tokens=… cached_input_tokens=… 
    cache_write_input_tokens=… output_tokens=… total_tokens=…
    model=gpt-5.6-luna thread.id=… turn.id=…
增量：记录最大行 id。
旧版：~/.codex/sessions/**/*.jsonl（带 tokens/usage 字段的行）。
"""
from __future__ import annotations

import os
import re

from .. import db, pricing
from ._util import expand, sqlite_ro, iter_jsonl

NAME = "codex"
DETAIL = "~/.codex/logs_2.sqlite 或 ~/.codex/sessions/"

_TU = re.compile(
    r"codex\.turn\.token_usage\.input_tokens=(\d+).*?"
    r"cached_input_tokens=(\d+).*?"
    r"cache_write_input_tokens=(\d+).*?"
    r"output_tokens=(\d+).*?"
    r"total_tokens=(\d+)",
    re.S,
)
_MODEL = re.compile(r"\bmodel=([\w.\-]+)")
_THREAD = re.compile(r"\bthread\.id=([0-9a-f\-]+)")
_TURN = re.compile(r"\bturn\.id=([0-9a-f\-]+)")


def sqlite_path() -> str:
    return expand(os.environ.get("CODEX_LOGS_DB") or "~/.codex/logs_2.sqlite")


def legacy_dir() -> str:
    return expand(os.environ.get("CODEX_SESSIONS_DIR") or "~/.codex/sessions")


def detect() -> bool:
    return os.path.isfile(sqlite_path()) or os.path.isdir(legacy_dir())


def _scan_sqlite(conn, prices, cursor, full) -> tuple[int, int, int]:
    db_path = sqlite_path()
    if not os.path.isfile(db_path):
        return 0, 0, 0
    added = updated = 0
    try:
        src = sqlite_ro(db_path)
    except Exception:
        return 0, 0, 0
    last_id = 0 if full else cursor.get("logs2_last_id", 0)
    rows = src.execute(
        """
        SELECT id, ts, ts_nanos, feedback_log_body FROM logs
        WHERE id > ? AND feedback_log_body LIKE '%codex.turn.token_usage.input_tokens=%'
        ORDER BY id
        """,
        (last_id,),
    )
    for r in rows:
        body = r["feedback_log_body"] or ""
        m = _TU.search(body)
        if not m:
            continue
        inp, cached, cw, outp, total = map(int, m.groups())
        model_m = _MODEL.search(body)
        model = model_m.group(1) if model_m else ""
        thread_m = _THREAD.search(body)
        turn_m = _TURN.search(body)
        sid = (thread_m or turn_m).group(1) if (thread_m or turn_m) else str(r["id"])
        # logs.ts 单位为秒，ts_nanos 为秒内纳秒小数
        ts_raw = r["ts"] or 0
        ts_nanos = r["ts_nanos"] or 0
        if ts_raw > 1e14:
            ts = int(ts_raw / 1_000_000)              # 纳秒
        elif ts_raw > 1e11:
            ts = int(ts_raw)                           # 毫秒
        else:
            ts = int(ts_raw * 1000 + ts_nanos // 1_000_000)  # 秒 + 纳秒
        cost, _ = pricing.cost_for(prices, model, inp, outp, cached, cw)
        db.put_event(conn, NAME, f"logs2|{r['id']}",
                     session_id=sid, project="", ts=ts,
                     model=model, input=inp, output=outp,
                     cache_read=cached, cache_write=cw, cost=cost)
        added += 1
        last_id = r["id"]
    src.close()
    cursor["logs2_last_id"] = last_id
    return added, updated, 1


def _scan_legacy(conn, prices, cursor, full) -> tuple[int, int, int]:
    base = legacy_dir()
    if not os.path.isdir(base):
        return 0, 0, 0
    from ._util import changed, stat_key
    added = updated = files = 0
    for dirpath, _dirs, names in os.walk(base):
        for name in sorted(names):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            if not full and not changed(cursor, path):
                continue
            files += 1
            for lineno, obj in iter_jsonl(path):
                if not isinstance(obj, dict):
                    continue
                toks = obj.get("tokens") if isinstance(obj.get("tokens"), dict) else None
                usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else None
                src = toks or usage
                if not src:
                    continue
                inp = src.get("input") or src.get("input_tokens") or 0
                outp = src.get("output") or src.get("output_tokens") or 0
                cr = src.get("cache_read") or src.get("cached_input_tokens") or 0
                cw = src.get("cache_write") or src.get("cache_creation_input_tokens") or 0
                if inp + outp + cr + cw == 0:
                    continue
                model = obj.get("model") or obj.get("modelId") or ""
                ts = obj.get("timestamp") or ""
                ts_ms = 0
                if isinstance(ts, (int, float)):
                    ts_ms = int(ts * 1000 if ts < 1e12 else ts)
                sid = obj.get("thread_id") or obj.get("session_id") or name[:-6]
                cost, _ = pricing.cost_for(prices, model, inp, outp, cr, cw)
                db.put_event(conn, NAME, f"legacy|{path}|{lineno}",
                             session_id=str(sid), project=dirpath, ts=ts_ms,
                             model=model, input=inp, output=outp,
                             cache_read=cr, cache_write=cw, cost=cost)
                added += 1
            cursor[path] = stat_key(path)
    return added, updated, files


def scan(conn, prices, full: bool = False) -> dict:
    cursor = db.get_scan_cursor(conn, NAME)
    a1, u1, f1 = _scan_sqlite(conn, prices, cursor, full)
    a2, u2, f2 = _scan_legacy(conn, prices, cursor, full)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": a1 + a2, "updated": u1 + u2, "files": f1 + f2}