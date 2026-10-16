"""opencode 扫描器：~/.local/share/opencode/opencode.db

session 累计字段按持久化快照计算差量；首次存量保留为时间未分配历史。
"""
from __future__ import annotations

import json
import os

from .. import activity, db
from ._util import expand, sqlite_ro

NAME = "opencode"
DETAIL = "~/.local/share/opencode/opencode.db"


def db_path() -> str:
    return expand(os.environ.get("OPENCODE_DB") or "~/.local/share/opencode/opencode.db")


def detect() -> bool:
    return os.path.isfile(db_path())


def _model_info(raw) -> tuple[str, str]:
    if not raw:
        return "", ""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return raw, ""
    if isinstance(raw, dict):
        return (raw.get("id") or raw.get("modelID") or raw.get("model") or "",
                raw.get("providerID") or raw.get("provider") or "")
    return str(raw), ""


def scan(conn, prices, full: bool = False) -> dict:
    # Read every cumulative row: unchanged observations narrow the next interval;
    # updated_at is not a safe cursor (ties and resets can hide changed counters).
    path = db_path()
    added = updated = resets = activity_added = activity_updated = 0
    src = sqlite_ro(path)
    try:
        rows = src.execute("SELECT * FROM session").fetchall()
        observed_at = int(db.time.time() * 1000)
        for r in rows:
            model, provider = _model_info(r["model"])
            result = db.put_snapshot(
                conn, NAME, os.path.realpath(path), str(r["id"]),
                session_id=str(r["id"]), project=r["directory"] or r["title"] or "",
                model=model, provider=provider, input=r["tokens_input"], output=r["tokens_output"],
                cache_read=r["tokens_cache_read"], cache_write=r["tokens_cache_write"],
                native_cost=r["cost"], prices=prices, legacy_key=str(r["id"]), observed_at=observed_at)
            directory = r["directory"] or ""
            if directory.startswith("/"):
                for event in conn.execute("SELECT src_key FROM usage_events WHERE tool=? AND session_id=?", (NAME, str(r["id"]))).fetchall():
                    db.record_project_path(conn, NAME, event["src_key"], directory)
            db.set_session_title(conn, NAME, str(r["id"]), r["title"] or "")
            added += result["added"]
            resets += result["counter_resets"]
            updated += 1
        tables = {r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "part" in tables:
            for row in src.execute("SELECT id,session_id,time_created,time_updated,data FROM part"):
                try:
                    data = json.loads(row["data"] or "{}")
                except (TypeError, ValueError):
                    continue
                if not isinstance(data, dict) or data.get("type") != "tool" or not data.get("tool"):
                    continue
                state = data.get("state") if isinstance(data.get("state"), dict) else {}
                timing = state.get("time") if isinstance(state.get("time"), dict) else {}
                status = activity.status_from(state.get("status"))
                change = activity.put(
                    conn, NAME, f"{os.path.realpath(path)}|part|{row['id']}",
                    raw_name=str(data["tool"]), session_id=str(row["session_id"] or ""),
                    call_id=str(data.get("callID") or data.get("callId") or row["id"]),
                    started_at=timing.get("start") or row["time_created"],
                    ended_at=timing.get("end") or (row["time_updated"] if status != "unknown" else None),
                    status=status, source_kind="opencode_part", arguments=state.get("input"))
                activity_added += change["added"]
                activity_updated += change["updated"]
        cursor = {"mode": "snapshots", "observed_at": observed_at}
        activity.mark_current(cursor)
        db.set_scan_cursor(conn, NAME, cursor)
    finally:
        src.close()
    return {"added": added, "updated": updated, "files": 1, "counter_resets": resets,
            "activity_added": activity_added, "activity_updated": activity_updated}
