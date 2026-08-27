"""SQLite 聚合库：usage_events + scan_state（增量游标）。

所有扫描器输出统一的 usage 事件，这里负责去重（UNIQUE(tool, src_key)）、
聚合查询与增量游标持久化。
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
from datetime import datetime, timedelta

SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_events (
    id          INTEGER PRIMARY KEY,
    tool        TEXT NOT NULL,
    session_id  TEXT NOT NULL DEFAULT '',
    project     TEXT NOT NULL DEFAULT '',
    ts          INTEGER NOT NULL,
    model       TEXT NOT NULL DEFAULT '',
    input       INTEGER NOT NULL DEFAULT 0,
    output      INTEGER NOT NULL DEFAULT 0,
    cache_read  INTEGER NOT NULL DEFAULT 0,
    cache_write INTEGER NOT NULL DEFAULT 0,
    cost        REAL,
    src_key     TEXT NOT NULL,
    UNIQUE(tool, src_key)
);
CREATE INDEX IF NOT EXISTS idx_events_tool_ts ON usage_events(tool, ts);
CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events(ts);

CREATE TABLE IF NOT EXISTS scan_state (
    tool   TEXT PRIMARY KEY,
    cursor TEXT
);
"""


def default_db_path() -> str:
    env = os.environ.get("TOKENTRACKER_DB")
    if env:
        return env
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "usage.db")


def connect(db_path: str | None = None) -> sqlite3.Connection:
    path = db_path or default_db_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def put_event(conn, tool: str, src_key: str, *,
              session_id: str = "", project: str = "", ts: int = 0,
              model: str = "", input: int = 0, output: int = 0,
              cache_read: int = 0, cache_write: int = 0, cost=None,
              replace: bool = False) -> int:
    """写入一条事件；replace=True 时按 (tool, src_key) 覆盖（聚合类源）。"""
    if ts <= 0:
        ts = int(time.time() * 1000)
    row = (tool, src_key, session_id, project, ts, model,
           input, output, cache_read, cache_write, cost)
    verb = "INSERT OR REPLACE" if replace else "INSERT OR IGNORE"
    cur = conn.execute(
        f"{verb} INTO usage_events"
        "(tool, src_key, session_id, project, ts, model,"
        " input, output, cache_read, cache_write, cost)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        row,
    )
    # INSERT OR IGNORE：重复事件返回 0，真实新增返回 1；REPLACE 恒为 1
    return cur.rowcount


def set_scan_cursor(conn, tool: str, cursor: dict):
    conn.execute(
        "INSERT OR REPLACE INTO scan_state(tool, cursor) VALUES (?,?)",
        (tool, json.dumps(cursor)),
    )
    conn.commit()


def get_scan_cursor(conn, tool: str) -> dict:
    row = conn.execute("SELECT cursor FROM scan_state WHERE tool=?", (tool,)).fetchone()
    return json.loads(row["cursor"]) if row and row["cursor"] else {}


# ---------------------------------------------------------------- 查询 ----

def _range_bounds(range_key: str) -> tuple[int, int]:
    """返回 [start_ms, end_ms)，本地时区。"""
    now = datetime.now()
    if range_key == "day":
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif range_key == "week":
        start = (now - timedelta(days=6)).replace(hour=0, minute=0, second=0, microsecond=0)
    elif range_key == "month":
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    else:  # all
        start = datetime(1970, 1, 1)
    end = now + timedelta(seconds=1)
    return int(start.timestamp() * 1000), int(end.timestamp() * 1000)


_STATS_SQL = """
SELECT tool,
       COUNT(DISTINCT session_id) AS sessions,
       COUNT(*)                   AS events,
       COALESCE(SUM(input),0)     AS input,
       COALESCE(SUM(output),0)    AS output,
       COALESCE(SUM(cache_read),0)  AS cache_read,
       COALESCE(SUM(cache_write),0) AS cache_write,
       COALESCE(SUM(cost),0)      AS cost,
       SUM(CASE WHEN cost IS NULL THEN 1 ELSE 0 END) AS unpriced
FROM usage_events
WHERE ts >= ? AND ts <= ?
"""


def stats(conn, range_key: str = "all", tool: str | None = None) -> list[dict]:
    lo, hi = _range_bounds(range_key)
    sql = _STATS_SQL
    args: list = [lo, hi]
    if tool:
        sql += " AND tool=?"
        args.append(tool)
    sql += " GROUP BY tool ORDER BY (COALESCE(SUM(input),0)+COALESCE(SUM(output),0)) DESC"
    rows = [dict(r) for r in conn.execute(sql, args)]
    # 汇总行
    total = {
        "tool": "__total__", "sessions": sum(r["sessions"] for r in rows),
        "events": sum(r["events"] for r in rows),
        "input": sum(r["input"] for r in rows),
        "output": sum(r["output"] for r in rows),
        "cache_read": sum(r["cache_read"] for r in rows),
        "cache_write": sum(r["cache_write"] for r in rows),
        "cost": round(sum(r["cost"] for r in rows), 6),
        "unpriced": sum(r["unpriced"] for r in rows),
    }
    return rows, total


def daily(conn, range_key: str = "all") -> list[dict]:
    """按天×工具聚合，供折线图；range=day（今天）时按 24 小时粒度（d 为 "HH:00"）。"""
    lo, hi = _range_bounds(range_key)
    if range_key == "day":
        bucket = "strftime('%H:00', ts/1000, 'unixepoch', 'localtime')"
    else:
        bucket = "date(ts/1000, 'unixepoch', 'localtime')"
    rows = conn.execute(
        f"""
        SELECT tool, {bucket} AS d,
               COALESCE(SUM(input),0) AS input,
               COALESCE(SUM(output),0) AS output,
               COALESCE(SUM(cache_read),0) AS cache_read,
               COALESCE(SUM(cost),0) AS cost
        FROM usage_events WHERE ts>=? AND ts<=?
        GROUP BY d, tool ORDER BY d
        """,
        (lo, hi),
    )
    return [dict(r) for r in rows]


def models(conn, range_key: str = "all", tool: str | None = None) -> list[dict]:
    lo, hi = _range_bounds(range_key)
    sql = """
        SELECT tool, model,
               COALESCE(SUM(input),0) AS input,
               COALESCE(SUM(output),0) AS output,
               COALESCE(SUM(cache_read),0) AS cache_read,
               COALESCE(SUM(cost),0) AS cost
        FROM usage_events WHERE ts>=? AND ts<=?
    """
    args: list = [lo, hi]
    if tool:
        sql += " AND tool=?"
        args.append(tool)
    sql += " GROUP BY tool, model ORDER BY input+output DESC"
    return [dict(r) for r in conn.execute(sql, args)]


def window_usage(conn, start_ms: int, tool: str | None = None,
                 model_prefix: str | None = None, include_cache: bool = False,
                 usd: bool = False) -> float:
    """滚动窗口用量：start_ms 之后的 (输入+输出[+缓存读]) 或成本(usd)。"""
    expr = "SUM(cost)" if usd else "SUM(input+output)" + ("+cache_read" if include_cache else "")
    sql = f"SELECT COALESCE({expr},0) AS v FROM usage_events WHERE ts>=?"
    args: list = [int(start_ms)]
    if tool:
        sql += " AND tool=?"
        args.append(tool)
    if model_prefix:
        sql += " AND model LIKE ?"
        args.append(model_prefix + "%")
    row = conn.execute(sql, args).fetchone()
    return row["v"] or 0


def quota_usage(conn, range_key: str, tool: str | None = None,
                model_prefix: str | None = None, include_cache: bool = False) -> tuple:
    """配额已用量：返回 (tokens, cost_usd)。tokens = 输入+输出(+可选缓存)。"""
    lo, hi = _range_bounds(range_key)
    expr = "SUM(input+output)" + ("+cache_read" if include_cache else "")
    sql = f"SELECT COALESCE({expr},0) AS t, COALESCE(SUM(cost),0) AS c FROM usage_events WHERE ts>=? AND ts<=?"
    args: list = [lo, hi]
    if tool:
        sql += " AND tool=?"
        args.append(tool)
    if model_prefix:
        sql += " AND model LIKE ?"
        args.append(model_prefix + "%")
    row = conn.execute(sql, args).fetchone()
    return row["t"], row["c"]


def reprice(conn, prices) -> int:
    """为所有 cost 为 NULL 的事件按价格表回填成本（价格表改完跑 tt scan / tt reprice）。"""
    from .pricing import cost_for
    rows = conn.execute(
        "SELECT id, model, input, output, cache_read, cache_write FROM usage_events WHERE cost IS NULL"
    ).fetchall()
    n = 0
    for r in rows:
        if not r["model"]:
            continue
        c, _ = cost_for(prices, r["model"], r["input"], r["output"],
                        r["cache_read"], r["cache_write"])
        if c is not None:
            conn.execute("UPDATE usage_events SET cost=? WHERE id=?", (c, r["id"]))
            n += 1
    conn.commit()
    return n


def session_detail(conn, tool: str, session_id: str) -> dict:
    """单会话钻取：按模型聚合 + 总计 + 项目路径。"""
    models = [dict(r) for r in conn.execute(
        """
        SELECT model,
               COUNT(*) AS events,
               COALESCE(SUM(input),0) AS input,
               COALESCE(SUM(output),0) AS output,
               COALESCE(SUM(cache_read),0) AS cache_read,
               COALESCE(SUM(cache_write),0) AS cache_write,
               COALESCE(SUM(cost),0) AS cost,
               MIN(ts) AS first_ts, MAX(ts) AS last_ts
        FROM usage_events WHERE tool=? AND session_id=?
        GROUP BY model ORDER BY input+output DESC
        """,
        (tool, session_id),
    )]
    meta = conn.execute(
        """
        SELECT COALESCE(MAX(NULLIF(project,'')),'') AS project,
               COUNT(*) AS events,
               COALESCE(SUM(input),0)+COALESCE(SUM(output),0) AS tokens,
               COALESCE(SUM(cost),0) AS cost,
               MIN(ts) AS first_ts, MAX(ts) AS last_ts
        FROM usage_events WHERE tool=? AND session_id=?
        """,
        (tool, session_id),
    ).fetchone()
    return {"models": models, **dict(meta)}


def sessions(conn, range_key: str = "all", tool: str | None = None, limit: int = 300) -> list[dict]:
    lo, hi = _range_bounds(range_key)
    sql = """
        SELECT tool, session_id, project,
               datetime(MAX(ts)/1000,'unixepoch','localtime') AS last_seen,
               MAX(ts) AS ts,
               MAX(model) AS model,
               COALESCE(SUM(input),0) AS input,
               COALESCE(SUM(output),0) AS output,
               COALESCE(SUM(cache_read),0) AS cache_read,
               COALESCE(SUM(cost),0) AS cost,
               COUNT(*) AS events
        FROM usage_events WHERE ts>=? AND ts<=?
    """
    args: list = [lo, hi]
    if tool:
        sql += " AND tool=?"
        args.append(tool)
    sql += " GROUP BY tool, session_id ORDER BY ts DESC LIMIT ?"
    args.append(limit)
    return [dict(r) for r in conn.execute(sql, args)]