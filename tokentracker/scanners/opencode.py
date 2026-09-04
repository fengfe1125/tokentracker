"""opencode 扫描器：~/.local/share/opencode/opencode.db

session 累计字段按持久化快照计算差量；首次存量保留为时间未分配历史。
"""
from __future__ import annotations

import json
import os

from .. import db
from ._util import expand, sqlite_ro

NAME = "opencode"
DETAIL = "~/.local/share/opencode/opencode.db"


def db_path() -> str:
    return expand(os.environ.get("OPENCODE_DB") or "~/.local/share/opencode/opencode.db")


def detect() -> bool:
    return os.path.isfile(db_path())


def _model_id(raw) -> str:
    if not raw:
        return ""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return raw
    if isinstance(raw, dict):
        return raw.get("id") or raw.get("model") or raw.get("providerID") or ""
    return str(raw)


def scan(conn, prices, full: bool = False) -> dict:
    # Read every cumulative row: unchanged observations narrow the next interval;
    # updated_at is not a safe cursor (ties and resets can hide changed counters).
    path = db_path()
    added = updated = resets = 0
    src = sqlite_ro(path)
    try:
        rows = src.execute("SELECT * FROM session").fetchall()
        observed_at = int(db.time.time() * 1000)
        for r in rows:
            result = db.put_snapshot(
                conn, NAME, os.path.realpath(path), str(r["id"]),
                session_id=str(r["id"]), project=r["directory"] or r["title"] or "",
                model=_model_id(r["model"]), input=r["tokens_input"], output=r["tokens_output"],
                cache_read=r["tokens_cache_read"], cache_write=r["tokens_cache_write"],
                native_cost=r["cost"], prices=prices, legacy_key=str(r["id"]), observed_at=observed_at)
            db.set_session_title(conn, NAME, str(r["id"]), r["title"] or "")
            added += result["added"]
            resets += result["counter_resets"]
            updated += 1
        db.set_scan_cursor(conn, NAME, {"mode": "snapshots", "observed_at": observed_at})
    finally:
        src.close()
    return {"added": added, "updated": updated, "files": 1, "counter_resets": resets}
