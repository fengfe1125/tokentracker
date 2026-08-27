"""Menu tests without AppKit, real preferences, or network access."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from app import menubar_fmt


def _load_menubar():
    appkit = types.ModuleType("AppKit")
    for name in ("NSApp", "NSMenu", "NSMenuItem", "NSStatusBar",
                 "NSApplicationActivationPolicyAccessory",
                 "NSApplicationActivationPolicyRegular", "NSVariableStatusItemLength"):
        setattr(appkit, name, None)
    appkit.NSObject = object
    helpers = types.ModuleType("PyObjCTools")
    helpers.AppHelper = types.SimpleNamespace(callAfter=lambda fn: fn())
    spec = importlib.util.spec_from_file_location(
        "isolated_menubar", Path(__file__).resolve().parents[1] / "app" / "menubar.py")
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {"AppKit": appkit, "PyObjCTools": helpers}):
        spec.loader.exec_module(module)
    return module


class MenuBarTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mb = _load_menubar()

    def setUp(self):
        self.bar = self.mb.MenuBar()
        self.bar.tt_url = "http://mock.invalid"
        self.bar.tt_info = {}

    def test_failed_quota_refresh_clears_previous_value_and_lines(self):
        self.bar.tt_info = {"entries": [{"id": "claude", "windows": [{
            "pct": 75, "source": "official", "stale": False}]}],
            "quotas": ["Claude 75%"]}
        with patch.object(self.mb, "_get", side_effect=[
                {"total": {"tokens": 103}}, TimeoutError("offline")]):
            self.bar.tt_fetch_data()
        self.assertFalse(self.bar.tt_info.get("entries"))
        self.assertFalse(self.bar.tt_info.get("quotas"))
        self.assertEqual(menubar_fmt.fmt_title(self.bar.tt_info["today"],
                         self.bar.tt_info.get("entries"), "claude"), "⚡ 103")

    def test_today_uses_total_tokens_including_cache(self):
        with patch.object(self.mb, "_get", side_effect=[
                {"total": {"tokens": 1000, "input": 10, "output": 20,
                           "cache_read": 900, "cache_write": 70}}, {"entries": []}]):
            self.bar.tt_fetch_data()
        self.assertEqual(self.bar.tt_info["today"]["tokens"], 1000)

    def test_title_and_menu_use_the_selected_windows_source(self):
        entry = {"id": "claude", "name": "Claude Code", "note": "arbitrary message",
                 "source": "official", "windows": [
                     {"pct": 20, "label": "5h", "source": "official", "stale": True},
                     {"pct": 45, "label": "7d", "source": "local", "stale": False}]}
        with patch.object(self.mb, "_get", side_effect=[
                {"total": {"tokens": 100}}, {"entries": [entry]}]):
            self.bar.tt_fetch_data()
        self.assertEqual(self.bar.tt_info["quotas"], ["Claude Code · 7d ≈45%"])
        self.assertEqual(menubar_fmt.fmt_title({"tokens": 100}, [entry], "claude"),
                         "⚡ 100 · C ≈45%")

    def test_preference_selection_is_saved_without_touching_real_home(self):
        with tempfile.TemporaryDirectory(prefix="tt_menu_") as temp, \
                patch.object(menubar_fmt, "prefs_path", return_value=os.path.join(temp, "settings.json")):
            self.bar.tt_provider = "claude"
            self.bar.tt_status = None
            sender = types.SimpleNamespace(representedObject=lambda: "off")
            self.bar.ttPickProvider_(sender)
            self.assertEqual(menubar_fmt.load_prefs()["menubar_provider"], "off")


class TitleSourceTest(unittest.TestCase):
    def test_source_marker_does_not_depend_on_note(self):
        for source, stale, expected in [("official", False, "45%"),
                                        ("official", True, "~45%"),
                                        ("local", False, "≈45%")]:
            for note in ("", "请先登录"):
                with self.subTest(source=source, stale=stale, note=note):
                    entry = {"id": "claude", "note": note, "windows": [{
                        "pct": 45, "source": source, "stale": stale}]}
                    self.assertEqual(menubar_fmt.fmt_title({"tokens": 100}, [entry], "claude"),
                                     "⚡ 100 · C " + expected)
