"""Hermes Agent 扫描器：$HERMES_HOME/state.db（含 profiles/*/state.db）

session_model_usage 表按 (session_id, model, provider, base_url, mode, task)
记录累计用量；按来源数据库持久化快照，保留存量并记录观察区间内的差量。
"""
from __future__ import annotations

import glob
import json
import os

from .. import db
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


def _read_rows(path):
    src = sqlite_ro(path)
    try:
        return src.execute("""
            SELECT u.*, s.display_name FROM session_model_usage u
            LEFT JOIN sessions s ON s.id = u.session_id
        """).fetchall()
    finally:
        src.close()


def _identity(row):
    return [row[k] for k in ("session_id", "model", "billing_provider", "billing_base_url", "billing_mode", "task")]


def _counts(row):
    return tuple(row[k] or 0 for k in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"))


def _legacy_owners(conn, sources):
    """Match the old global key before a smaller root profile can claim it.

    Old versions kept only the last profile's cumulative row. An exact payload
    match is preferred; a single source or monotonic continuation is usable.
    Ambiguous decreases cannot prove which source reset, so preserve the row.
    """
    groups = {}
    for path, rows in sources:
        for row in rows:
            key = "|".join(str(x) for x in _identity(row))
            groups.setdefault(key, []).append((path, row))
    owners = {}
    for key, candidates in groups.items():
        old = conn.execute("SELECT * FROM usage_events WHERE tool=? AND src_key=? AND source_scope=''",
                           (NAME, key)).fetchone()
        if not old:
            continue
        old_counts = tuple(old[k] for k in db.TOKEN_COLUMNS)
        exact = [(p, r) for p, r in candidates if _counts(r) == old_counts
                 and (r["display_name"] or r["session_id"] or "") == old["project"]]
        monotonic = [(p, r) for p, r in candidates if all(a >= b for a, b in zip(_counts(r), old_counts))]
        selected = exact or (candidates if len(candidates) == 1 else monotonic)
        owners[key] = selected[0][0] if selected else None
    return owners


def _scan_one(conn, path: str, prices, rows=None, owners=None) -> tuple[int, int, int]:
    rows = _read_rows(path) if rows is None else rows
    added = resets = 0
    observed_at = int(db.time.time() * 1000)
    for r in rows:
        parts = _identity(r)
        key = "|".join(str(x) for x in parts)
        # 新版 hermes 常把 actual 记为 0 / cost_status=unknown：视为未知成本，
        # 交给价格表估算（native_cost=None 时 put_snapshot 走 cost_for）。
        actual = r["actual_cost_usd"] or 0
        estimated = r["estimated_cost_usd"] or 0
        if actual > 0:
            native, origin = actual, "native"
        elif estimated > 0:
            native, origin = estimated, "provider_estimate"
        else:
            native, origin = None, "priced"
        legacy_key = key if owners is None or key not in owners or owners[key] == path else None
        inp, out, cached, written = _counts(r)
        result = db.put_snapshot(
            conn, NAME, os.path.realpath(path), json.dumps(parts),
            session_id=r["session_id"] or "", project=r["display_name"] or r["session_id"] or "",
            model=r["model"] or "", input=inp, output=out, cache_read=cached, cache_write=written,
            native_cost=native, cost_source=origin, prices=prices, legacy_key=legacy_key, observed_at=observed_at)
        db.set_session_title(conn, NAME, r["session_id"] or "", r["display_name"] or "")
        added += result["added"]
        resets += result["counter_resets"]
    return added, len(rows), resets


def scan(conn, prices, full: bool = False) -> dict:
    added = updated = resets = 0
    files = db_files()
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    sources = [(path, _read_rows(path)) for path in files]
    owners = _legacy_owners(conn, sources)
    for path, rows in sources:
        a, u, r = _scan_one(conn, path, prices, rows, owners)
        added += a
        updated += u
        resets += r
    unresolved = conn.execute("SELECT COUNT(*) FROM usage_events WHERE tool=? AND source_scope='' AND time_quality='unallocated'",
                              (NAME,)).fetchone()[0]
    db.set_scan_cursor(conn, NAME, {"mode": "snapshots"})
    result = {"added": added, "updated": updated, "files": len(files), "counter_resets": resets}
    if unresolved:
        result["warning"] = f"保留 {unresolved} 条无法映射 profile 的未分配历史，可能与现存来源重叠"
    return result
