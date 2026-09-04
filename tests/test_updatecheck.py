"""更新检查：缓存、版本比较、离线静默。"""
import json
import os
import tempfile
import unittest
from unittest.mock import patch

from tokentracker import updatecheck


class FakeResp:
    def __init__(self, payload):
        self.payload = payload
    def read(self):
        return json.dumps(self.payload).encode()
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False


class UpdateCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(patch.stopall)
        patch.object(updatecheck, "cache_path",
                     return_value=os.path.join(self.tmp.name, "update_check.json")).start()

    def test_parse_and_compare(self):
        self.assertEqual(updatecheck.parse_version("v0.2.1"), (0, 2, 1))
        self.assertTrue(updatecheck.update_available({"latest": "v99.0.0"}))
        self.assertFalse(updatecheck.update_available({"latest": "v0.0.1"}))
        self.assertFalse(updatecheck.update_available(None))
        self.assertFalse(updatecheck.update_available({"latest": ""}))

    def test_check_caches_release(self):
        info = updatecheck.check(force=True, fetch=lambda *a, **k: FakeResp(
            {"tag_name": "v9.9.9", "html_url": "https://example.com/r"}))
        self.assertEqual(info["latest"], "v9.9.9")
        # 缓存命中：fetch 抛错也返回缓存
        cached = updatecheck.check(fetch=lambda *a, **k: (_ for _ in ()).throw(OSError()))
        self.assertEqual(cached["latest"], "v9.9.9")

    def test_offline_silent(self):
        self.assertIsNone(updatecheck.check(force=True, fetch=lambda *a, **k: (_ for _ in ()).throw(OSError())))


if __name__ == "__main__":
    unittest.main()
