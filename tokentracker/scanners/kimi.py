"""Kimi Code 扫描器：~/.kimi-code/server/events/session_*.jsonl（事件日志）
另有 kimi-cli：~/.kimi/sessions/（若存在，按通用 JSONL 兜底解析）。

事件日志结构：
    {"kind":"journal_header",...}
    {"kind":"event","seq":1,"envelope":{"type":"turn.step.completed",
     "timestamp":"ISO","payload":{...,"usage":{"inputOther":N,"output":N,
     "inputCacheRead":N,"inputCacheCreation":N}}}}
turn.step.completed 的 usage 是每步增量 → 直接累加，不重复计数。
"""
from __future__ import annotations

import os
from datetime import datetime

from .. import db, pricing
from ._util import changed, expand, iter_jsonl, stat_key

NAME = "kimi"
DETAIL = "~/.kimi-code/server/events/session_*.jsonl"


def journal_dir() -> str:
    return expand(os.environ.get("KIMI_CODE_HOME") or "~/.kimi-code/server/events")


def cli_dir() -> str:
    return expand("~/.kimi/sessions")


def detect() -> bool:
    return os.path.isdir(journal_dir()) or os.path.isdir(cli_dir())


def _parse_ts(ts_raw) -> int:
    if isinstance(ts_raw, (int, float)):
        return int(ts_raw * 1000) if ts_raw < 1e12 else int(ts_raw)
    if isinstance(ts_raw, str):
        try:
            return int(datetime.fromisoformat(ts_raw.replace("Z", "+00:00")).timestamp() * 1000)
        except ValueError:
            return 0
    return 0


def _scan_journal(conn, prices, cursor, full) -> tuple[int, int, int]:
    base = journal_dir()
    if not os.path.isdir(base):
        return 0, 0, 0
    added = updated = files = 0
    for dirpath, _dirs, names in os.walk(base):
        for name in sorted(names):
            if not (name.startswith("session_") and name.endswith(".jsonl")):
                continue
            path = os.path.join(dirpath, name)
            if not full and not changed(cursor, path):
                continue
            files += 1
            session_id = name[len("session_"):-len(".jsonl")]
            project = ""
            model_hint = ""
            for lineno, obj in iter_jsonl(path):
                if not isinstance(obj, dict):
                    continue
                kind = obj.get("kind")
                env = obj.get("envelope") or {}
                payload = env.get("payload") or {}
                if kind == "event" and env.get("type") == "event.session.created":
                    sess = payload.get("session") or {}
                    meta = sess.get("metadata") or {}
                    project = meta.get("cwd") or project
                    continue
                if kind != "event" or env.get("type") != "turn.step.completed":
                    continue
                usage = payload.get("usage")
                if not isinstance(usage, dict):
                    continue
                inp = usage.get("inputOther") or 0          # 非缓存输入增量
                outp = usage.get("output") or 0
                cr = usage.get("inputCacheRead") or 0
                cw = usage.get("inputCacheCreation") or 0
                if inp + outp + cr + cw == 0:
                    continue
                m = payload.get("model")
                if isinstance(m, dict):
                    m = m.get("id")
                if m:
                    model_hint = str(m)
                # 事件日志不携带模型字段，默认 kimi-code（k3 家族）
                model = model_hint or "kimi-code"
                ts = _parse_ts(env.get("timestamp") or obj.get("time"))
                key = f"{session_id}|step|{obj.get('seq')}"
                cost, _ = pricing.cost_for(prices, model, inp, outp, cr, cw)
                added += db.put_event(conn, NAME, key, session_id=session_id,
                                      project=project, ts=ts, model=str(model),
                                      input=inp, output=outp, cache_read=cr,
                                      cache_write=cw, cost=cost)
            cursor[path] = stat_key(path)
    return added, updated, files


def _scan_cli(conn, prices, cursor, full) -> tuple[int, int, int]:
    base = cli_dir()
    if not os.path.isdir(base):
        return 0, 0, 0
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
                usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else None
                if not usage:
                    continue
                inp = usage.get("input") or usage.get("input_tokens") or 0
                outp = usage.get("output") or usage.get("output_tokens") or 0
                if inp + outp == 0:
                    continue
                model = obj.get("model") or ""
                cost, _ = pricing.cost_for(prices, model, inp, outp, 0, 0)
                added += db.put_event(conn, NAME, f"cli|{path}|{lineno}",
                                      session_id=name[:-6], project=dirpath,
                                      ts=_parse_ts(obj.get("timestamp") or 0), model=str(model),
                                      input=inp, output=outp, cost=cost)
            cursor[path] = stat_key(path)
    return added, updated, files


def scan(conn, prices, full: bool = False) -> dict:
    cursor = db.get_scan_cursor(conn, NAME)
    a1, u1, f1 = _scan_journal(conn, prices, cursor, full)
    a2, u2, f2 = _scan_cli(conn, prices, cursor, full)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": a1 + a2, "updated": u1 + u2, "files": f1 + f2}