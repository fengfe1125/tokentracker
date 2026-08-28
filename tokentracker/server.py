"""本地 HTTP 服务：静态仪表盘 + JSON API。"""
from __future__ import annotations

import copy
import json
import mimetypes
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import db, prefs, pricing
from .quotas import DEFAULT_QUOTAS, compute as compute_quotas
from .scanners import ALL, detect_all, run_all

# 资源根目录：PyInstaller 打包后位于 _MEIPASS，开发时位于仓库根
_BASE = sys._MEIPASS if getattr(sys, "frozen", False) else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(_BASE, "web")
APP_WEB_DIR = os.path.join(_BASE, "app", "web")


class ScanService:
    """One scan at a time, shared by HTTP actions and the desktop timer.

    The scheduler belongs to the Python service, so hiding or throttling a web
    view cannot stop ingestion. Clock/wait/worker injection keeps tests isolated.
    """

    def __init__(self, *, scan=None, interval=60, clock=None, wait=None,
                 thread_factory=threading.Thread):
        self._scan = scan or self._scan_logs
        self._interval = interval
        self._clock = clock or time.time
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._wait = wait or self._stop.wait
        self._thread = thread_factory
        self._worker = self._timer = None
        self._status = {"running": False, "last": None}

    @staticmethod
    def _scan_logs(*, tools=None, full=False):
        conn = db.connect()
        try:
            prices = pricing.load_prices()
            results = run_all(conn, prices, tools=tools, full=full)
            return {"results": results, "repriced": db.reprice(conn, prices)}
        finally:
            conn.close()

    def snapshot(self):
        with self._lock:
            return copy.deepcopy(self._status)

    def request(self, *, tools=None, full=False, source="manual"):
        with self._lock:
            if self._stop.is_set() or self._status["running"]:
                return False
            last = {"started": True, "done": False,
                    "started_at": self._clock(), "source": source}
            self._status = {"running": True, "last": last}
            worker = self._thread(target=lambda: self._run(last, tools, full), daemon=True)
            self._worker = worker
            worker.start()
        return True

    def _run(self, started, tools, full):
        last = dict(started)
        try:
            last.update(self._scan(tools=tools, full=full))
            errors = [f"{name}: {result['error']}"
                      for name, result in last.get("results", {}).items()
                      if result.get("error")]
            if errors:
                last["error"] = "; ".join(errors)
        except Exception as e:  # A failed scan must not poison the shared lock.
            last["error"] = str(e)
        finally:
            last.update(done=True, finished_at=self._clock())
            with self._lock:
                self._status = {"running": False, "last": last}

    def start_auto(self):
        with self._lock:
            if self._stop.is_set() or self._timer is not None:
                return
            timer = self._thread(target=self._auto_loop, daemon=True)
            self._timer = timer
            timer.start()

    def _auto_loop(self):
        self.request(source="automatic")
        while not self._wait(self._interval):
            if self._stop.is_set():
                break
            self.request(source="automatic")

    def stop(self):
        # Do not cancel an in-progress SQLite transaction; prevent new scans
        # and give the current worker a bounded opportunity to finish.
        with self._lock:
            self._stop.set()
        for thread in (self._timer, self._worker):
            if thread and thread is not threading.current_thread():
                thread.join(timeout=2)


_servers = {}

# 设置页（/api/settings）允许读写的键与校验规则；未列出的键一律拒绝。
_PROVIDER_ID = re.compile(r"off|[a-z0-9][a-z0-9_-]{0,23}\Z")
_SETTINGS_SCHEMA = {
    "menubar_provider": lambda v: isinstance(v, str) and bool(_PROVIDER_ID.fullmatch(v)),
    "menubar_compact": lambda v: isinstance(v, bool),
    "launch_at_login": lambda v: isinstance(v, bool),
}


def _settings_payload() -> dict:
    raw = prefs.load_prefs()
    settings = dict(prefs.DEFAULTS)
    settings.update({k: v for k, v in raw.items()
                     if k in _SETTINGS_SCHEMA and _SETTINGS_SCHEMA[k](v)})
    providers = [{"id": e["id"], "name": e["name"]}
                 for e in DEFAULT_QUOTAS.get("entries", [])]
    return {"settings": settings, "providers": providers}


class Handler(BaseHTTPRequestHandler):
    server_version = "TokenTracker/0.1"

    def log_message(self, *args):  # 静默访问日志
        pass

    # ------------------------------------------------------------ 工具 ----
    def _json_object(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 <= length <= 16384:
            raise ValueError("invalid request size")
        body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        if not isinstance(body, dict):
            raise ValueError("expected a JSON object")
        return body

    def _send(self, code: int, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _static(self, path: str, base: str | None = None):
        base = os.path.abspath(base or WEB_DIR)
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
                range_key = q.get("range", ["all"])[0]
                rows = db.daily(conn, range_key)
                summary = db.time_summary(conn, range_key,
                                          bucket="hour" if range_key == "day" else "day")
            finally:
                conn.close()
            self._send(200, {"rows": rows, "summary": summary})
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
        elif p == "/api/session_detail":
            conn = db.connect()
            try:
                data = db.session_detail(conn, q.get("tool", [""])[0],
                                         q.get("session_id", [""])[0])
            finally:
                conn.close()
            self._send(200, data)
        elif p == "/api/quotas":
            conn = db.connect()
            try:
                data = compute_quotas(conn, force=q.get("force", [""])[0] in ("1", "true"))
            finally:
                conn.close()
            self._send(200, data)
        elif p == "/api/scan/status":
            self._send(200, self.server.scan_service.snapshot())
        elif p == "/api/settings":
            self._send(200, _settings_payload())
        elif p.startswith("/app/"):
            self._static(p[len("/app/"):], APP_WEB_DIR)
        elif p.startswith("/api/"):
            self._send(404, {"error": "unknown api"})
        else:
            self._static(p)

    def do_POST(self):
        p = urlparse(self.path).path
        if p == "/api/settings":
            try:
                body = self._json_object()
                unknown = [k for k in body if k not in _SETTINGS_SCHEMA]
                if unknown:
                    raise ValueError("unknown settings: " + ", ".join(sorted(unknown)))
                invalid = [k for k, v in body.items() if not _SETTINGS_SCHEMA[k](v)]
                if invalid:
                    raise ValueError("invalid value for: " + ", ".join(sorted(invalid)))
            except (ValueError, UnicodeError) as e:
                self._send(400, {"error": str(e)})
                return
            current = prefs.load_prefs()
            current.update(body)
            prefs.save_prefs(current)
            self._send(200, {"ok": True, **_settings_payload()})
            return
        if p == "/api/scan":
            try:
                body = self._json_object()
                tools = body.get("tools")
                if tools is not None and (not isinstance(tools, list) or
                                          any(not isinstance(t, str) or t not in ALL for t in tools)):
                    raise ValueError("unknown scan tools")
                if "full" in body and not isinstance(body["full"], bool):
                    raise ValueError("full must be a boolean")
            except (ValueError, UnicodeError) as e:
                self._send(400, {"error": str(e)})
                return
            tools = body.get("tools") or None
            full = bool(body.get("full"))
            if self.server.scan_service.request(tools=tools, full=full, source="manual"):
                self._send(200, {"ok": True})
            else:
                self._send(409, {"error": "scan already running or service stopped"})
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


def serve(port: int = 8765, *, auto_scan=False, initial_scan=False, scan_interval=60) -> str:
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
    url = f"http://127.0.0.1:{srv.server_port}"
    srv.scan_service = ScanService(interval=scan_interval)
    _servers[url] = srv
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    if auto_scan:
        srv.scan_service.start_auto()
    elif initial_scan:
        srv.scan_service.request(source="startup")
    return url


def stop(url=None):
    """Stop a server and its scheduler (or all servers owned by this process)."""
    for key in ([url] if url else list(_servers)):
        srv = _servers.pop(key, None)
        if srv is not None:
            srv.scan_service.stop()
            srv.shutdown()
            srv.server_close()


def serve_blocking(port: int = 8765, on_ready=None, *, auto_scan=False, initial_scan=False):
    """前台阻塞运行（Ctrl-C 退出）。on_ready(url) 在就绪后回调。"""
    url = serve(port, auto_scan=auto_scan, initial_scan=initial_scan)
    print(f"TokenTracker 仪表盘已启动: {url}  (Ctrl-C 退出)")
    try:
        if on_ready:
            on_ready(url)
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        pass
    finally:
        stop(url)
