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


if __name__ == "__main__":
    unittest.main()
