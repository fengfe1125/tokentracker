"""Python CLI 回归测试；桌面与浏览器入口已退役。"""
import io
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from tokentracker import __main__ as cli
from tokentracker import db


class CliScanTest(unittest.TestCase):
    def test_scan_reports_resets_and_unmapped_history(self):
        output = io.StringIO()
        result = {
            "hermes": {
                "added": 1,
                "updated": 2,
                "files": 2,
                "counter_resets": 1,
                "warning": "无法映射旧历史",
            }
        }
        with (
            patch.object(cli.db, "connect", return_value=Mock()),
            patch.object(cli.pricing, "load_prices", return_value={}),
            patch.object(cli, "run_all", return_value=result),
            patch.object(cli.db, "reprice", return_value=0),
            patch("sys.stdout", output),
        ):
            cli.cmd_scan(SimpleNamespace(tool=None, full=False, reset=False))
        self.assertIn("重置", output.getvalue())
        self.assertIn("无法映射旧历史", output.getvalue())

    def test_explicit_reset_removes_only_selected_snapshot_baselines(self):
        connect = db.connect
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "usage.db")
            conn = connect(path)
            for tool in ("opencode", "hermes"):
                db.put_event(conn, tool, "old", input=10, time_quality="unallocated")
                conn.execute(
                    "INSERT INTO aggregate_snapshots VALUES (?,?,?,?,?,?)",
                    (tool, "fixture", "session", "{}", 1700000000000, 0),
                )
                db.set_scan_cursor(conn, tool, {"fixture": True})
            conn.close()

            output = io.StringIO()
            with (
                patch.object(cli.db, "connect", side_effect=lambda: connect(path)),
                patch.object(cli.pricing, "load_prices", return_value={}),
                patch.object(cli, "run_all", return_value={}) as run,
                patch("sys.stdout", output),
            ):
                cli.cmd_scan(SimpleNamespace(tool=["opencode"], full=False, reset=True))

            self.assertTrue(run.call_args.kwargs["full"])
            self.assertEqual(run.call_args.kwargs["tools"], ["opencode"])
            conn = connect(path)
            try:
                for table in ("usage_events", "scan_state", "aggregate_snapshots"):
                    self.assertEqual(
                        [row[0] for row in conn.execute(f"SELECT tool FROM {table}")],
                        ["hermes"],
                    )
            finally:
                conn.close()
            self.assertIn("无法恢复", output.getvalue())

    def test_scan_and_quota_failures_close_connections(self):
        conn = Mock()
        with (
            patch.object(cli.db, "connect", return_value=conn),
            patch.object(cli.pricing, "load_prices", return_value={}),
            patch.object(cli, "run_all", side_effect=RuntimeError("scanner")),
        ):
            with self.assertRaisesRegex(RuntimeError, "scanner"):
                cli.cmd_scan(SimpleNamespace(tool=None, full=False, reset=False))
            conn.close.assert_called_once()

        conn = Mock()
        with (
            patch.object(cli.db, "connect", return_value=conn),
            patch("tokentracker.quotas.compute", side_effect=RuntimeError("quota")),
        ):
            with self.assertRaisesRegex(RuntimeError, "quota"):
                cli.cmd_quotas(SimpleNamespace())
            conn.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
