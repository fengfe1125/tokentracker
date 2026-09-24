"""Pi (Pi Coding Agent) 扫描器：~/.pi/agent/sessions/**/*.jsonl（Oh My Pi: ~/.omp）

事件流：
    {"type":"session","id":...,"cwd":...}
    {"type":"message","id":"...","timestamp":"ISO","message":{
       "role":"assistant","model":"claude-opus-5",
       "usage":{"input":N,"output":N,"cacheRead":N,"cacheWrite":N,
                "totalTokens":N,"cost":{"input":..,"output":..,"total":..}}}}
幂等键：文件内事件 id。增量：文件 mtime+size。
"""
from __future__ import annotations

import os
from datetime import datetime

from .. import activity, db, pricing
from ._util import changed, expand, iter_jsonl, stat_key, user_text

NAME = "pi"
DETAIL = "~/.pi/agent/sessions/**/*.jsonl"


def roots() -> list[str]:
    out = [
        expand(os.environ.get("PI_HOME") or "~/.pi/agent/sessions"),
        expand("~/.omp"),
    ]
    return [p for p in out if os.path.isdir(p)]


def detect() -> bool:
    return bool(roots())


def _parse_ts(ts_raw) -> int:
    if isinstance(ts_raw, (int, float)):
        return int(ts_raw * 1000) if ts_raw < 1e12 else int(ts_raw)
    if isinstance(ts_raw, str):
        try:
            return int(datetime.fromisoformat(ts_raw.replace("Z", "+00:00")).timestamp() * 1000)
        except ValueError:
            return 0
    return 0


def scan(conn, prices, full: bool = False) -> dict:
    cursor = db.get_scan_cursor(conn, NAME)
    effective_full = full or activity.needs_backfill(cursor)
    added = updated = files = activity_added = activity_updated = 0
    for base in roots():
        for dirpath, _dirs, names in os.walk(base):
            for name in sorted(names):
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, name)
                if not effective_full and not changed(cursor, path):
                    continue
                try:
                    snapshot = stat_key(path)
                except OSError:
                    continue
                files += 1
                session_id = ""
                project = os.path.basename(dirpath)
                title = None
                for lineno, obj in iter_jsonl(path):
                    if not isinstance(obj, dict):
                        continue
                    if title is None:
                        text = user_text(obj)
                        if text:
                            title = text
                    t = obj.get("type")
                    if t == "session":
                        session_id = obj.get("id") or ""
                        project = obj.get("cwd") or project
                        continue
                    if t != "message":
                        continue
                    msg = obj.get("message")
                    if not isinstance(msg, dict):
                        continue
                    ts = _parse_ts(msg.get("timestamp") or obj.get("timestamp"))
                    content = msg.get("content") if isinstance(msg.get("content"), list) else []
                    for index, part in enumerate(content):
                        if not isinstance(part, dict):
                            continue
                        part_type = part.get("type")
                        if part_type == "toolCall" and part.get("name"):
                            call_id = part.get("id") or part.get("toolCallId")
                            change = activity.put(
                                conn, NAME, f"{os.path.realpath(path)}|tool|{call_id or str(obj.get('id')) + '|' + str(index)}",
                                raw_name=str(part["name"]), session_id=session_id,
                                call_id=str(call_id or ""), started_at=ts or None,
                                source_kind="pi_jsonl",
                                arguments=part.get("arguments") or part.get("input"))
                            activity_added += change["added"]
                            activity_updated += change["updated"]
                        elif part_type == "toolResult":
                            status = "error" if part.get("isError") else activity.status_from(part.get("status"))
                            if status == "unknown":
                                status = "success"
                            activity_updated += db.complete_activity_event(
                                conn, NAME, str(part.get("toolCallId") or part.get("id") or ""),
                                status=status, ended_at=ts or None)
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    inp = usage.get("input") or 0
                    outp = usage.get("output") or 0
                    cr = usage.get("cacheRead") or 0
                    cw = usage.get("cacheWrite") or 0
                    if inp + outp + cr + cw == 0:
                        continue
                    model = msg.get("model") or obj.get("modelId") or ""
                    key = f"{os.path.basename(path)}|{obj.get('id')}"
                    cost_obj = usage.get("cost") if isinstance(usage.get("cost"), dict) else {}
                    source_cost = cost_obj.get("total")
                    source_cost = source_cost if isinstance(source_cost, (int, float)) and source_cost > 0 else None
                    source_provider = str(msg.get("provider") or obj.get("provider") or "")
                    cost, resolved_provider, version_id = pricing.quote_for(
                        prices, model, inp, outp, cr, cw,
                        provider=source_provider or None, event_ts=ts)
                    provider = source_provider or resolved_provider or ""
                    if source_cost is not None:
                        cost, version_id, cost_source = source_cost, None, "native"
                    else:
                        cost_source = "estimate"
                    added += db.put_event(conn, NAME, key, session_id=session_id,
                                          project=project, ts=ts, model=str(model),
                                          input=inp, output=outp, cache_read=cr,
                                          cache_write=cw, cost=cost, provider=provider,
                                          price_version_id=version_id, cost_source=cost_source)
                cursor[path] = snapshot
                if title:
                    db.set_session_title(conn, NAME, session_id, title)
    activity.mark_current(cursor)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": added, "updated": updated, "files": files,
            "activity_added": activity_added, "activity_updated": activity_updated}
