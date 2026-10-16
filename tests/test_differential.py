"""差分基建回归：语料可重复生成、Python 导出结果确定且与基线一致。"""
import json
import os
import subprocess
import unittest

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "differential")
EXPECTED = os.path.join(HERE, "expected_python.json")


class DifferentialCase(unittest.TestCase):
    def test_export_is_deterministic_and_matches_baseline(self):
        subprocess.run(["python3", os.path.join(HERE, "make_corpus.py")],
                       check=True, capture_output=True)
        outs = []
        for _ in range(2):
            proc = subprocess.run(
                ["python3", os.path.join(HERE, "export_python.py"), "-"],
                check=True, capture_output=True, text=True)
            outs.append(proc.stdout)
        self.assertEqual(outs[0], outs[1], "同一语料两次导出必须逐字节一致")
        with open(EXPECTED, encoding="utf-8") as f:
            baseline = f.read()
        self.assertEqual(outs[0], baseline,
                         "Python 导出与 expected_python.json 不一致；"
                         "若扫描器行为变更是有意的，重新运行 export_python.py 更新基线")
        data = json.loads(outs[0])
        self.assertEqual({r for r in data["scan_results"]},
                         {"claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"})
        self.assertGreaterEqual(len(data["events"]), 10)
        by_tool = {tool: [event for event in data["events"] if event["tool"] == tool]
                   for tool in data["scan_results"]}
        self.assertTrue(all(by_tool.values()), "七个扫描器都必须产出固定样例用量")
        self.assertTrue(all(event["input"] >= 0 and event["output"] >= 0
                            and event["cache_read"] >= 0 and event["cache_write"] >= 0
                            for event in data["events"]))
        opencode = next(event for event in by_tool["opencode"]
                        if event["session_id"] == "oc-sess-1")
        # tokens_reasoning 是 output 的子集；不再独立叠加。
        self.assertEqual(sum(opencode[key] for key in
                             ("input", "output", "cache_read", "cache_write")), 26_800)
        unknown = next(event for event in by_tool["pi"] if event["model"] == "unpriced-model-x")
        self.assertEqual(unknown["input"] + unknown["output"], 1_560)
        self.assertIsNone(unknown["cost"])
        self.assertIsNone(unknown["price_version_id"])


if __name__ == "__main__":
    unittest.main()
