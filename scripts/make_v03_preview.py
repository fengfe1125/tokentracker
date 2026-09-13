#!/usr/bin/env python3
"""Create invented data for packaged v0.3 UI acceptance; never reads user logs."""
import json
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tokentracker import db


def create(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    database = destination / "usage.db"
    if database.exists():
        raise SystemExit("Preview database already exists; choose a fresh directory")
    conn = db.connect(str(database))
    now = int(time.time() * 1000)
    today = datetime.now().replace(hour=10, minute=0, second=0, microsecond=0)
    for project_index, project in enumerate(("Atlas", "Garden", "Notebook")):
        for day in range(21):
            when = int((today - timedelta(days=day)).timestamp() * 1000)
            for step, tool in enumerate(("codex", "pi", "dsh")):
                session = f"demo-{project_index}-{day}"
                key = f"{session}-{step}"
                multiplier = 6 if day == 0 and project_index == 0 else 1
                tokens = (20000 + project_index * 4000 + step * 2000) * multiplier
                db.put_event(conn, tool, key, session_id=session,
                             project=f"/tmp/TokenTracker-Demo/{project}",
                             ts=when+step*60000, model="demo-model",
                             input=tokens, output=tokens//5, cache_read=tokens//2,
                             cost=tokens/1000000*3)
                db.set_session_title(conn, tool, session, f"{project} — example task {day+1}")
                for call in range(3):
                    db.put_activity_event(conn, tool, key+f"-call-{call}", session_id=session,
                                          raw_name=("read", "apply_patch", "test")[call],
                                          call_id=key+f"-call-{call}", turn_id="turn-1",
                                          started_at=when+call*1000, ended_at=when+call*1000+450,
                                          duration_ms=450, status="error" if call == 2 and day == 0 else "success")
    for tool in ("codex", "pi", "dsh"):
        conn.execute("INSERT INTO scan_health VALUES (?,?,?,?,?,?,?,?,?,?)",
                     (tool,"正常",now,now,.25,21,63,0,"",2))
        conn.execute("INSERT INTO scan_diagnostics VALUES (?,?,?)",(tool,0,0))
    budget = {"id":"demo-budget","unit":"tokens","period":"day","limit":950000}
    conn.execute("INSERT INTO budgets VALUES (?,?)",("demo-budget",json.dumps(budget)))
    conn.commit()
    conn.close()
    (destination / "settings.json").write_text('{"publish_enabled":false}', encoding="utf-8")
    print(database)


if __name__ == "__main__":
    create(sys.argv[1])
