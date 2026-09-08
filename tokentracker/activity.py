"""Shared, metadata-only normalization for agent tool activity."""
from __future__ import annotations

import json
import re

from . import db

PARSER_VERSION = 1
_SKILL_PATH = re.compile(r"(?:^|[/\\])([^/\\]+)[/\\]SKILL\.md(?:$|[\s'\"])", re.I)
_INNER_TOOL = re.compile(r"(?:await\s+)?tools\.([A-Za-z_$][\w$]*)\s*\(")
_JS_HELPERS = {"map", "filter", "reduce", "foreach", "find", "some", "every", "sort"}


def needs_backfill(cursor: dict) -> bool:
    return cursor.get("activity_parser_version") != PARSER_VERSION


def mark_current(cursor: dict) -> None:
    cursor["activity_parser_version"] = PARSER_VERSION


def namespace(raw_name: str) -> str:
    low = (raw_name or "").lower()
    if low.startswith("mcp__"):
        return low.split("__", 2)[1] if "__" in low else "mcp"
    return "built-in"


def skill_from(raw_name: str, arguments, *, allow_path=False) -> tuple[str, str]:
    low = (raw_name or "").lower()
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except (TypeError, ValueError):
            if allow_path:
                match = _SKILL_PATH.search(arguments)
                return (match.group(1), "derived") if match else ("", "")
            return "", ""
    if low in ("skill", "skill_view") and isinstance(arguments, dict):
        value = arguments.get("skill") or arguments.get("name") or arguments.get("skill_name")
        if isinstance(value, str) and value.strip():
            return value.strip(), "exact"
    if allow_path:
        text = json.dumps(arguments, ensure_ascii=False) if isinstance(arguments, (dict, list)) else str(arguments or "")
        match = _SKILL_PATH.search(text)
        if match:
            return match.group(1), "derived"
    return "", ""


def status_from(value) -> str:
    low = str(value or "").lower()
    if any(word in low for word in ("denied", "rejected", "blocked")):
        return "denied"
    if any(word in low for word in ("error", "failed", "failure")):
        return "error"
    if any(word in low for word in ("success", "completed", "complete", "done", "ok")):
        return "success"
    return "unknown"


def put(conn, agent: str, src_key: str, *, raw_name: str, session_id="", turn_id="",
        call_id="", parent_call_id="", started_at=None, ended_at=None, duration_ms=None,
        status="unknown", source_kind="", confidence="exact", arguments=None,
        allow_skill_path=False) -> dict:
    skill_name, skill_confidence = skill_from(raw_name, arguments, allow_path=allow_skill_path)
    return db.put_activity_event(
        conn, agent, src_key, session_id=session_id, turn_id=turn_id,
        raw_name=raw_name, namespace=namespace(raw_name), call_id=str(call_id or ""),
        parent_call_id=str(parent_call_id or ""), started_at=started_at, ended_at=ended_at,
        duration_ms=duration_ms, status=status, source_kind=source_kind,
        confidence=confidence, skill_name=skill_name, skill_confidence=skill_confidence)


def inferred_codex_tools(script: str) -> list[str]:
    if not isinstance(script, str):
        return []
    return [name for name in _INNER_TOOL.findall(script)
            if name.lower() not in _JS_HELPERS]


def add_counts(target: dict, change: dict) -> None:
    target["activity_added"] = target.get("activity_added", 0) + change.get("added", 0)
    target["activity_updated"] = target.get("activity_updated", 0) + change.get("updated", 0)
