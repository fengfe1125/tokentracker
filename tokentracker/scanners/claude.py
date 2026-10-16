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

from .. import activity, db, pricing
from ._util import changed, expand, iter_jsonl, read_jsonl_delta, stat_key, user_text

NAME = "claude"
DETAIL = "~/.claude/projects/**/*.jsonl"
_VERSION = 2


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
    """解析一行 → (usage added, activity change, 标题候选)。"""
    title = user_text(obj) or None
    msg = obj.get("message")
    msg = msg if isinstance(msg, dict) else {}
    changes = {"activity_added": 0, "activity_updated": 0}
    ts = _ms_from_ts(obj.get("timestamp"), st_mtime_ms)
    content = msg.get("content") if isinstance(msg.get("content"), list) else []
    for index, part in enumerate(content):
        if not isinstance(part, dict):
            continue
        if part.get("type") == "tool_use" and part.get("name"):
            call_id = str(part.get("id") or "")
            key = f"{session_id}|tool|{call_id or fallback_key + '|' + str(index)}"
            activity.add_counts(changes, activity.put(
                conn, NAME, key, raw_name=str(part["name"]), session_id=session_id,
                call_id=call_id, started_at=ts, source_kind="claude_jsonl",
                arguments=part.get("input")))
        elif part.get("type") == "tool_result":
            status = "error" if part.get("is_error") else activity.status_from(part.get("status"))
            if status == "unknown":
                status = "success"
            changes["activity_updated"] += db.complete_activity_event(
                conn, NAME, str(part.get("tool_use_id") or part.get("toolUseId") or ""),
                status=status, ended_at=ts)
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        usage = obj.get("usage") if isinstance(obj, dict) else None
    if not isinstance(usage, dict):
        return 0, 0, changes, title
    inp = usage.get("input_tokens") or 0
    outp = usage.get("output_tokens") or 0
    cr = usage.get("cache_read_input_tokens") or 0
    cw = usage.get("cache_creation_input_tokens") or 0
    if inp + outp + cr + cw == 0:
        return 0, 0, changes, title
    model = msg.get("model") or obj.get("model") or ""
    key = (msg or {}).get("id") or f"{session_id}|{fallback_key}"
    cost, version_id = pricing.cost_for(prices, model, inp, outp, cr, cw,
                                        provider="anthropic", event_ts=ts)
    source_key = f"{session_id}|{key}"
    if obj.get("cwd"):
        db.record_project_path(conn, NAME, source_key, obj["cwd"])
    old = conn.execute(
        "SELECT input,output,cache_read,cache_write FROM usage_events WHERE tool=? AND src_key=?",
        (NAME, source_key)).fetchone()
    if old:
        # Claude Code 会为同一 message.id 写入多条流式快照。各计数器只会
        # 向完整值增长，保留逐字段最大值，避免首个不完整快照锁死用量。
        inp = max(inp, old["input"])
        outp = max(outp, old["output"])
        cr = max(cr, old["cache_read"])
        cw = max(cw, old["cache_write"])
        unchanged = (inp, outp, cr, cw) == tuple(old)
        if unchanged:
            return 0, 0, changes, title
        cost, version_id = pricing.cost_for(prices, model, inp, outp, cr, cw,
                                            provider="anthropic", event_ts=ts)
    added = db.put_event(conn, NAME, source_key,
                         session_id=session_id, project=slug, ts=ts,
                         model=model, input=inp, output=outp,
                         cache_read=cr, cache_write=cw, cost=cost,
                         replace=old is not None, provider="anthropic",
                         price_version_id=version_id)
    return (0, 1, changes, title) if old else (added, 0, changes, title)


def scan(conn, prices, full: bool = False) -> dict:
    base = root()
    cursor = db.get_scan_cursor(conn, NAME)
    effective_full = (full or cursor.get("parser_version") != _VERSION
                      or activity.needs_backfill(cursor))
    added = updated = files = activity_added = activity_updated = 0
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
            if not effective_full and not changed(cursor, path):
                continue
            files += 1
            try:
                st = os.stat(path)
                snapshot = stat_key(path)
            except OSError:
                continue
            session_id = name[:-6]
            title = None
            prev_offset = 0 if effective_full else int((cursor.get(path) or {}).get("o") or 0)
            delta = None
            if prev_offset:
                delta, new_offset = read_jsonl_delta(path, prev_offset)
                if new_offset < 0:
                    delta = None            # 截断/轮转/偏移失效 → 全量
            if delta is None:
                # 全量解析：行号兜底键，与历史数据幂等
                for lineno, obj in iter_jsonl(path):
                    a, u, ac, t = _scan_line(obj, str(lineno), session_id, slug,
                                             int(st.st_mtime * 1000), prices, conn)
                    added += a
                    updated += u
                    activity_added += ac["activity_added"]
                    activity_updated += ac["activity_updated"]
                    if t and title is None:
                        title = t
                new_offset = snapshot["s"]
            else:
                # 增量解析：字节偏移兜底键（仅追加文件中稳定）
                for line_off, obj in delta:
                    a, u, ac, t = _scan_line(obj, f"b{line_off}", session_id, slug,
                                             int(st.st_mtime * 1000), prices, conn)
                    added += a
                    updated += u
                    activity_added += ac["activity_added"]
                    activity_updated += ac["activity_updated"]
                    if t and title is None:
                        title = t
            snapshot = dict(snapshot)
            snapshot["o"] = new_offset
            cursor[path] = snapshot
            if title:
                db.set_session_title(conn, NAME, session_id, title)
    cursor["parser_version"] = _VERSION
    activity.mark_current(cursor)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": added, "updated": updated, "files": files,
            "activity_added": activity_added, "activity_updated": activity_updated}
