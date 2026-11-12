#!/usr/bin/env python3
"""Create invented data for packaged UI acceptance; never reads user logs.

The schema comes from the Swift store (tt-swift creates an empty database),
then invented usage, sessions, projects, activity, health and one budget are
written with sqlite3 directly.

    python3 scripts/make_v03_preview.py /tmp/tt-preview
    TT_UI_PREVIEW=1 TT_UI_TEST_SHOW_MAIN=1 TOKENTRACKER_DB=/tmp/tt-preview/usage.db \\
      "build/TokenTracker Dev.app/Contents/MacOS/TokenTracker"
"""
import json
import os
import random
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# tool -> [(model, provider, USD per input token or None for unpriced)]
MODELS = {
    "claude": [("claude-opus-5-5", "anthropic", 30e-6)],
    "codex": [("gpt-6-astra", "openai", 8e-6), ("gpt-6.1-terra", "openai", 4e-6)],
    "opencode": [("demo/flash-v4", "", None)],
    "dsh": [("deepseek-flash", "deepseek", 0.4e-6)],
    "pi": [("demo-local-model", "", None)],
}
SCALE = {"claude": 6, "codex": 3, "opencode": 1.5, "dsh": 2, "pi": 0.4}
PROJECTS = ["Atlas", "Garden", "Notebook", "a-very-long-project-directory-name-for-truncation"]
TITLES = ["重构设置页的表单分组", "Fix flaky scheduler test", "给周报加上导出入口",
          "Investigate cache hit regression", "整理发布脚本", "Add dark mode tokens"]
CALLS = ["read", "apply_patch", "shell", "grep", "test"]


def empty_database(database):
    """Let the Swift store create the schema so this script never drifts from it."""
    binary = Path(os.environ.get("TT_SWIFT", ROOT / "swift/.build/debug/tt-swift"))
    if not binary.exists():
        subprocess.run(["swift", "build", "--package-path", str(ROOT / "swift"),
                        "--product", "tt-swift"], check=True)
    subprocess.run([str(binary), "stats"], check=True, stdout=subprocess.DEVNULL,
                   env={**os.environ, "TOKENTRACKER_DB": str(database)})


def create(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    database = destination / "usage.db"
    if database.exists():
        raise SystemExit("Preview database already exists; choose a fresh directory")
    empty_database(database)
    conn = sqlite3.connect(database)
    tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    missing = {"usage_events", "session_meta", "agent_activity_events", "projects",
               "project_sessions", "scan_health", "scan_diagnostics", "budgets"} - tables
    if missing:
        raise SystemExit(f"Schema is missing tables: {sorted(missing)}")

    rng = random.Random(7)
    now = datetime.now()
    now_ms = int(time.time() * 1000)
    for index, name in enumerate(PROJECTS):
        conn.execute("INSERT INTO projects(id,name) VALUES(?,?)", (f"demo-p{index}", name))

    events = sessions = 0
    for day in range(40):
        base = (now - timedelta(days=day)).replace(minute=0, second=0, microsecond=0)
        for tool, models in MODELS.items():
            if tool == "pi" and day % 3:
                continue
            for slot in range(rng.randint(1, 3)):
                when = base.replace(hour=rng.choice([9, 10, 11, 14, 15, 16, 20, 21]))
                if when > now:
                    when = now - timedelta(minutes=rng.randint(5, 90))
                session = f"demo-{tool}-{day}-{slot}"
                model, provider, rate = rng.choice(models)
                # One session in ten stays unassigned, like usage without a reliable directory.
                project = rng.choice([0, 0, 0, 0, 1, 1, 1, 2, 3, None])
                path = f"/tmp/TokenTracker-Demo/{PROJECTS[project]}" if project is not None else ""
                sessions += 1
                conn.execute("INSERT INTO session_meta(tool,session_id,title,updated_at) VALUES(?,?,?,?)",
                             (tool, session, rng.choice(TITLES), int(when.timestamp() * 1000)))
                if project is not None:
                    conn.execute("INSERT INTO project_sessions(tool,session_id,project_id) VALUES(?,?,?)",
                                 (tool, session, f"demo-p{project}"))
                for step in range(rng.randint(2, 6)):
                    scale = SCALE[tool] * rng.uniform(0.3, 1.8)
                    cache_read, inp = int(900_000 * scale), int(22_000 * scale)
                    cache_write, out = int(40_000 * scale), int(9_000 * scale)
                    cost = None if rate is None else (
                        (inp + cache_write) * rate + cache_read * rate * 0.1 + out * rate * 5)
                    at = int((when + timedelta(minutes=step * 7)).timestamp() * 1000)
                    events += 1
                    conn.execute(
                        "INSERT INTO usage_events(tool,src_key,session_id,project,ts,model,input,output,"
                        "cache_read,cache_write,cost,provider,cost_source) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (tool, f"u{events}", session, path, at, model, inp, out,
                         cache_read, cache_write, cost, provider, "estimate"))
                    if tool in ("claude", "codex") and day < 14:
                        for call in range(rng.randint(1, 3)):
                            name = rng.choice(CALLS)
                            failed = name == "test" and rng.random() < 0.2
                            conn.execute(
                                "INSERT INTO agent_activity_events(agent,session_id,turn_id,raw_name,"
                                "canonical_name,call_id,started_at,ended_at,duration_ms,status,src_key) "
                                "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                                (tool, session, f"turn-{step}", name, name, f"u{events}-c{call}",
                                 at + call * 1000, at + call * 1000 + 450, 450,
                                 "error" if failed else "success", f"u{events}-c{call}"))

    for tool in MODELS:
        conn.execute("INSERT INTO scan_health VALUES (?,?,?,?,?,?,?,?,?,?)",
                     (tool, "正常", now_ms, now_ms, .25, 21, 63, 0, "", 2))
        conn.execute("INSERT INTO scan_diagnostics VALUES (?,?,?)", (tool, 0, 0))
    budget = {"id": "demo-budget", "unit": "tokens", "period": "day", "limit": 400_000_000}
    conn.execute("INSERT INTO budgets VALUES (?,?)", ("demo-budget", json.dumps(budget)))
    conn.commit()
    conn.close()
    (destination / "settings.json").write_text('{"publish_enabled":false,"unit_yi":true}',
                                               encoding="utf-8")
    print(f"{database}: {events} usage events, {sessions} sessions")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: make_v03_preview.py <fresh directory>")
    create(sys.argv[1])
