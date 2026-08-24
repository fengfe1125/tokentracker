"""本地 HTTP 服务：静态仪表盘 + JSON API。"""
from __future__ import annotations

import json
import mimetypes
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import db, pricing
from .quotas import compute as compute_quotas
from .scanners import detect_all, run_all

WEB_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web")

_scan_lock = threading.Lock()
_scan_status = {"running": False, "last": None}


class Handler(BaseHTTPRequestHandler):
    server_version = "TokenTracker/0.1"

    def log_message(self, *args):  # 静默访问日志
        pass

    # ------------------------------------------------------------ 工具 ----
    def _send(self, code: int, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _static(self, path: str):
        base = os.path.abspath(WEB_DIR)
        safe = os.path.abspath(os.path.join(base, path.lstrip("/")))
        if not (safe == base or safe.startswith(base + os.sep)):
            self.send_error(403)
            return
        if os.path.isdir(safe):
            safe = os.path.join(safe, "index.html")
        try:
            with open(safe, "rb") as f:
                data = f.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(safe)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    # ------------------------------------------------------------ 路由 ----
    def do_GET(self):
        url = urlparse(self.path)
        p = url.path
        q = parse_qs(url.query)
        if p == "/api/detect":
            self._send(200, detect_all())
        elif p == "/api/stats":
            self._send(200, self._stats(q))
        elif p == "/api/daily":
            conn = db.connect()
            try:
                rows = db.daily(conn, q.get("range", ["all"])[0])
            finally:
                conn.close()
            self._send(200, {"rows": rows})
        elif p == "/api/models":
            conn = db.connect()
            try:
                rows = db.models(conn, q.get("range", ["all"])[0],
                                 q.get("tool", [None])[0] or None)
            finally:
                conn.close()
            self._send(200, {"rows": rows})
        elif p == "/api/sessions":
            conn = db.connect()
            try:
                rows = db.sessions(conn, q.get("range", ["all"])[0],
                                   q.get("tool", [None])[0] or None,
                                   int(q.get("limit", ["300"])[0]))
            finally:
                conn.close()
            self._send(200, {"rows": rows})
        elif p == "/api/quotas":
            conn = db.connect()
            try:
                data = compute_quotas(conn)
            finally:
                conn.close()
            self._send(200, data)
        elif p == "/api/scan/status":
            with _scan_lock:
                self._send(200, dict(_scan_status))
        elif p.startswith("/api/"):
            self._send(404, {"error": "unknown api"})
        else:
            self._static(p)

    def do_POST(self):
        p = urlparse(self.path).path
        if p == "/api/scan":
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length).decode("utf-8") or "{}") if length else {}
            with _scan_lock:
                if _scan_status["running"]:
                    self._send(409, {"error": "scan already running"})
                    return
                _scan_status["running"] = True
                _scan_status["last"] = {"started": True, "done": False}
            tools = body.get("tools") or None
            full = bool(body.get("full"))

            def _work():
                try:
                    conn = db.connect()
                    prices = pricing.load_prices()
                    results = run_all(conn, prices, tools=tools, full=full)
                    repriced = db.reprice(conn, prices)
                    conn.close()
                    with _scan_lock:
                        _scan_status.update(running=False, last={"done": True, "results": results, "repriced": repriced})
                except Exception as e:  # noqa: BLE001
                    with _scan_lock:
                        _scan_status.update(running=False, last={"done": True, "error": str(e)})

            threading.Thread(target=_work, daemon=True).start()
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "unknown api"})

    def _stats(self, q: dict):
        conn = db.connect()
        try:
            rows, total = db.stats(conn, q.get("range", ["all"])[0],
                                   q.get("tool", [None])[0] or None)
        finally:
            conn.close()
        return {"rows": rows, "total": total}


def serve(port: int = 8765) -> str:
    """在 port 起的空闲端口上启动服务，返回实际 URL。"""
    srv = None
    for p in range(port, port + 11):
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", p), Handler)
            break
        except OSError:
            continue
    if srv is None:
        raise SystemExit(f"端口 {port}-{port+10} 均被占用，请用 --port 指定其他端口")
    url = f"http://127.0.0.1:{p}"
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return url


def serve_blocking(port: int = 8765, on_ready=None):
    """前台阻塞运行（Ctrl-C 退出）。on_ready(url) 在就绪后回调。"""
    import time
    url = serve(port)
    print(f"TokenTracker 仪表盘已启动: {url}  (Ctrl-C 退出)")
    if on_ready:
        on_ready(url)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass