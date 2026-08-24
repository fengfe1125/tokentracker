"""Hermes Agent 扫描器：$HERMES_HOME/state.db（含 profiles/*/state.db）

session_model_usage 表按 (session_id, model, provider, base_url, mode, task)
记录聚合用量与成本，天然幂等 → 全量覆盖更新（replace=True）。
"""
from __future__ import annotations

import glob
import os

from .. import db, pricing
from ._util import expand, sqlite_ro

NAME = "hermes"
DETAIL = "~/.hermes/state.db (session_model_usage)"


def home() -> str:
    return expand(os.environ.get("HERMES_HOME") or "~/.hermes")


def db_files() -> list[str]:
    h = home()
    out = []
    for pat in (os.path.join(h, "state.db"), os.path.join(h, "profiles", "*", "state.db")):
        out.extend(sorted(glob.glob(pat)))
    return out


def detect() -> bool:
    return bool(db_files())


def _scan_one(conn, path: str, prices) -> tuple[int, int]:
    try:
        src = sqlite_ro(path)
    except Exception:
        return 0, 0
    rows = src.execute(
        """
        SELECT u.session_id, s.display_name, u.model,
               u.input_tokens, u.output_tokens,
               u.cache_read_tokens, u.cache_write_tokens, u.reasoning_tokens,
               u.estimated_cost_usd, u.actual_cost_usd,
               u.first_seen, u.last_seen, u.api_call_count,
               u.billing_provider, u.billing_base_url, u.billing_mode, u.task
        FROM session_model_usage u
        LEFT JOIN sessions s ON s.id = u.session_id
        """
    )
    n = 0
    for r in rows:
        inp = r["input_tokens"] or 0
        outp = r["output_tokens"] or 0
        cr = r["cache_read_tokens"] or 0
        cw = r["cache_write_tokens"] or 0
        if inp + outp + cr + cw == 0:
            continue
        cost = None
        if (r["actual_cost_usd"] or 0) > 0:
            cost = r["actual_cost_usd"]
        elif (r["estimated_cost_usd"] or 0) > 0:
            cost = r["estimated_cost_usd"]
        if cost is None:
            # 无官方成本时按价格表估算
            cost, _ = pricing.cost_for(prices, r["model"] or "", inp, outp, cr, cw)
        ts = int((r["last_seen"] or r["first_seen"] or 0) * 1000)
        key = f"{r['session_id']}|{r['model']}|{r['billing_provider']}|{r['billing_base_url']}|{r['billing_mode']}|{r['task']}"
        db.put_event(conn, NAME, key,
                     session_id=r["session_id"] or "",
                     project=r["display_name"] or r["session_id"] or "",
                     ts=ts, model=r["model"] or "",
                     input=inp, output=outp, cache_read=cr, cache_write=cw,
                     cost=cost or None, replace=True)
        n += 1
    src.close()
    return n, 0


def scan(conn, prices, full: bool = False) -> dict:
    added = updated = 0
    files = 0
    for path in db_files():
        if not full and not os.path.isfile(path):
            continue
        files += 1
        u, a = _scan_one(conn, path, prices)
        updated += u
    # hermes 为全量覆盖，无增量游标
    db.set_scan_cursor(conn, NAME, {"mode": "full-upsert"})
    return {"added": added, "updated": updated, "files": files}