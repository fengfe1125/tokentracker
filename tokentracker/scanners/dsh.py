"""DSH (DeepSeek Harness) 扫描器：~/.dsh/sessions/**/session.jsonl.zstd

zstd 压缩 JSONL 事件流。用量在两种事件里：
  1) {"type":"assistant/chunk","data":{"turn":t,"step":s,"chunk":{"type":"usage","usage":{...}}}}
  2) {"type":"usage","seq":N,"data":{...}}（如存在）
幂等键：会话内 (turn, step) 唯一。增量：文件 mtime+size。
"""
from __future__ import annotations

import os

from .. import db, pricing
from ._util import changed, expand, iter_zstd_jsonl, stat_key

NAME = "dsh"
DETAIL = "~/.dsh/sessions/**/session.jsonl.zstd"


def root() -> str:
    return expand(os.environ.get("DSH_SESSIONS_DIR") or "~/.dsh/sessions")


def detect() -> bool:
    return os.path.isdir(root())


def scan(conn, prices, full: bool = False) -> dict:
    base = root()
    cursor = db.get_scan_cursor(conn, NAME)
    added = updated = files = 0
    for dirpath, _dirs, names in os.walk(base):
        # 一级子目录是 workspace slug，二级是 session id
        rel = os.path.relpath(dirpath, base)
        parts = rel.split(os.sep) if rel != "." else []
        for name in sorted(names):
            if not name.endswith(".jsonl.zstd"):
                continue
            path = os.path.join(dirpath, name)
            if not full and not changed(cursor, path):
                continue
            files += 1
            # 没有 session 事件的文件：用文件名兜底，避免空 session_id 的
            # (turn, step) 键在不同会话文件间互相碰撞丢数据
            fallback_id = name[: -len(".jsonl.zstd")]
            session_id = ""
            project = parts[0] if len(parts) >= 1 else ""
            model = ""
            for lineno, obj in iter_zstd_jsonl(path):
                if not isinstance(obj, dict):
                    continue
                t = obj.get("type", "")
                if t == "session":
                    session_id = obj.get("id") or (parts[1] if len(parts) >= 2 else "")
                    project = obj.get("cwd") or project
                elif t == "request/header":
                    cfg = (obj.get("data") or {}).get("header") or {}
                    m = (cfg.get("config") or {}).get("model") or ""
                    if m:
                        model = m
                elif t == "assistant/chunk":
                    data = obj.get("data") or {}
                    chunk = data.get("chunk") or {}
                    if chunk.get("type") == "usage" and isinstance(chunk.get("usage"), dict):
                        u = chunk["usage"]
                        inp = u.get("inputTokens") or 0
                        outp = u.get("outputTokens") or 0
                        cr = u.get("cacheReadTokens") or u.get("cacheRead") or 0
                        cw = u.get("cacheWriteTokens") or u.get("cacheWrite") or 0
                        if inp + outp + cr + cw == 0:
                            continue
                        ts = obj.get("time") or 0
                        sid = session_id or fallback_id
                        key = f"{sid}|{data.get('turn')}|{data.get('step')}"
                        cost, _ = pricing.cost_for(prices, model, inp, outp, cr, cw)
                        added += db.put_event(conn, NAME, key, session_id=sid,
                                              project=project, ts=int(ts), model=model,
                                              input=inp, output=outp, cache_read=cr,
                                              cache_write=cw, cost=cost)
                elif t == "usage":
                    # 顶层 usage 事件（兜底）
                    data = obj.get("data") or {}
                    u = data.get("usage") if isinstance(data.get("usage"), dict) else data
                    inp = u.get("inputTokens") or u.get("input") or 0
                    outp = u.get("outputTokens") or u.get("output") or 0
                    if inp + outp == 0:
                        continue
                    sid = session_id or fallback_id
                    key = f"{sid}|top|{obj.get('seq')}"
                    cost, _ = pricing.cost_for(prices, model, inp, outp, 0, 0)
                    added += db.put_event(conn, NAME, key, session_id=sid,
                                          project=project, ts=int(obj.get("time") or 0),
                                          model=model, input=inp, output=outp, cost=cost)
            cursor[path] = stat_key(path)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": added, "updated": updated, "files": files}