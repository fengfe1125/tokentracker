"""Claude Code 扫描器：~/.claude/projects/<slug>/*.jsonl

事件格式（每行一个 JSON）：
    {"type":"assistant","message":{"id":"msg_...","model":"claude-...",
     "usage":{"input_tokens":N,"output_tokens":N,
              "cache_creation_input_tokens":N,"cache_read_input_tokens":N}},
     "timestamp":"2025-..."}
以 message.id 为幂等键，重扫不重复。
增量：文件指纹（mtime+size+inode）未变跳过；变了则按字节偏移只解析新增
内容（借鉴 cc-switch 的字节游标：offset+行边界校验），截断/轮转/偏移失效
自动回退全量解析。全量解析用行号兜底键（与历史数据幂等），增量解析用
字节偏移兜底键（仅追加文件中稳定）。
"""
from __future__ import annotations

import os
from datetime import datetime

from .. import db, pricing
from ._util import changed, expand, iter_jsonl, read_jsonl_delta, stat_key, user_text

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


def _scan_line(obj, fallback_key, session_id, slug, st_mtime_ms, prices, conn):
    """解析一行 → (added, 标题候选或 None)。标题=首个真实用户消息。"""
    title = user_text(obj) or None
    msg = obj.get("message")
    msg = msg if isinstance(msg, dict) else {}
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        usage = obj.get("usage") if isinstance(obj, dict) else None
    if not isinstance(usage, dict):
        return 0, title
    inp = usage.get("input_tokens") or 0
    outp = usage.get("output_tokens") or 0
    cr = usage.get("cache_read_input_tokens") or 0
    cw = usage.get("cache_creation_input_tokens") or 0
    if inp + outp + cr + cw == 0:
        return 0, title
    model = msg.get("model") or obj.get("model") or ""
    key = (msg or {}).get("id") or f"{session_id}|{fallback_key}"
    ts = _ms_from_ts(obj.get("timestamp"), st_mtime_ms)
    cost, _ = pricing.cost_for(prices, model, inp, outp, cr, cw)
    added = db.put_event(conn, NAME, f"{session_id}|{key}",
                         session_id=session_id, project=slug, ts=ts,
                         model=model, input=inp, output=outp,
                         cache_read=cr, cache_write=cw, cost=cost)
    return added, title


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
            title = None
            prev_offset = 0 if full else int((cursor.get(path) or {}).get("o") or 0)
            delta = None
            if prev_offset:
                delta, new_offset = read_jsonl_delta(path, prev_offset)
                if new_offset < 0:
                    delta = None            # 截断/轮转/偏移失效 → 全量
            if delta is None:
                # 全量解析：行号兜底键，与历史数据幂等
                for lineno, obj in iter_jsonl(path):
                    a, t = _scan_line(obj, str(lineno), session_id, slug,
                                      int(st.st_mtime * 1000), prices, conn)
                    added += a
                    if t and title is None:
                        title = t
                new_offset = snapshot["s"]
            else:
                # 增量解析：字节偏移兜底键（仅追加文件中稳定）
                for line_off, obj in delta:
                    a, t = _scan_line(obj, f"b{line_off}", session_id, slug,
                                      int(st.st_mtime * 1000), prices, conn)
                    added += a
                    if t and title is None:
                        title = t
            snapshot = dict(snapshot)
            snapshot["o"] = new_offset
            cursor[path] = snapshot
            if title:
                db.set_session_title(conn, NAME, session_id, title)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": added, "updated": updated, "files": files}
