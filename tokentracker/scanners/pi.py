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

from .. import db, pricing
from ._util import changed, expand, iter_jsonl, stat_key

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
    added = updated = files = 0
    for base in roots():
        for dirpath, _dirs, names in os.walk(base):
            for name in sorted(names):
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, name)
                if not full and not changed(cursor, path):
                    continue
                files += 1
                session_id = ""
                project = os.path.basename(dirpath)
                for lineno, obj in iter_jsonl(path):
                    if not isinstance(obj, dict):
                        continue
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
                    ts = _parse_ts(msg.get("timestamp") or obj.get("timestamp"))
                    key = f"{os.path.basename(path)}|{obj.get('id')}"
                    cost_obj = usage.get("cost") if isinstance(usage.get("cost"), dict) else {}
                    cost = cost_obj.get("total") or 0
                    if cost <= 0:
                        cost, _ = pricing.cost_for(prices, model, inp, outp, cr, cw)
                    db.put_event(conn, NAME, key, session_id=session_id,
                                 project=project, ts=ts, model=str(model),
                                 input=inp, output=outp, cache_read=cr,
                                 cache_write=cw, cost=cost)
                    added += 1
                cursor[path] = stat_key(path)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": added, "updated": updated, "files": files}