"""扫描服务回归：无真实日志、网络或凭据访问。"""
import io
import os
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from tokentracker import server
from tokentracker import __main__ as cli


class InlineThread:
    def __init__(self, target, **kwargs):
        self.target = target
    def start(self):
        self.target()
    def join(self, timeout=None):
        pass
    def is_alive(self):
        return False


class ScanServiceTest(unittest.TestCase):
    def test_startup_interval_and_stop_with_injected_wait(self):
        now = [100]
        calls = []
        def scan(**kwargs):
            calls.append((now[0], kwargs))
            return {"results": {}, "repriced": 0}
        def wait(timeout):
            self.assertEqual(timeout, 60)
            now[0] += timeout
            return len(calls) >= 3
        service = server.ScanService(scan=scan, clock=lambda: now[0], wait=wait,
                                     thread_factory=InlineThread)
        service.start_auto()
        self.assertEqual([t for t, _ in calls], [100, 160, 220])
        status = service.snapshot()
        self.assertFalse(status["running"])
        self.assertEqual(status["last"]["started_at"], 220)
        self.assertEqual(status["last"]["finished_at"], 220)
        self.assertEqual(status["last"]["source"], "automatic")
        service.stop()
        self.assertFalse(service.request())
        self.assertEqual(len(calls), 3)

    def test_manual_and_automatic_share_lock(self):
        entered, release = threading.Event(), threading.Event()
        def scan(**kwargs):
            entered.set()
            release.wait(2)
            return {"results": {}, "repriced": 0}
        service = server.ScanService(scan=scan)
        try:
            self.assertTrue(service.request(source="manual"))
            self.assertTrue(entered.wait(1))
            self.assertFalse(service.request(source="automatic"))
            self.assertTrue(service.snapshot()["running"])
        finally:
            release.set()
            service.stop()
        self.assertFalse(service.snapshot()["running"])
        self.assertTrue(service.snapshot()["last"]["done"])

    def test_failure_records_timestamps_and_releases_lock(self):
        scan = Mock(side_effect=[RuntimeError("scan failed"), {"results": {}, "repriced": 2}])
        service = server.ScanService(scan=scan, clock=iter([10, 11, 12, 13]).__next__,
                                     thread_factory=InlineThread)
        self.assertTrue(service.request(full=True, tools=["claude"]))
        last = service.snapshot()["last"]
        self.assertEqual((last["started_at"], last["finished_at"], last["error"]), (10, 11, "scan failed"))
        self.assertTrue(service.request())
        self.assertNotIn("error", service.snapshot()["last"])
        self.assertEqual(service.snapshot()["last"]["repriced"], 2)
        service.stop()

    def test_scanner_errors_are_visible_and_connection_always_closes(self):
        conn = Mock()
        with patch.object(server.db, "connect", return_value=conn), patch.object(server.pricing, "load_prices", return_value={}), patch.object(server, "run_all", side_effect=RuntimeError("broken parser")):
            service = server.ScanService(thread_factory=InlineThread)
            service.request()
            self.assertIn("broken parser", service.snapshot()["last"]["error"])
            conn.close.assert_called_once()
        service = server.ScanService(scan=lambda **kw: {"results": {"codex": {"error": "bad file"}}, "repriced": 0}, thread_factory=InlineThread)
        service.request()
        self.assertIn("bad file", service.snapshot()["last"]["error"])

    def test_stop_wakes_waiting_scheduler_without_a_second_scan(self):
        waiting = threading.Event()
        scan = Mock(return_value={"results": {}, "repriced": 0})
        service = server.ScanService(scan=scan)
        def wait(timeout):
            waiting.set()
            return service._stop.wait(timeout)
        service._wait = wait
        service.start_auto()
        self.assertTrue(waiting.wait(1))
        service.stop()
        self.assertFalse(service._timer.is_alive())
        scan.assert_called_once()
        self.assertFalse(service.request())


class HandlerTest(unittest.TestCase):
    def handler(self, path, body=b"{}"):
        handler = object.__new__(server.Handler)
        handler.path = path
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler._send = Mock()
        handler.server = Mock(scan_service=Mock())
        return handler

    def test_manual_request_uses_shared_service(self):
        handler = self.handler("/api/scan", b'{"tools":["claude"],"full":true}')
        handler.server.scan_service.request.return_value = False
        handler.do_POST()
        handler.server.scan_service.request.assert_called_once_with(tools=["claude"], full=True, source="manual")
        self.assertEqual(handler._send.call_args.args[0], 409)

    def test_malformed_requests_do_not_start_scan(self):
        for body in (b'[]', b'not json', b'{"tools":["../../anything"]}', b'{"tools":"claude"}'):
            with self.subTest(body=body):
                handler = self.handler("/api/scan", body)
                handler.do_POST()
                self.assertEqual(handler._send.call_args.args[0], 400)
                handler.server.scan_service.request.assert_not_called()

    def test_daily_includes_time_quality_summary(self):
        handler = self.handler("/api/daily?range=day")
        conn = Mock()
        summary = {"unallocated": {"tokens": 30, "cost": 2, "events": 1}, "estimated_tokens": 10}
        with patch.object(server.db, "connect", return_value=conn), patch.object(server.db, "daily", return_value=[{"tokens": 50}]), patch.object(server.db, "time_summary", create=True, return_value=summary) as summarize:
            handler.do_GET()
        summarize.assert_called_once_with(conn, "day", bucket="hour")
        self.assertEqual(handler._send.call_args.args, (200, {"rows": [{"tokens": 50}], "summary": summary}))
        conn.close.assert_called_once()

    def test_aggregate_endpoints_keep_cache_and_unallocated_history(self):
        connect = server.db.connect
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "usage.db")
            conn = connect(path)
            server.db.put_event(conn, "claude", "exact", session_id="exact", ts=1700000000000,
                                input=1, output=2, cache_read=3, cache_write=4, cost=1)
            server.db.put_event(conn, "claude", "history", session_id="history", ts=1700000000000,
                                input=20, time_quality="unallocated", cost=2)
            conn.commit()
            conn.close()
            with patch.object(server.db, "connect", side_effect=lambda: connect(path)):
                payloads = {}
                for endpoint in ("stats", "models", "sessions", "daily"):
                    handler = self.handler(f"/api/{endpoint}?range=all")
                    handler.do_GET()
                    payloads[endpoint] = handler._send.call_args.args[1]
                detail = self.handler("/api/session_detail?tool=claude&session_id=exact")
                detail.do_GET()
                self.assertEqual(detail._send.call_args.args[1]["tokens"], 10)
            self.assertEqual(payloads["stats"]["total"]["tokens"], 30)
            self.assertEqual(payloads["stats"]["total"]["unallocated"]["tokens"], 20)
            for endpoint in ("models", "sessions"):
                self.assertEqual(sum(row["tokens"] for row in payloads[endpoint]["rows"]), 30)
                self.assertEqual(sum(row["cache_write"] for row in payloads[endpoint]["rows"]), 4)
            history = next(row for row in payloads["sessions"]["rows"] if row["session_id"] == "history")
            self.assertIsNone(history["last_seen"])
            self.assertEqual(sum(row["tokens"] for row in payloads["daily"]["rows"]), 10)
            self.assertEqual(payloads["daily"]["summary"]["unallocated"]["tokens"], 20)


class ServerLifecycleTest(unittest.TestCase):
    def test_default_one_shot_and_automatic_modes(self):
        for options, expected in (({}, None), ({"initial_scan": True}, "startup"),
                                  ({"auto_scan": True, "initial_scan": True}, "automatic")):
            with self.subTest(options=options):
                http = Mock(server_port=8765)
                service = Mock()
                with patch.dict(server._servers, {}, clear=True), patch.object(server, "ThreadingHTTPServer", return_value=http), patch.object(server, "ScanService", return_value=service), patch.object(server.threading, "Thread", InlineThread):
                    url = server.serve(**options)
                    if expected == "automatic":
                        service.start_auto.assert_called_once()
                        service.request.assert_not_called()
                    elif expected == "startup":
                        service.request.assert_called_once_with(source="startup")
                        service.start_auto.assert_not_called()
                    else:
                        service.request.assert_not_called()
                        service.start_auto.assert_not_called()
                    server.stop(url)
                    service.stop.assert_called_once()
                    http.shutdown.assert_called_once()
                    http.server_close.assert_called_once()

    def test_cli_auto_scan_is_opt_in_and_preserves_one_shot(self):
        for flags, auto, once in (([], False, False), (["--scan"], False, True), (["--auto-scan"], True, False)):
            with self.subTest(flags=flags), patch.object(server, "serve_blocking") as serve:
                cli.main(["serve", *flags])
                serve.assert_called_once_with(port=8765, on_ready=None, auto_scan=auto, initial_scan=once)

    def test_blocking_server_stops_even_if_ready_callback_fails(self):
        with patch.object(server, "serve", return_value="http://fake.invalid"), patch.object(server, "stop") as stop:
            with self.assertRaisesRegex(RuntimeError, "callback"):
                server.serve_blocking(on_ready=Mock(side_effect=RuntimeError("callback")))
            stop.assert_called_once_with("http://fake.invalid")


class CliScanTest(unittest.TestCase):
    def test_scan_reports_resets_and_unmapped_history(self):
        output = io.StringIO()
        result = {"hermes":{"added":1,"updated":2,"files":2,"counter_resets":1,"warning":"无法映射旧历史"}}
        with patch.object(cli.db,"connect",return_value=Mock()), patch.object(cli.pricing,"load_prices",return_value={}), patch.object(cli,"run_all",return_value=result), patch.object(cli.db,"reprice",return_value=0), patch("sys.stdout",output):
            cli.cmd_scan(SimpleNamespace(tool=None,full=False,reset=False))
        self.assertIn("重置",output.getvalue())
        self.assertIn("无法映射旧历史",output.getvalue())

    def test_explicit_reset_removes_only_selected_snapshot_baselines(self):
        connect = server.db.connect
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "usage.db")
            conn = connect(path)
            for tool in ("opencode", "hermes"):
                server.db.put_event(conn, tool, "old", input=10, time_quality="unallocated")
                conn.execute("INSERT INTO aggregate_snapshots VALUES (?,?,?,?,?,?)",
                             (tool, "fixture", "session", '{}', 1700000000000, 0))
                server.db.set_scan_cursor(conn, tool, {"fixture": True})
            conn.close()
            output = io.StringIO()
            with patch.object(cli.db, "connect", side_effect=lambda: connect(path)), patch.object(cli.pricing, "load_prices", return_value={}), patch.object(cli, "run_all", return_value={}) as run, patch("sys.stdout", output):
                cli.cmd_scan(SimpleNamespace(tool=["opencode"], full=False, reset=True))
            self.assertTrue(run.call_args.kwargs["full"])
            self.assertEqual(run.call_args.kwargs["tools"], ["opencode"])
            conn = connect(path)
            try:
                for table in ("usage_events", "scan_state", "aggregate_snapshots"):
                    self.assertEqual([r[0] for r in conn.execute(f"SELECT tool FROM {table}")], ["hermes"])
            finally:
                conn.close()
            self.assertIn("无法恢复", output.getvalue())

    def test_scan_and_quota_failures_close_connections(self):
        conn = Mock()
        with patch.object(cli.db, "connect", return_value=conn), patch.object(cli.pricing, "load_prices", return_value={}), patch.object(cli, "run_all", side_effect=RuntimeError("scanner")):
            with self.assertRaisesRegex(RuntimeError, "scanner"):
                cli.cmd_scan(SimpleNamespace(tool=None, full=False, reset=False))
            conn.close.assert_called_once()
        conn = Mock()
        with patch.object(cli.db, "connect", return_value=conn), patch("tokentracker.quotas.compute", side_effect=RuntimeError("quota")):
            with self.assertRaisesRegex(RuntimeError, "quota"):
                cli.cmd_quotas(SimpleNamespace())
            conn.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
