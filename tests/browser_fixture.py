"""Manual browser regression server; synthetic usage and quotas, no real sources.

Run: python3 tests/browser_fixture.py  (open the printed /app/ and / URLs).
Ctrl-C shuts down the server and removes the temporary database.
"""
from datetime import datetime
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tokentracker import db, server

ATTACK = '<img src=x onerror="document.body.dataset.reviewProbe=1">'


def main():
    with tempfile.TemporaryDirectory(prefix="tt_browser_") as tmp:
        with patch.dict(os.environ, {"TOKENTRACKER_DB": os.path.join(tmp, "usage.db")}):
            conn = db.connect()
            now = int(time.time()*1000)
            hour = int(datetime.now().replace(minute=0, second=0, microsecond=0).timestamp()*1000)
            db.put_event(conn,"claude","exact",session_id="fixture",project=ATTACK,model=ATTACK,
                         ts=now,input=100,output=20,cache_read=200,cache_write=20,cost=.56)
            db.put_event(conn,"claude","history",session_id="fixture",project=ATTACK,model=ATTACK,
                         ts=1,input=1000,time_quality="unallocated",cost=.1)
            db.put_event(conn,"claude","observed",session_id="fixture",project=ATTACK,model=ATTACK,
                         ts=now,input=100,time_quality="observed",interval_start=hour,cost=.1)
            conn.commit()
            conn.close()
            quotas = {"entries": [{"id": ATTACK, "name": ATTACK, "plan": ATTACK,
                "source": "official", "via": "oauth", "note": ATTACK, "windows": [
                    {"key": "5h", "label": ATTACK, "pct":45, "source":"official", "stale":True,
                     "unit":"pct", "used":None, "limit":None, "resets_at":None},
                    {"key":"month", "label":"月度", "pct":10, "source":"local", "stale":False,
                     "unit":"tokens", "used":100, "limit":1000, "unallocated":1000, "resets_at":None}]}]}
            with patch.object(server,"compute_quotas",return_value=quotas), patch.object(
                    server,"detect_all",return_value={"claude":{"installed":True,"detail":"synthetic fixture"}}):
                url = server.serve(18785)
                server._servers[url].scan_service = server.ScanService(scan=lambda **kw: {"results": {}})
                print(url + "/app/", flush=True)
                try:
                    threading.Event().wait()
                except KeyboardInterrupt:
                    pass
                finally:
                    server.stop(url)


if __name__ == "__main__":
    main()
