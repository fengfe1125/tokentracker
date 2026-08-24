"""opencode 扫描器：~/.local/share/opencode/opencode.db

session 表自带聚合字段（tokens_input/output/cache_*/cost/model），
按 session id 覆盖更新（会话进行中数字会增长）。
"""
from __future__ import annotations

import json
import os

from .. import db, pricing
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
    path = db_path()
    cursor = db.get_scan_cursor(conn, NAME)
    added = updated = 0
    try:
        src = sqlite_ro(path)
    except Exception as e:
        return {"added": 0, "updated": 0, "files": 0, "error": str(e)}
    last = 0 if full else cursor.get("opencode_last_updated", 0)
    rows = src.execute(
        """
        SELECT id, directory, title, model,
               tokens_input, tokens_output, tokens_reasoning,
               tokens_cache_read, tokens_cache_write, cost,
               time_created, time_updated
        FROM session
        WHERE time_updated > ? AND (tokens_input+tokens_output+tokens_cache_read+tokens_cache_write) > 0
        ORDER BY time_updated
        """,
        (last,),
    )
    for r in rows:
        inp = r["tokens_input"] or 0
        outp = r["tokens_output"] or 0
        cr = r["tokens_cache_read"] or 0
        cw = r["tokens_cache_write"] or 0
        model = _model_id(r["model"])
        native_cost = r["cost"] or 0
        if native_cost > 0:
            cost = native_cost
        else:
            cost, _ = pricing.cost_for(prices, model, inp, outp, cr, cw)
        db.put_event(conn, NAME, r["id"],  # 聚合行：覆盖更新
                     session_id=str(r["id"]), project=(r["directory"] or r["title"] or ""),
                     ts=int(r["time_created"] or 0), model=model,
                     input=inp, output=outp, cache_read=cr, cache_write=cw,
                     cost=cost, replace=True)
        updated += 1
        last = r["time_updated"]
    src.close()
    cursor["opencode_last_updated"] = last
    db.set_scan_cursor(conn, NAME, cursor)
    return {"added": added, "updated": updated, "files": 1}