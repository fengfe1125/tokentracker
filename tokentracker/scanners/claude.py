"""Claude Code 扫描器：~/.claude/projects/<slug>/*.jsonl

事件格式（每行一个 JSON）：
    {"type":"assistant","message":{"id":"msg_...","model":"claude-...",
     "usage":{"input_tokens":N,"output_tokens":N,
              "cache_creation_input_tokens":N,"cache_read_input_tokens":N}},
     "timestamp":"2025-..."}
以 message.id 为幂等键，重扫不重复。增量：文件 mtime+size 未变则跳过。
"""
from __future__ import annotations

import os
from datetime import datetime

from .. import db, pricing
from ._util import changed, expand, iter_jsonl, stat_key

NAME = "claude"
DETAIL = "~/.claude/projects/**/*.jsonl"


def root() -> str:
    return os.environ.get("CLAUDE_PROJECTS_DIR") or expand("~/.claude/projects")


def detect() -> bool:
    return os.path.isdir(root())


def _ms_from_ts(ts: str | None, fallback_ms: int) -> int:
    if ts:
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            return int(dt.timestamp() * 1000)
        except ValueError:
            pass
    return fallback_ms


def scan(conn, prices, full: bool = False) -> dict:
    base = root()
    cursor = db.get_scan_cursor(conn, NAME)
    added = updated = files = 0
    for dirpath, _dirs, names in os.walk(base):
        if dirpath == base:
            continue  # slug 目录在下一层
        slug = os.path.basename(
            os.path.dirname(dirpath) if os.path.basename(dirpath) == "projects" else dirpath
        ) or dirpath
        for name in sorted(names):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            if not full and not changed(cursor, path):
                continue
            files += 1
            try:
                st = os.stat(path)
                snapshot = stat_key(path)
            except OSError:
                continue
            session_id = name[:-6]
            for lineno, obj in iter_jsonl(path):
                if not isinstance(obj, dict):
                    continue
                msg = obj.get("message")
                msg = msg if isinstance(msg, dict) else {}
                usage = msg.get("usage")
                if not isinstance(usage, dict):
                    usage = obj.get("usage") if isinstance(obj, dict) else None
                if not isinstance(usage, dict):
                    continue
                inp = usage.get("input_tokens") or 0
                outp = usage.get("output_tokens") or 0
                cr = usage.get("cache_read_input_tokens") or 0
                cw = usage.get("cache_creation_input_tokens") or 0
                if inp + outp + cr + cw == 0:
                    continue
                model = msg.get("model") or obj.get("model") or ""
                key = (msg or {}).get("id") or f"{session_id}|{lineno}"
                ts = _ms_from_ts(obj.get("timestamp"), int(st.st_mtime * 1000))
                cost, _ = pricing.cost_for(prices, model, inp, outp, cr, cw)
                added += db.put_event(conn, NAME, f"{session_id}|{key}",
                                      session_id=session_id, project=slug, ts=ts,
                                      model=model, input=inp, output=outp,
                                      cache_read=cr, cache_write=cw, cost=cost)
            cursor[path] = snapshot
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": added, "updated": updated, "files": files}
