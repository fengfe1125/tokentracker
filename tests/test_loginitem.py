"""LaunchAgent 开机自启：不触碰真实 ~/Library/LaunchAgents。"""
import os
import tempfile
import unittest
from unittest.mock import patch

from app import loginitem


class LoginItemTest(unittest.TestCase):
    def test_enable_disable_roundtrip(self):
        with tempfile.TemporaryDirectory(prefix="tt_login_") as d, \
                patch.object(loginitem, "plist_path",
                             return_value=os.path.join(d, "sub", "x.plist")), \
                patch.object(loginitem, "supported", return_value=True):
            self.assertFalse(loginitem.is_enabled())
            self.assertTrue(loginitem.set_enabled(True))
            self.assertTrue(loginitem.is_enabled())
            self.assertTrue(loginitem.set_enabled(False))
            self.assertFalse(loginitem.is_enabled())

    def test_unsupported_environment_is_a_noop(self):
        with tempfile.TemporaryDirectory(prefix="tt_login_") as d, \
                patch.object(loginitem, "plist_path",
                             return_value=os.path.join(d, "x.plist")), \
                patch.object(loginitem, "supported", return_value=False):
            self.assertTrue(loginitem.set_enabled(True))
            self.assertFalse(os.path.exists(os.path.join(d, "x.plist")))

    def test_foreign_plist_does_not_count_as_enabled(self):
        with tempfile.TemporaryDirectory(prefix="tt_login_") as d:
            path = os.path.join(d, "x.plist")
            with open(path, "w", encoding="utf-8") as f:
                f.write("not a plist")
            with patch.object(loginitem, "plist_path", return_value=path):
                self.assertFalse(loginitem.is_enabled())


if __name__ == "__main__":
    unittest.main()
