"""SQLite accounting, transactional schema upgrades, and explicit time quality.

Token columns are disjoint: uncached input, output, cache read, cache write.
Unknown history stays in lifetime totals; observed intervals are never assigned
arbitrarily to a date/hour that they cross.
"""
from __future__ import annotations

from contextlib import closing
import fcntl
import hashlib
import json
import os
import sqlite3
import threading
import time
from datetime import datetime, timedelta

SCHEMA_VERSION = 2
_MIGRATION_LOCK = threading.Lock()
TOKEN_COLUMNS = ("input", "output", "cache_read", "cache_write")
TOKENS = "(input+output+cache_read+cache_write)"
SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_events (
    id INTEGER PRIMARY KEY, tool TEXT NOT NULL, session_id TEXT NOT NULL DEFAULT '',
    project TEXT NOT NULL DEFAULT '', ts INTEGER NOT NULL, model TEXT NOT NULL DEFAULT '',
    input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
    cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
    cost REAL, src_key TEXT NOT NULL,
    time_quality TEXT NOT NULL DEFAULT 'exact', interval_start INTEGER,
    cost_source TEXT NOT NULL DEFAULT 'estimate',
    source_kind TEXT NOT NULL DEFAULT '', source_scope TEXT NOT NULL DEFAULT '',
    UNIQUE(tool, src_key)
);
CREATE INDEX IF NOT EXISTS idx_events_tool_ts ON usage_events(tool, ts);
CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events(ts);
CREATE TABLE IF NOT EXISTS scan_state (tool TEXT PRIMARY KEY, cursor TEXT);
CREATE TABLE IF NOT EXISTS aggregate_snapshots (
    tool TEXT NOT NULL, source_scope TEXT NOT NULL, identity TEXT NOT NULL,
    values_json TEXT NOT NULL, observed_at INTEGER NOT NULL, revision INTEGER NOT NULL,
    PRIMARY KEY(tool, source_scope, identity)
);
CREATE TABLE IF NOT EXISTS migration_history (
    version INTEGER NOT NULL, migrated_at INTEGER NOT NULL, event_id INTEGER,
    original_json TEXT NOT NULL, note TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS session_meta (
    tool TEXT NOT NULL, session_id TEXT NOT NULL, title TEXT NOT NULL,
    updated_at INTEGER NOT NULL, PRIMARY KEY(tool, session_id)
);
"""


def default_db_path() -> str:
    return os.environ.get("TOKENTRACKER_DB") or os.path.join(os.path.expanduser("~"), ".tokentracker", "usage.db")


def _upgrade(conn, path):
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version > SCHEMA_VERSION:
        raise RuntimeError(f"Database version {version} is newer than supported {SCHEMA_VERSION}")
    if version == SCHEMA_VERSION:
        return
    legacy = conn.execute("SELECT 1 FROM sqlite_master WHERE name='usage_events'").fetchone()
    if legacy:
        backup_path = f"{path}.v{version}.backup-{time.time_ns()}.db"
        with closing(sqlite3.connect(backup_path)) as backup:
            conn.backup(backup)
    conn.execute("BEGIN IMMEDIATE")
    try:
        if legacy and version < 1:
            columns = {
                "time_quality": "TEXT NOT NULL DEFAULT 'exact'", "interval_start": "INTEGER",
                "cost_source": "TEXT NOT NULL DEFAULT 'estimate'",
                "source_kind": "TEXT NOT NULL DEFAULT ''", "source_scope": "TEXT NOT NULL DEFAULT ''",
            }
            for column, declaration in columns.items():
                conn.execute(f"ALTER TABLE usage_events ADD COLUMN {column} {declaration}")
        # executescript implicitly commits; execute statements individually instead.
        for statement in SCHEMA.split(";"):
            if statement.strip():
                conn.execute(statement)
        if legacy and version < 1:
            from .pricing import cost_for, load_prices
            prices = load_prices()
            for row in conn.execute("SELECT * FROM usage_events WHERE tool IN ('codex','opencode','hermes')").fetchall():
                old = dict(row)
                conn.execute("INSERT INTO migration_history VALUES (?,?,?,?,?)", (
                    SCHEMA_VERSION, int(time.time()*1000), row["id"], json.dumps(old),
                    "Preserved original counters; Codex prices recalculated using the current price table (not a historical bill)."))
                if row["tool"] == "codex":
                    inp = max(0, row["input"] - row["cache_read"] - row["cache_write"])
                    cost, _ = cost_for(prices, row["model"], inp, row["output"], row["cache_read"], row["cache_write"])
                    quality = "unallocated" if row["src_key"].startswith("legacy|") else "exact"
                    conn.execute("UPDATE usage_events SET input=?,cost=?,cost_source='recomputed',time_quality=? WHERE id=?",
                                 (inp, cost, quality, row["id"]))
                else:
                    conn.execute("UPDATE usage_events SET time_quality='unallocated',cost_source='legacy' WHERE id=?", (row["id"],))
        conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        conn.commit()
    except BaseException:
        conn.rollback()
        raise


def connect(db_path: str | None = None) -> sqlite3.Connection:
    path = db_path or default_db_path()
    if path != ":memory:":
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    conn = sqlite3.connect(path, timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version != SCHEMA_VERSION:
            with _MIGRATION_LOCK:
                if path == ":memory:":
                    _upgrade(conn, path)
                else:
                    with open(path + ".migrate.lock", "a") as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        _upgrade(conn, path)
        return conn
    except BaseException:
        conn.close()
        raise


def put_event(conn, tool: str, src_key: str, *, session_id: str = "", project: str = "",
              ts: int = 0, model: str = "", input: int = 0, output: int = 0,
              cache_read: int = 0, cache_write: int = 0, cost=None, replace: bool = False,
              time_quality: str = "exact", interval_start: int | None = None,
              cost_source: str = "estimate", source_kind: str = "", source_scope: str = "") -> int:
    if time_quality not in ("exact", "observed", "unallocated"):
        raise ValueError("Unknown time quality")
    if time_quality == "observed" and (interval_start is None or interval_start > ts):
        time_quality = "unallocated"
    if ts <= 0:
        ts = int(time.time() * 1000)
    verb = "INSERT OR REPLACE" if replace else "INSERT OR IGNORE"
    return conn.execute(
        f"{verb} INTO usage_events (tool,src_key,session_id,project,ts,model,input,output,cache_read,cache_write,cost,"
        "time_quality,interval_start,cost_source,source_kind,source_scope) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (tool, src_key, session_id, project, ts, model, input, output, cache_read, cache_write, cost,
         time_quality, interval_start, cost_source, source_kind, source_scope)).rowcount


def set_scan_cursor(conn, tool: str, cursor: dict):
    conn.execute("INSERT OR REPLACE INTO scan_state(tool,cursor) VALUES (?,?)", (tool, json.dumps(cursor)))
    conn.commit()


def get_scan_cursor(conn, tool: str) -> dict:
    row = conn.execute("SELECT cursor FROM scan_state WHERE tool=?", (tool,)).fetchone()
    return json.loads(row["cursor"]) if row and row["cursor"] else {}


def put_snapshot(conn, tool, source_scope, identity, *, session_id, project, model,
                 input=0, output=0, cache_read=0, cache_write=0, native_cost=None,
                 cost_source="native", prices=None, legacy_key=None, observed_at=None):
    """Persist a cumulative observation and emit only its change (no commit).

    The first observation has no reliable event time. Unchanged observations also
    advance the interval boundary. A decreasing counter establishes a new baseline
    without adding a negative event or counting the replacement baseline again.
    """
    from .pricing import cost_for
    # SELECT must participate in the same write transaction as the revision
    # insert. Otherwise another process can consume that revision between them.
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    now = int(time.time()*1000) if observed_at is None else int(observed_at)
    digest = hashlib.sha256(json.dumps([source_scope, identity]).encode()).hexdigest()
    values = dict(zip(TOKEN_COLUMNS, (input, output, cache_read, cache_write)))
    values = {k: max(0, int(v or 0)) for k, v in values.items()}
    values["native_cost"] = native_cost
    values["native_source"] = cost_source if native_cost is not None else None
    row = conn.execute("SELECT * FROM aggregate_snapshots WHERE tool=? AND source_scope=? AND identity=?",
                       (tool, source_scope, identity)).fetchone()
    previous, start, revision = None, None, -1
    if row:
        previous, start, revision = json.loads(row["values_json"]), row["observed_at"], row["revision"]
    elif legacy_key is not None:
        legacy = conn.execute("SELECT * FROM usage_events WHERE tool=? AND src_key=? AND source_scope=''",
                              (tool, legacy_key)).fetchone()
        if legacy:
            previous = {k: legacy[k] for k in TOKEN_COLUMNS}
            previous["accounted_cost"] = legacy["cost"] or 0
            previous["native_source"] = legacy["cost_source"] if legacy["cost_source"] in ("native", "provider_estimate") else None
            previous["native_cost"] = legacy["cost"] if previous["native_source"] else None
            previous["legacy_key"] = legacy_key
            conn.execute("UPDATE usage_events SET time_quality='unallocated',source_kind='aggregate_snapshot',source_scope=? WHERE id=?",
                         (source_scope, legacy["id"]))
    adopted_key = (previous or {}).get("legacy_key", legacy_key)
    ledger_where = "tool=? AND (src_key LIKE ? OR (src_key=? AND source_scope=?))"
    ledger_args = (tool, f"aggregate|{digest}|%", adopted_key or "", source_scope)
    def ledger_cost():
        return conn.execute(
            f"SELECT COALESCE(SUM(cost),0) FROM usage_events WHERE {ledger_where}", ledger_args).fetchone()[0]
    cost_offset = (previous or {}).get("cost_offset", 0)
    if previous and "accounted_cost" in previous:
        accounted = previous["accounted_cost"] or 0
    else:
        # Compatibility with snapshots written before the cost ledger existed,
        # including a legacy row already adopted by the old implementation.
        accounted = ledger_cost() - cost_offset
    reset = bool(previous and any(values[k] < previous[k] for k in TOKEN_COLUMNS))
    delta = {k: values[k] - (previous[k] if previous else 0) for k in TOKEN_COLUMNS}
    added = 0
    def emit(counters, cost, origin, quality):
        nonlocal revision, added
        revision += 1
        added += put_event(conn, tool, f"aggregate|{digest}|{revision}",
                           session_id=session_id, project=project, model=model, ts=now,
                           **counters, cost=cost, time_quality=quality,
                           interval_start=start if quality == "observed" else None,
                           cost_source=origin, source_kind="aggregate_snapshot", source_scope=source_scope)
    if not reset:
        continuous_native = bool(
            previous and native_cost is not None and previous.get("native_cost") is not None
            and previous.get("native_source") == cost_source
            and native_cost >= previous["native_cost"])
        if previous and native_cost is not None and not continuous_native:
            # Repricing can fill NULL costs between observations. Reconcile the
            # actual ledger, subtracting expenses retained from older epochs.
            accounted = ledger_cost() - cost_offset
        if native_cost is not None and (not previous or continuous_native):
            cost = native_cost - (previous["native_cost"] if previous else 0)
            origin = cost_source
        else:
            cost, _ = cost_for(prices or {}, model, *(delta[k] for k in TOKEN_COLUMNS))
            origin = "estimate"
        if any(delta.values()) or (cost is not None and cost != 0):
            emit(delta, cost, origin, "observed" if start is not None else "unallocated")
            accounted += cost or 0
        if previous and native_cost is not None and not continuous_native:
            # The first authoritative cumulative cost (or a different cost
            # source) reconciles the ledger, not the current time bucket.
            correction = native_cost - accounted
            if abs(correction) > 1e-9:
                emit(dict.fromkeys(TOKEN_COLUMNS, 0), correction, "native_adjustment", "unallocated")
            accounted = native_cost
            # These unknown individual prices are now included in the cumulative
            # adjustment; a later reprice must not charge them a second time.
            conn.execute(f"UPDATE usage_events SET cost=0,cost_source='native_included' WHERE {ledger_where} AND cost IS NULL",
                         ledger_args)
    else:
        revision += 1
        # Counters restarted. Future native costs are relative to this baseline,
        # not to all the expenses retained from the previous epoch.
        accounted = native_cost
        if accounted is None:
            accounted, _ = cost_for(prices or {}, model, *(values[k] for k in TOKEN_COLUMNS))
        cost_offset = ledger_cost() - (accounted or 0)
    values["accounted_cost"] = accounted or 0
    values["cost_offset"] = cost_offset
    values["legacy_key"] = adopted_key
    conn.execute("INSERT OR REPLACE INTO aggregate_snapshots VALUES (?,?,?,?,?,?)",
                 (tool, source_scope, identity, json.dumps(values), now, revision))
    return {"added": added, "counter_resets": int(reset)}


def _range_bounds(range_key: str) -> tuple[int, int]:
    now = datetime.now()
    if range_key == "day":
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif range_key == "week":
        start = (now - timedelta(days=6)).replace(hour=0, minute=0, second=0, microsecond=0)
    elif range_key == "month":
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    else:
        start = datetime(1970, 1, 1)
    return int(start.timestamp()*1000), int((now+timedelta(seconds=1)).timestamp()*1000)


def _countable(lo, hi):
    return "(time_quality='exact' OR (time_quality='observed' AND interval_start>=?)) AND ts>=? AND ts<?", [lo, lo, hi]


def _filter(range_key, tool=None, model_prefix=None):
    if range_key == "all":
        sql, args = "1", []
    else:
        sql, args = _countable(*_range_bounds(range_key))
    return _scope(sql, args, tool, model_prefix)


def _scope(sql, args, tool=None, model_prefix=None):
    if tool:
        sql += " AND tool=?"
        args.append(tool)
    if model_prefix:
        sql += " AND model LIKE ?"
        args.append(model_prefix + "%")
    return sql, args


def _bucket(column, bucket):
    fmt = "%Y-%m-%d %H" if bucket == "hour" else "%Y-%m-%d"
    return f"strftime('{fmt}', {column}/1000, 'unixepoch', 'localtime')"


def _bucket_filter(bucket):
    return f"(time_quality='exact' OR (time_quality='observed' AND {_bucket('interval_start', bucket)}={_bucket('ts', bucket)}))"


_AGG = ", ".join(f"COALESCE(SUM({k}),0) AS {k}" for k in (*TOKEN_COLUMNS, "cost")) + f""",
    COALESCE(SUM({TOKENS}),0) AS tokens, COUNT(*) AS events,
    COALESCE(SUM(CASE WHEN cost IS NULL THEN 1 ELSE 0 END),0) AS unpriced,
    COALESCE(SUM(CASE WHEN time_quality='observed' THEN {TOKENS} ELSE 0 END),0) AS estimated_tokens,
    COALESCE(SUM(CASE WHEN time_quality='unallocated' THEN {TOKENS} ELSE 0 END),0) AS unallocated_tokens"""


def _summary(conn, where, args):
    return dict(conn.execute(f"SELECT COALESCE(SUM({TOKENS}),0) AS tokens,COALESCE(SUM(cost),0) AS cost,COUNT(*) AS events FROM usage_events WHERE {where}", args).fetchone())


def time_summary(conn, range_key="all", bucket=None, tool=None):
    where, args = _filter(range_key, tool)
    if bucket:
        where += " AND " + _bucket_filter(bucket)
    estimate = conn.execute(f"SELECT COALESCE(SUM({TOKENS}),0) FROM usage_events WHERE {where} AND time_quality='observed'", args).fetchone()[0]
    if range_key == "all":
        excluded = "time_quality='unallocated'"
        excluded_args = []
        if bucket:
            excluded += " OR (time_quality='observed' AND NOT " + _bucket_filter(bucket) + ")"
    else:
        lo, hi = _range_bounds(range_key)
        included, included_args = _countable(lo, hi)
        if bucket:
            included += " AND " + _bucket_filter(bucket)
        # Unknown history may belong to any range. Intervals are relevant only if overlapping it.
        excluded = f"time_quality='unallocated' OR (time_quality='observed' AND ts>=? AND interval_start<? AND NOT ({included}))"
        excluded_args = [lo, hi, *included_args]
    excluded, excluded_args = _scope("(" + excluded + ")", excluded_args, tool)
    return {"unallocated": _summary(conn, excluded, excluded_args), "estimated_tokens": estimate}


def stats(conn, range_key="all", tool=None):
    where, args = _filter(range_key, tool)
    rows = [dict(r) for r in conn.execute(f"SELECT tool,COUNT(DISTINCT session_id) AS sessions,{_AGG} FROM usage_events WHERE {where} GROUP BY tool ORDER BY tokens DESC", args)]
    total = {key: sum(row[key] for row in rows) for key in (*TOKEN_COLUMNS, "cost", "tokens", "events", "sessions", "unpriced", "estimated_tokens", "unallocated_tokens")}
    total.update(tool="__total__", cost=round(total["cost"], 6), **time_summary(conn, range_key, tool=tool))
    return rows, total


def daily(conn, range_key="all"):
    bucket = "hour" if range_key == "day" else "day"
    label = "strftime('%H:00', ts/1000, 'unixepoch', 'localtime')" if bucket == "hour" else _bucket("ts", bucket)
    where, args = _filter(range_key)
    return [dict(r) for r in conn.execute(f"SELECT tool,{label} AS d,{_AGG} FROM usage_events WHERE {where} AND {_bucket_filter(bucket)} GROUP BY d,tool ORDER BY d", args)]


def models(conn, range_key="all", tool=None):
    where, args = _filter(range_key, tool)
    return [dict(r) for r in conn.execute(f"SELECT tool,model,{_AGG} FROM usage_events WHERE {where} GROUP BY tool,model ORDER BY tokens DESC", args)]


def window_usage(conn, start_ms, tool=None, model_prefix=None, include_cache=False, usd=False):
    where, args = _countable(int(start_ms), int(time.time()*1000)+1000)
    where, args = _scope(where, args, tool, model_prefix)
    expr = "cost" if usd else TOKENS if include_cache else "input+output"
    return conn.execute(f"SELECT COALESCE(SUM({expr}),0) FROM usage_events WHERE {where}", args).fetchone()[0]


def window_unallocated(conn, start_ms, tool=None, model_prefix=None, include_cache=False, usd=False):
    where = "(time_quality='unallocated' OR (time_quality='observed' AND ts>=? AND interval_start<?))"
    where, args = _scope(where, [int(start_ms), int(start_ms)], tool, model_prefix)
    expr = "cost" if usd else TOKENS if include_cache else "input+output"
    return conn.execute(f"SELECT COALESCE(SUM({expr}),0) FROM usage_events WHERE {where}", args).fetchone()[0]


def quota_usage(conn, range_key, tool=None, model_prefix=None, include_cache=False):
    where, args = _filter(range_key, tool, model_prefix)
    expr = TOKENS if include_cache else "input+output"
    row = conn.execute(f"SELECT COALESCE(SUM({expr}),0),COALESCE(SUM(cost),0) FROM usage_events WHERE {where}", args).fetchone()
    return tuple(row)


def reprice(conn, prices):
    from .pricing import cost_for
    n = 0
    for r in conn.execute("SELECT * FROM usage_events WHERE cost IS NULL").fetchall():
        cost, _ = cost_for(prices, r["model"], *(r[k] for k in TOKEN_COLUMNS))
        if cost is not None:
            conn.execute("UPDATE usage_events SET cost=?,cost_source='estimate' WHERE id=?", (cost, r["id"]))
            n += 1
    conn.commit()
    return n


def session_detail(conn, tool, session_id):
    where, args = "tool=? AND session_id=?", [tool, session_id]
    times = "MIN(CASE WHEN time_quality!='unallocated' THEN COALESCE(interval_start,ts) END) AS first_ts,MAX(CASE WHEN time_quality!='unallocated' THEN ts END) AS last_ts"
    model_rows = [dict(r) for r in conn.execute(f"SELECT model,{_AGG},{times} FROM usage_events WHERE {where} GROUP BY model ORDER BY tokens DESC", args)]
    total = dict(conn.execute(f"SELECT COALESCE(MAX(NULLIF(project,'')),'') AS project,{_AGG},{times} FROM usage_events WHERE {where}", args).fetchone())
    intervals = [dict(r) for r in conn.execute("SELECT interval_start,ts,tokens FROM (SELECT interval_start,ts," + TOKENS + " AS tokens FROM usage_events WHERE tool=? AND session_id=? AND time_quality='observed') ORDER BY ts", args)]
    return {"models": model_rows, **total, "observation_intervals": intervals}


def set_session_title(conn, tool: str, session_id: str, title: str):
    """记录会话标题（首个 user 消息等）。只在内容变化时更新，幂等。"""
    title = " ".join((title or "").split())[:120]
    if not title or not session_id:
        return
    conn.execute("""INSERT INTO session_meta VALUES (?,?,?,?)
        ON CONFLICT(tool, session_id) DO UPDATE SET title=excluded.title,
        updated_at=excluded.updated_at WHERE session_meta.title != excluded.title""",
        (tool, session_id, title, int(time.time() * 1000)))


def sessions(conn, range_key="all", tool=None, limit=300, q=None):
    where, args = _filter(range_key, tool)
    base = f"""SELECT tool,session_id,MAX(project) AS project,
        datetime(MAX(CASE WHEN time_quality!='unallocated' THEN ts END)/1000,'unixepoch','localtime') AS last_seen,
        MAX(CASE WHEN time_quality!='unallocated' THEN ts END) AS ts,MAX(model) AS model,{_AGG}
        FROM usage_events WHERE {where} GROUP BY tool,session_id ORDER BY ts DESC"""
    sql = (f"SELECT s.*, m.title FROM ({base}) s LEFT JOIN session_meta m "
           f"ON m.tool=s.tool AND m.session_id=s.session_id")
    if q:
        sql += (" WHERE (m.title LIKE ? OR s.project LIKE ? OR s.session_id LIKE ? "
                "OR s.model LIKE ?)")
        args = [*args, *([f"%{q}%"] * 4)]
    sql += " ORDER BY s.ts DESC LIMIT ?"
    return [dict(r) for r in conn.execute(sql, [*args, limit])]
