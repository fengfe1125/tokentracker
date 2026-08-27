"""冒烟测试：核心逻辑不依赖 macOS / 网络 / 真实日志，CI 可直接跑。

运行：python -m unittest discover -s tests -v
"""
import json
import os
import tempfile
import unittest

# 隔离测试数据库与配额配置（import 前设置）
_TMP = tempfile.mkdtemp(prefix="tt_test_")
os.environ["TOKENTRACKER_DB"] = os.path.join(_TMP, "usage.db")
os.environ["TOKENTRACKER_QUOTAS"] = os.path.join(_TMP, "quotas.json")

from tokentracker import db, pricing  # noqa: E402


class PricingTest(unittest.TestCase):
    def test_longest_substring_match(self):
        prices = {"default": {"input": 1, "output": 1},
                  "models": {"gpt-5": {"input": 2, "output": 2},
                             "gpt-5.6-luna": {"input": 9, "output": 9}}}
        cost, _ = pricing.cost_for(prices, "gpt-5.6-luna", 1_000_000, 0)
        self.assertEqual(cost, 9.0)   # 不能被 "gpt-5" 抢先命中
        cost, _ = pricing.cost_for(prices, "gpt-5", 1_000_000, 0)
        self.assertEqual(cost, 2.0)

    def test_default_fallback(self):
        prices = {"default": {"input": 1, "output": 0}, "models": {}}
        cost, _ = pricing.cost_for(prices, "unknown-model", 1_000_000, 0)
        self.assertEqual(cost, 1.0)


class DbTest(unittest.TestCase):
    def setUp(self):
        if os.path.exists(os.environ["TOKENTRACKER_DB"]):
            os.remove(os.environ["TOKENTRACKER_DB"])
        self.conn = db.connect()

    def tearDown(self):
        self.conn.close()

    def test_put_event_idempotent(self):
        n1 = db.put_event(self.conn, "t", "k1", input=10, output=5)
        n2 = db.put_event(self.conn, "t", "k1", input=10, output=5)
        n3 = db.put_event(self.conn, "t", "k2", input=1, output=1)
        self.assertEqual((n1, n2, n3), (1, 0, 1))

    def test_stats_and_session_detail(self):
        db.put_event(self.conn, "claude", "s1|m1", session_id="s1",
                     project="proj", model="m", input=100, output=50, cost=0.5)
        db.put_event(self.conn, "claude", "s1|m2", session_id="s1",
                     project="proj", model="m", input=200, output=60, cost=0.7)
        rows, total = db.stats(self.conn, "all")
        self.assertEqual(total["input"], 300)
        self.assertEqual(total["output"], 110)
        self.assertAlmostEqual(total["cost"], 1.2)
        d = db.session_detail(self.conn, "claude", "s1")
        self.assertEqual(d["events"], 2)
        self.assertEqual(d["tokens"], 410)
        self.assertEqual(len(d["models"]), 1)
        self.assertEqual(d["project"], "proj")
        # 每日聚合
        self.assertEqual(len(db.daily(self.conn, "all")), 1)

    def test_daily_day_range_is_hourly(self):
        import time
        from datetime import datetime
        now = time.time()
        t1, t2 = int((now - 120) * 1000), int((now - 30) * 1000)
        db.put_event(self.conn, "claude", "h1", ts=t1, input=10, output=5)
        db.put_event(self.conn, "claude", "h2", ts=t2, input=20, output=5)
        rows = db.daily(self.conn, "day")
        # 今天范围按小时聚合：标签形如 "HH:00"，行数 = 实际覆盖的小时数
        for r in rows:
            self.assertRegex(r["d"], r"^\d{2}:00$")
        expect = len({datetime.fromtimestamp(t / 1000).strftime("%H:00") for t in (t1, t2)})
        self.assertEqual(len(rows), expect)
        self.assertEqual(sum(r["input"] for r in rows), 30)


class QuotasTest(unittest.TestCase):
    def setUp(self):
        if os.path.exists(os.environ["TOKENTRACKER_DB"]):
            os.remove(os.environ["TOKENTRACKER_DB"])
        with open(os.environ["TOKENTRACKER_QUOTAS"], "w", encoding="utf-8") as f:
            json.dump({"entries": [{
                "id": "t", "name": "T", "plan": "", "tool": "claude",
                "windows": {"5h": {"label": "5 小时", "limit_tokens": 1000}},
            }]}, f)

    def test_local_quota_pct(self):
        from tokentracker import quotas
        conn = db.connect()
        db.put_event(conn, "claude", "k", input=400, output=100)
        data = quotas.compute(conn)
        conn.close()
        win = data["entries"][0]["windows"][0]
        self.assertEqual(win["source"], "local")
        self.assertEqual(win["pct"], 50.0)


class ClaudeScannerTest(unittest.TestCase):
    def setUp(self):
        if os.path.exists(os.environ["TOKENTRACKER_DB"]):
            os.remove(os.environ["TOKENTRACKER_DB"])
        self.dir = tempfile.mkdtemp(prefix="tt_claude_")
        os.environ["CLAUDE_PROJECTS_DIR"] = self.dir

    def test_scan_idempotent(self):
        from tokentracker.scanners import claude
        proj = os.path.join(self.dir, "-tmp-proj")
        os.makedirs(proj)
        line = {"type": "assistant", "timestamp": "2026-08-25T01:00:00Z",
                "message": {"id": "msg_1", "model": "claude-opus-5",
                            "usage": {"input_tokens": 10, "output_tokens": 5,
                                      "cache_read_input_tokens": 2,
                                      "cache_creation_input_tokens": 1}}}
        with open(os.path.join(proj, "sess1.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps(line) + "\n")
        conn = db.connect()
        r1 = claude.scan(conn, pricing.DEFAULT_PRICES)
        r2 = claude.scan(conn, pricing.DEFAULT_PRICES)
        conn.close()
        self.assertEqual(r1["added"], 1)
        self.assertEqual(r2["added"], 0)   # 重复扫描不重复计数


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from tokentracker import server
        cls.url = server.serve(18765)

    def _get(self, path):
        import urllib.request
        with urllib.request.urlopen(self.url + path, timeout=5) as r:
            return json.loads(r.read().decode("utf-8"))

    def test_routes(self):
        self.assertIn("total", self._get("/api/stats?range=day"))
        self.assertIn("rows", self._get("/api/sessions"))
        self.assertIn("models", self._get("/api/session_detail?tool=t&session_id=s"))
        self.assertIn("running", self._get("/api/scan/status"))
        self.assertIn("claude", self._get("/api/detect"))


class BillingTest(unittest.TestCase):
    """官方配额抓取的回退链：全部离线，用 monkeypatch 隔离网络/钥匙串/桌面 App。"""

    def setUp(self):
        from tokentracker import billing
        self.b = billing
        # 快照路径隔离到临时目录
        self._restore = [("_claude_snap_path", billing._claude_snap_path)]
        billing._claude_snap_path = lambda: os.path.join(_TMP, "claude_cred_backup.json")
        if os.path.exists(billing._claude_snap_path()):
            os.remove(billing._claude_snap_path())
        # ~ 重定向到空临时目录：绝不读真实钥匙串替代文件 / 桌面 App 采样
        import tokentracker.billing as bm
        self._restore.append(("_expanduser", bm.os.path.expanduser))
        real = self._restore[-1][1]
        empty = os.path.join(_TMP, "nohome")
        os.makedirs(empty, exist_ok=True)
        bm.os.path.expanduser = lambda x: x.replace("~", empty, 1) if x.startswith("~") else real(x)

    def _patch(self, name, fn):
        """打补丁并登记，tearDown 统一恢复。"""
        if not hasattr(self, "_patched"):
            self._patched = []
        if not any(n == name for n, _ in self._patched):
            self._patched.append((name, getattr(self.b, name)))
        setattr(self.b, name, fn)

    def tearDown(self):  # noqa: F811
        import tokentracker.billing as bm
        for name, val in self._restore:
            if name == "_expanduser":
                bm.os.path.expanduser = val
            else:
                setattr(self.b, name, val)
        for name, val in getattr(self, "_patched", []):
            setattr(self.b, name, val)

    # ---- Codex wham/usage ----
    def test_codex_wham_window_mapping(self):
        b = self.b
        payload = {"plan_type": "plus",
                   "rate_limit": {"primary_window": {"used_percent": 67,
                                                     "limit_window_seconds": 18000,
                                                     "reset_at": 1787812845},
                                  "secondary_window": {"used_percent": 42,
                                                       "limit_window_seconds": 604800,
                                                       "reset_at": 1788338599}},
                   "credits": {"balance": "0", "unlimited": False}}
        self._patch("_codex_credentials", lambda: ({"access_token": "t", "account_id": "a"}, None))
        self._patch("_http_json", lambda *a, **k: (200, payload))
        r = b._codex_usage_wham()
        self.assertEqual(r["_via"], "wham")
        self.assertEqual(r["windows"]["5h"]["pct"], 67.0)
        self.assertEqual(r["windows"]["7d"]["resets_at"], 1788338599000)
        self.assertEqual(r["plan"], "plus")

    def test_codex_falls_back_to_rpc(self):
        b = self.b
        self._patch("_codex_usage_wham", lambda: {"error": "http_401", "detail": "x"})
        self._patch("_codex_usage_rpc",
                    lambda: {"windows": {"7d": {"pct": 1.0}}, "plan": "plus", "_via": "rpc"})
        r = b.codex_usage()
        self.assertEqual(r["_via"], "rpc")
        # 两条都挂时报主路错误并附兑底原因
        self._patch("_codex_usage_rpc", lambda: {"error": "rpc_failed", "detail": "y"})
        r = b.codex_usage()
        self.assertEqual(r["error"], "http_401")
        self.assertIn("y", r["detail"])

    # ---- Claude 桌面采样 ----
    def test_desktop_sample_fresh_and_stale(self):
        b = self.b
        import time as _t
        import tokentracker.billing as bm
        home = os.path.join(_TMP, "fakehome")
        lib = os.path.join(home, "Library", "Application Support", "Claude")
        os.makedirs(lib, exist_ok=True)
        real = bm.os.path.expanduser
        bm.os.path.expanduser = lambda x: x.replace("~", home, 1) if x.startswith("~") else real(x)
        try:
            p = os.path.join(lib, "plan-usage-history.json")
            with open(p, "w", encoding="utf-8") as f:
                json.dump({"samples": [{"t": int(_t.time() * 1000) - 60_000,
                                        "u": {"fh": 22, "sd": 64}}]}, f)
            r = b._claude_desktop_usage()
            self.assertEqual(r["_via"], "desktop")
            self.assertEqual(r["windows"]["5h"]["pct"], 22.0)
            # 31 分钟前的样本 → 失效
            with open(p, "w", encoding="utf-8") as f:
                json.dump({"samples": [{"t": int(_t.time() * 1000) - 31 * 60_000,
                                        "u": {"fh": 22, "sd": 64}}]}, f)
            self.assertIsNone(b._claude_desktop_usage())
        finally:
            bm.os.path.expanduser = real

    # ---- Claude 凭据快照与空壳过滤 ----
    def test_snap_save_and_blank_filtered(self):
        b = self.b
        # 空壳（官方 bug 清空的条目）不应进入候选；文件/快照均为空（~ 已隔离）
        self._patch("_kc_read", lambda: {"claudeAiOauth": {"accessToken": "",
                                                           "refreshToken": "", "expiresAt": 0}})
        self.assertEqual(b._claude_credentials(), [])
        # 快照写入/读取回环
        b._claude_snap_save({"accessToken": "a", "refreshToken": "r", "expiresAt": 1})
        snap = b._claude_snap_load()
        self.assertEqual(snap["refreshToken"], "r")
        # 无 refreshToken 不快照
        os.remove(b._claude_snap_path())
        b._claude_snap_save({"accessToken": "a"})
        self.assertIsNone(b._claude_snap_load())

    def test_claude_failover_to_snapshot(self):
        """主凭据刷新失败时，自动换快照源并成功。"""
        b = self.b
        b._claude_snap_save({"accessToken": "good-tok", "refreshToken": "good-rt",
                             "expiresAt": 9_999_999_999_999, "subscriptionType": "pro"})
        self._patch("_kc_read", lambda: {"claudeAiOauth": {"accessToken": "",
                                                           "refreshToken": "bad-rt",
                                                           "expiresAt": 9_999_999_999_999}})
        self._patch("_claude_refresh",
                    lambda rt: (_ for _ in ()).throw(RuntimeError("HTTP 400")))
        self._patch("_claude_refresh_cli",
                    lambda rt: (_ for _ in ()).throw(RuntimeError("nope")))
        calls = []
        self._patch("_claude_usage_http",
                    lambda tok: (calls.append(tok),
                                 (200, {"five_hour": {"utilization": 42,
                                                      "resets_at": None}}))[1])
        r = b.claude_oauth_usage()
        self.assertEqual(r["windows"]["5h"]["pct"], 42)
        self.assertEqual(calls, ["good-tok"])  # 坏源刷新失败后换快照源成功


if __name__ == "__main__":
    unittest.main()
