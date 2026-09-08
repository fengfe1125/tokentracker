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

SCHEMA_VERSION = 3
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
CREATE TABLE IF NOT EXISTS agent_activity_events (
    id INTEGER PRIMARY KEY,
    agent TEXT NOT NULL,
    session_id TEXT NOT NULL DEFAULT '',
    turn_id TEXT NOT NULL DEFAULT '',
    raw_name TEXT NOT NULL,
    canonical_name TEXT NOT NULL,
    namespace TEXT NOT NULL DEFAULT '',
    call_id TEXT NOT NULL DEFAULT '',
    parent_call_id TEXT NOT NULL DEFAULT '',
    started_at INTEGER,
    ended_at INTEGER,
    duration_ms INTEGER,
    status TEXT NOT NULL DEFAULT 'unknown',
    source_kind TEXT NOT NULL DEFAULT '',
    confidence TEXT NOT NULL DEFAULT 'exact',
    skill_name TEXT NOT NULL DEFAULT '',
    skill_confidence TEXT NOT NULL DEFAULT '',
    src_key TEXT NOT NULL,
    UNIQUE(agent, src_key)
);
CREATE INDEX IF NOT EXISTS idx_activity_agent_time ON agent_activity_events(agent, started_at);
CREATE INDEX IF NOT EXISTS idx_activity_session ON agent_activity_events(agent, session_id, started_at);
CREATE INDEX IF NOT EXISTS idx_activity_tool ON agent_activity_events(canonical_name, started_at);
CREATE INDEX IF NOT EXISTS idx_activity_skill ON agent_activity_events(skill_name, started_at);
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
    if version < 3:
        _validate_residual_activity_table(conn)
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


def _validate_residual_activity_table(conn):
    """Accept a complete v3 activity table left behind by an older rollback."""
    exists = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_activity_events'"
    ).fetchone()
    if not exists:
        return
    expected = {
        "id", "agent", "session_id", "turn_id", "raw_name", "canonical_name",
        "namespace", "call_id", "parent_call_id", "started_at", "ended_at",
        "duration_ms", "status", "source_kind", "confidence", "skill_name",
        "skill_confidence", "src_key",
    }
    columns = {row[1] for row in conn.execute("PRAGMA table_info(agent_activity_events)")}
    if columns != expected:
        raise RuntimeError("Existing agent_activity_events schema is incompatible")
    has_identity = False
    for index in conn.execute("PRAGMA index_list(agent_activity_events)"):
        if not index[2]:
            continue
        escaped = index[1].replace('"', '""')
        names = [row[2] for row in conn.execute(f'PRAGMA index_info("{escaped}")')]
        if names == ["agent", "src_key"]:
            has_identity = True
            break
    if not has_identity:
        raise RuntimeError("Existing agent_activity_events lacks UNIQUE(agent,src_key)")


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


_ACTIVITY_STATUSES = {"success", "error", "denied", "unknown"}
_ACTIVITY_CONFIDENCE = {"exact", "derived"}


def put_activity_event(conn, agent: str, src_key: str, *, session_id: str = "",
                       turn_id: str = "", raw_name: str, canonical_name: str | None = None,
                       namespace: str = "", call_id: str = "", parent_call_id: str = "",
                       started_at: int | None = None, ended_at: int | None = None,
                       duration_ms: int | None = None, status: str = "unknown",
                       source_kind: str = "", confidence: str = "exact",
                       skill_name: str = "", skill_confidence: str = "") -> dict:
    """Insert one metadata-only tool invocation, or enrich its result fields."""
    if status not in _ACTIVITY_STATUSES:
        raise ValueError(f"Unknown activity status: {status}")
    if confidence not in _ACTIVITY_CONFIDENCE:
        raise ValueError(f"Unknown activity confidence: {confidence}")
    if skill_confidence and skill_confidence not in _ACTIVITY_CONFIDENCE:
        raise ValueError(f"Unknown skill confidence: {skill_confidence}")
    if not agent or not src_key or not raw_name:
        raise ValueError("agent, src_key and raw_name are required")
    canonical_name = canonical_name or canonical_tool_name(raw_name)
    before = conn.execute(
        "SELECT id,status,ended_at,duration_ms FROM agent_activity_events WHERE agent=? AND src_key=?",
        (agent, src_key)).fetchone()
    conn.execute("""
        INSERT INTO agent_activity_events (
            agent,session_id,turn_id,raw_name,canonical_name,namespace,call_id,parent_call_id,
            started_at,ended_at,duration_ms,status,source_kind,confidence,
            skill_name,skill_confidence,src_key
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(agent,src_key) DO UPDATE SET
            session_id=CASE WHEN excluded.session_id!='' THEN excluded.session_id ELSE session_id END,
            turn_id=CASE WHEN excluded.turn_id!='' THEN excluded.turn_id ELSE turn_id END,
            ended_at=COALESCE(excluded.ended_at,ended_at),
            duration_ms=COALESCE(excluded.duration_ms,duration_ms),
            status=CASE WHEN excluded.status!='unknown' THEN excluded.status ELSE status END,
            skill_name=CASE WHEN excluded.skill_name!='' THEN excluded.skill_name ELSE skill_name END,
            skill_confidence=CASE WHEN excluded.skill_confidence!='' THEN excluded.skill_confidence ELSE skill_confidence END
        """, (agent, session_id, turn_id, raw_name, canonical_name, namespace, call_id,
              parent_call_id, started_at, ended_at, duration_ms, status, source_kind,
              confidence, skill_name, skill_confidence, src_key))
    after = conn.execute(
        "SELECT status,ended_at,duration_ms FROM agent_activity_events WHERE agent=? AND src_key=?",
        (agent, src_key)).fetchone()
    return {"added": 0 if before else 1,
            "updated": 1 if before and tuple(before)[1:] != tuple(after) else 0}


def complete_activity_event(conn, agent: str, call_id: str, *, status="success",
                            ended_at=None, duration_ms=None) -> int:
    if not call_id or status not in _ACTIVITY_STATUSES:
        return 0
    row = conn.execute(
        "SELECT id,started_at,status,ended_at,duration_ms FROM agent_activity_events "
        "WHERE agent=? AND call_id=? ORDER BY id DESC LIMIT 1", (agent, str(call_id))).fetchone()
    if not row:
        return 0
    if duration_ms is None and ended_at is not None and row["started_at"] is not None:
        duration_ms = max(0, int(ended_at) - int(row["started_at"]))
    conn.execute("UPDATE agent_activity_events SET status=?,ended_at=COALESCE(?,ended_at),"
                 "duration_ms=COALESCE(?,duration_ms) WHERE id=?",
                 (status, ended_at, duration_ms, row["id"]))
    effective_ended = ended_at if ended_at is not None else row["ended_at"]
    effective_duration = duration_ms if duration_ms is not None else row["duration_ms"]
    return int((row["status"], row["ended_at"], row["duration_ms"]) !=
               (status, effective_ended, effective_duration))


def canonical_tool_name(raw_name: str) -> str:
    raw = (raw_name or "").strip()
    low = raw.lower()
    exact = {
        "bash": "shell", "shell": "shell", "execute_command": "shell", "exec_command": "shell",
        "read": "file.read", "read_file": "file.read", "write": "file.write",
        "write_file": "file.write", "edit": "file.edit", "apply_patch": "file.edit",
        "glob": "file.search", "grep": "file.search", "search": "web.search",
        "web_search": "web.search", "skill": "skill.activate", "skill_view": "skill.activate",
    }
    if low in exact:
        return exact[low]
    if low.startswith("mcp__"):
        return "mcp." + low[len("mcp__"):].replace("__", ".")
    return low.replace(" ", "_") or "unknown"


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
    activity = activity_timeline(conn, agent=tool, session_id=session_id, limit=500)
    activity_summary_rows = activity_summary(conn, "all", agent=tool, group="tool", session_id=session_id)
    return {"models": model_rows, **total, "observation_intervals": intervals,
            "activity": activity["rows"],
            "activity_summary": activity_summary_rows}


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
    rows = [dict(r) for r in conn.execute(sql, [*args, limit])]
    if not rows:
        return rows
    keys = {(r["tool"], r["session_id"]) for r in rows}
    lo, hi = _range_bounds(range_key)
    activity_where = "COALESCE(started_at,ended_at,0)>=? AND COALESCE(started_at,ended_at,0)<?"
    activity_args = [lo, hi]
    if range_key == "all":
        activity_where = "1=1"
        activity_args = []
    for a in conn.execute(f"""
        SELECT agent,session_id,
          SUM(CASE WHEN confidence='exact' THEN 1 ELSE 0 END) AS activity_exact,
          SUM(CASE WHEN confidence='derived' THEN 1 ELSE 0 END) AS activity_derived,
          COUNT(DISTINCT CASE WHEN skill_name!='' THEN skill_name END) AS skills
        FROM agent_activity_events WHERE {activity_where}
        GROUP BY agent,session_id
        """, activity_args):
        key = (a["agent"], a["session_id"])
        if key in keys:
            row = next(r for r in rows if (r["tool"], r["session_id"]) == key)
            row.update(activity_exact=a["activity_exact"], activity_derived=a["activity_derived"],
                       skills=a["skills"])
    for row in rows:
        row.setdefault("activity_exact", 0)
        row.setdefault("activity_derived", 0)
        row.setdefault("skills", 0)
    return rows


def _activity_filter(range_key="all", agent=None, confidence="all", session_id=None,
                     *, skill=False):
    if range_key not in ("day", "week", "month", "all"):
        raise ValueError("invalid range")
    if confidence not in ("exact", "derived", "all"):
        raise ValueError("invalid confidence")
    where, args = [], []
    if range_key != "all":
        lo, hi = _range_bounds(range_key)
        where.append("COALESCE(started_at,ended_at,0)>=? AND COALESCE(started_at,ended_at,0)<?")
        args.extend((lo, hi))
    if agent:
        where.append("agent=?")
        args.append(agent)
    if session_id is not None:
        where.append("session_id=?")
        args.append(session_id)
    if confidence != "all":
        where.append(("skill_confidence" if skill else "confidence") + "=?")
        args.append(confidence)
    if skill:
        where.append("skill_name!=''")
    return " AND ".join(where) or "1=1", args


def activity_summary(conn, range_key="all", agent=None, group="tool", confidence="all",
                     session_id=None):
    if group not in ("agent", "tool", "skill"):
        raise ValueError("invalid group")
    skill = group == "skill"
    where, args = _activity_filter(range_key, agent, confidence, session_id, skill=skill)
    # A single Agent keeps its native spelling. Cross-Agent totals use the
    # canonical name so aliases such as Bash/shell are not split.
    name = {"agent": "agent", "tool": "raw_name" if agent else "canonical_name",
            "skill": "skill_name"}[group]
    evidence = "skill_confidence" if skill else "confidence"
    sql = f"""
        SELECT {name} AS name,COUNT(*) AS calls,
          COUNT(DISTINCT session_id) AS sessions,
          SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS success,
          SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) AS error,
          SUM(CASE WHEN status='denied' THEN 1 ELSE 0 END) AS denied,
          SUM(CASE WHEN status='unknown' THEN 1 ELSE 0 END) AS unknown,
          SUM(CASE WHEN {evidence}='exact' THEN 1 ELSE 0 END) AS exact,
          SUM(CASE WHEN {evidence}='derived' THEN 1 ELSE 0 END) AS derived,
          MAX(COALESCE(ended_at,started_at,0)) AS last_used
        FROM agent_activity_events WHERE {where}
        GROUP BY {name} ORDER BY calls DESC,name
    """
    return [dict(r) for r in conn.execute(sql, args)]


def activity_timeline(conn, *, range_key="all", agent=None, session_id=None, confidence="all",
                      limit=200, before=None, before_id=None):
    where, args = _activity_filter(range_key, agent, confidence, session_id)
    if before is not None:
        if before_id is None:
            where += " AND COALESCE(started_at,ended_at,0)<?"
            args.append(int(before))
        else:
            where += (" AND (COALESCE(started_at,ended_at,0)<? OR "
                      "(COALESCE(started_at,ended_at,0)=? AND id<?))")
            args.extend((int(before), int(before), int(before_id)))
    limit = max(1, min(int(limit), 1000))
    rows = [dict(r) for r in conn.execute(
        f"SELECT * FROM agent_activity_events WHERE {where} "
        "ORDER BY COALESCE(started_at,ended_at,0) DESC,id DESC LIMIT ?", [*args, limit])]
    next_before = next_before_id = None
    if len(rows) == limit:
        next_before = rows[-1]["started_at"] or rows[-1]["ended_at"] or 0
        next_before_id = rows[-1]["id"]
    return {"rows": rows, "next_before": next_before, "next_before_id": next_before_id}


def activity_capabilities():
    return {
        "claude": {"tools": "exact", "skills": "exact"},
        "kimi": {"tools": "exact", "skills": "exact"},
        "dsh": {"tools": "exact", "skills": "exact"},
        "opencode": {"tools": "exact", "skills": "exact"},
        "hermes": {"tools": "exact", "skills": "exact"},
        "pi": {"tools": "exact", "skills": "unknown"},
        "codex": {"tools": "exact+derived", "skills": "derived"},
    }
