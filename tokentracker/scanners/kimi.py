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

from .. import activity, db, pricing
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


def _skill_name(payload):
    """Extract only the public Skill identifier, never its arguments/content."""
    skill = payload.get("skill")
    if isinstance(skill, dict):
        skill = skill.get("name") or skill.get("skillName") or skill.get("id")
    return (payload.get("skillName") or payload.get("name") or skill
            or payload.get("skill_name") or "")


def _scan_journal(conn, prices, cursor, full) -> tuple[int, int, int]:
    base = journal_dir()
    if not os.path.isdir(base):
        return 0, 0, 0, 0, 0
    added = updated = files = activity_added = activity_updated = 0
    for dirpath, _dirs, names in os.walk(base):
        for name in sorted(names):
            if not (name.startswith("session_") and name.endswith(".jsonl")):
                continue
            path = os.path.join(dirpath, name)
            if not full and not changed(cursor, path):
                continue
            try:
                snapshot = stat_key(path)
            except OSError:
                continue
            files += 1
            session_id = name[len("session_"):-len(".jsonl")]
            project = ""
            model_hint = ""
            title = None
            for lineno, obj in iter_jsonl(path):
                if not isinstance(obj, dict):
                    continue
                kind = obj.get("kind")
                env = obj.get("envelope") or {}
                payload = env.get("payload") or {}
                event_type = env.get("type")
                ts = _parse_ts(env.get("timestamp") or obj.get("time"))
                if kind == "event" and event_type == "skill.activated":
                    skill_name = _skill_name(payload)
                    if isinstance(skill_name, str) and skill_name.strip():
                        call_id = payload.get("id") or payload.get("skillCallId") or obj.get("seq")
                        change = activity.put(
                            conn, NAME, f"{session_id}|skill|{call_id}", raw_name="Skill",
                            session_id=session_id, turn_id=str(payload.get("turnId") or ""),
                            call_id=str(call_id or ""), started_at=ts,
                            source_kind="kimi_skill_activated", confidence="exact",
                            arguments={"skill": skill_name}, event_kind="skill")
                        activity_added += change["added"]
                        activity_updated += change["updated"]
                elif kind == "event" and isinstance(event_type, str) and event_type.startswith("subagent."):
                    call_id = payload.get("id") or payload.get("agentId") or obj.get("seq")
                    parent = payload.get("parentId") or payload.get("parentAgentId") or ""
                    change = activity.put(
                        conn, NAME, f"{session_id}|agent|{call_id}",
                        raw_name=str(payload.get("name") or event_type),
                        session_id=session_id, turn_id=str(payload.get("turnId") or ""),
                        call_id=str(call_id or ""), parent_call_id=str(parent or ""),
                        started_at=ts, source_kind="kimi_subagent", event_kind="agent")
                    activity_added += change["added"]
                    activity_updated += change["updated"]
                elif kind == "event" and event_type == "tool.call.started":
                    call = payload.get("toolCall") if isinstance(payload.get("toolCall"), dict) else payload
                    raw_name = call.get("name") or call.get("toolName") or call.get("tool")
                    call_id = call.get("id") or call.get("toolCallId") or payload.get("toolCallId")
                    if raw_name:
                        change = activity.put(
                            conn, NAME, f"{session_id}|tool|{call_id or obj.get('seq')}",
                            raw_name=str(raw_name), session_id=session_id,
                            turn_id=str(payload.get("turnId") or ""), call_id=str(call_id or ""),
                            started_at=ts, source_kind="kimi_journal",
                            arguments=call.get("args") or call.get("arguments") or call.get("input"))
                        activity_added += change["added"]
                        activity_updated += change["updated"]
                elif kind == "event" and event_type == "tool.result":
                    call_id = payload.get("toolCallId") or payload.get("callId") or payload.get("id")
                    status = activity.status_from(payload.get("status") or payload.get("error"))
                    if status == "unknown":
                        status = "error" if payload.get("error") else "success"
                    activity_updated += db.complete_activity_event(
                        conn, NAME, str(call_id or ""), status=status, ended_at=ts,
                        duration_ms=payload.get("durationMs"))
                if title is None and kind == "event" and env.get("type") == "turn.started":
                    prompt = payload.get("prompt")
                    if isinstance(prompt, str) and prompt.strip():
                        title = " ".join(prompt.split())[:120]
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
                cost, version_id = pricing.cost_for(prices, model, inp, outp, cr, cw,
                                                   provider="moonshot", event_ts=ts)
                added += db.put_event(conn, NAME, key, session_id=session_id,
                                      project=project, ts=ts, model=str(model),
                                      input=inp, output=outp, cache_read=cr,
                                      cache_write=cw, cost=cost, provider="moonshot",
                                      price_version_id=version_id)
            cursor[path] = snapshot
            if title:
                db.set_session_title(conn, NAME, session_id, title)
    return added, updated, files, activity_added, activity_updated


def _scan_cli(conn, prices, cursor, full) -> tuple[int, int, int]:
    base = cli_dir()
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
                ts = _parse_ts(obj.get("timestamp") or 0)
                cost, version_id = pricing.cost_for(prices, model, inp, outp, 0, 0,
                                                   provider="moonshot", event_ts=ts)
                added += db.put_event(conn, NAME, f"cli|{path}|{lineno}",
                                      session_id=name[:-6], project=dirpath,
                                      ts=ts, model=str(model), input=inp, output=outp,
                                      cost=cost, provider="moonshot", price_version_id=version_id)
            cursor[path] = snapshot
    return added, updated, files, activity_added, activity_updated


def scan(conn, prices, full: bool = False) -> dict:
    cursor = db.get_scan_cursor(conn, NAME)
    effective_full = full or activity.needs_backfill(cursor)
    a1, u1, f1, aa1, au1 = _scan_journal(conn, prices, cursor, effective_full)
    a2, u2, f2, aa2, au2 = _scan_cli(conn, prices, cursor, effective_full)
    activity.mark_current(cursor)
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": a1 + a2, "updated": u1 + u2, "files": f1 + f2,
            "activity_added": aa1 + aa2, "activity_updated": au1 + au2}
