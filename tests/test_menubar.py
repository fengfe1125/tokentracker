"""Menu tests without AppKit, real preferences, or network access."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock
from unittest.mock import patch

from app import menubar_fmt


def _load_menubar():
    foundation = types.ModuleType("Foundation")
    foundation.NSMakeSize = lambda w, h: (w, h)
    foundation.NSMakeRect = lambda x, y, w, h: (x, y, w, h)
    appkit = types.ModuleType("AppKit")
    for name in ("NSApp", "NSAttributedString", "NSBezierPath", "NSColor",
                 "NSForegroundColorAttributeName", "NSImage", "NSMenu", "NSMenuItem",
                 "NSMutableAttributedString", "NSObject", "NSStatusBar", "NSTimer",
                 "NSWorkspace",
                 "NSApplicationActivationPolicyAccessory",
                 "NSApplicationActivationPolicyRegular", "NSVariableStatusItemLength"):
        setattr(appkit, name, None)
    appkit.NSObject = object
    helpers = types.ModuleType("PyObjCTools")
    helpers.AppHelper = types.SimpleNamespace(callAfter=lambda fn: fn())
    spec = importlib.util.spec_from_file_location(
        "isolated_menubar", Path(__file__).resolve().parents[1] / "app" / "menubar.py")
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {"AppKit": appkit, "Foundation": foundation,
                                  "PyObjCTools": helpers}):
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

    def test_settings_page_changes_hot_reload(self):
        self.bar.tt_prefs = {"menubar_provider": "claude"}
        self.bar.tt_provider = "claude"
        self.bar.tt_compact = False
        self.bar.tt_login_applied = False
        self.bar.tt_status = None
        self.bar.tt_scanning = False
        new_prefs = {"menubar_provider": "codex", "menubar_compact": True,
                     "launch_at_login": True}
        with patch.object(self.mb, "load_prefs", return_value=new_prefs), \
                patch.object(self.mb.loginitem, "set_enabled", return_value=True) as apply_login:
            self.bar.tt_reload_prefs()
        self.assertEqual(self.bar.tt_provider, "codex")
        self.assertTrue(self.bar.tt_compact)
        apply_login.assert_called_once_with(True)
        self.assertTrue(self.bar.tt_login_applied)

    def test_unchanged_settings_skip_reload(self):
        prefs = {"menubar_provider": "claude"}
        self.bar.tt_prefs = prefs
        with patch.object(self.mb, "load_prefs", return_value=dict(prefs)), \
                patch.object(self.mb.loginitem, "set_enabled") as apply_login:
            self.bar.tt_reload_prefs()
        apply_login.assert_not_called()


class CompactTitleTest(unittest.TestCase):
    def test_compact_title_removes_all_spaces(self):
        entry = {"id": "claude", "windows": [{"pct": 45, "source": "official",
                                              "stale": False}]}
        self.assertEqual(menubar_fmt.fmt_title({"tokens": 32522521}, [entry], "claude"),
                         "⚡ 32.52M · C 45%")
        self.assertEqual(
            menubar_fmt.fmt_title({"tokens": 32522521}, [entry], "claude", compact=True),
            "⚡32.52M·C45%")
        self.assertEqual(menubar_fmt.fmt_title(None, None, "off", compact=True), "⚡—")
        self.assertEqual(
            menubar_fmt.fmt_title({"tokens": 100}, None, "off", compact=True), "⚡100")


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


class SegmentRenderTest(unittest.TestCase):
    """分段着色与动画曲线的纯逻辑（AppKit 层只做 role→NSColor 映射）。"""

    def test_segments_join_matches_title_text(self):
        entry = {"id": "claude", "name": "Claude Code", "windows": [
            {"pct": 45, "source": "official", "stale": False}]}
        for compact in (False, True):
            with self.subTest(compact=compact):
                segs = menubar_fmt.fmt_segments({"tokens": 12300000}, [entry], "claude", compact)
                self.assertEqual("".join(t for t, _ in segs),
                                 menubar_fmt.fmt_title({"tokens": 12300000}, [entry],
                                                       "claude", compact))

    def test_roles_cover_urgency_and_markers(self):
        for pct, role in [(10, "quota_ok"), (50, "quota_warn"), (79.9, "quota_warn"),
                          (80, "quota_crit"), (100, "quota_crit")]:
            with self.subTest(pct=pct):
                entry = {"id": "claude", "windows": [{"pct": pct, "source": "official"}]}
                roles = [r for _, r in menubar_fmt.fmt_segments({"tokens": 1}, [entry], "claude")]
                self.assertEqual(roles[-1], role)
        stale = {"id": "claude", "windows": [{"pct": 45, "source": "official", "stale": True}]}
        local = {"id": "claude", "windows": [{"pct": 45, "source": "local"}]}
        self.assertIn((" ~", "marker"),
                      menubar_fmt.fmt_segments({"tokens": 1}, [stale], "claude"))
        self.assertIn((" ≈", "marker"),
                      menubar_fmt.fmt_segments({"tokens": 1}, [local], "claude"))

    def test_menu_line_segments(self):
        entry = {"id": "kimi", "name": "Kimi", "windows": [
            {"pct": 74, "label": "周 (7天)", "source": "official"}]}
        segs = menubar_fmt.quota_line_segments(entry)
        self.assertEqual("".join(t for t, _ in segs), "● Kimi · 周 (7天) 74%")
        self.assertEqual(segs[0][1], "dot_kimi")
        self.assertEqual(segs[-1][1], "quota_warn")

    def test_today_line_segments(self):
        self.assertEqual("".join(t for t, _ in menubar_fmt.today_line_segments(
            {"tokens": 1500, "cost": 2.5})), "今日 1.50K tokens · $2.50")
        self.assertEqual(menubar_fmt.today_line_segments(None),
                         [("今日暂无数据（点「立即扫描」）", "dim")])

    def test_hex_rgb(self):
        self.assertEqual(menubar_fmt.hex_rgb("#d97757"),
                         (0xD9 / 255, 0x77 / 255, 0x57 / 255))
        self.assertEqual(menubar_fmt.hex_rgb("d97757"),
                         menubar_fmt.hex_rgb("#d97757"))

    def test_animation_curves(self):
        self.assertEqual(menubar_fmt.spinner_frame(10), menubar_fmt.SPINNER[0])
        self.assertEqual(menubar_fmt.spinner_frame(3), menubar_fmt.SPINNER[3])
        self.assertEqual(menubar_fmt.flash_alpha(-1), 0.0)
        self.assertAlmostEqual(menubar_fmt.flash_alpha(0.3), 0.5)
        self.assertEqual(menubar_fmt.flash_alpha(99), 1.0)
        for t in (0, 0.5, 1.3, 2.0, 5.7):
            a = menubar_fmt.pulse_alpha(t)
            self.assertGreaterEqual(a, menubar_fmt.PULSE_MIN)
            self.assertLessEqual(a, 1.0)


class VisibilityHealTest(unittest.TestCase):
    """自愈状态机：观察 → 重排 → 退避 → 重建；恢复可见后重置。"""

    @classmethod
    def setUpClass(cls):
        cls.mb = _load_menubar()

    def _bar(self, visible):
        bar = self.mb.MenuBar()
        bar.tt_status = Mock()
        bar.tt_status.isVisible.return_value = visible
        bar.tt_install_ui = Mock()
        bar.tt_render = Mock()
        bar.tt_log = Mock()
        bar.tt_invisible_since = None
        bar.tt_heal_level = 0
        bar.tt_last_heal = 0.0
        return bar

    def test_heal_ladder_and_backoff(self):
        bar = self._bar(visible=False)
        clock = iter([100, 104, 111, 112, 142])
        with patch.object(self.mb.time, "time", side_effect=lambda: next(clock)):
            bar.tt_check_visibility()          # t=100 开始观察
            self.assertEqual(bar.tt_invisible_since, 100)
            bar.tt_check_visibility()          # t=104 未到 10s
            bar.tt_status.setVisible_.assert_not_called()
            bar.tt_check_visibility()          # t=111 首次自愈：重排
            self.assertEqual(bar.tt_status.setVisible_.call_count, 2)
            bar.tt_check_visibility()          # t=112 退避期内
            bar.tt_install_ui.assert_not_called()
            bar.tt_check_visibility()          # t=142 重排无效 → 重建
            bar.tt_install_ui.assert_called_once()

    def test_visible_resets_state(self):
        bar = self._bar(visible=False)
        clock = iter([100, 111])
        with patch.object(self.mb.time, "time", side_effect=lambda: next(clock)):
            bar.tt_check_visibility()
            bar.tt_check_visibility()
        self.assertEqual(bar.tt_heal_level, 1)
        bar.tt_status.isVisible.return_value = True
        with patch.object(self.mb.time, "time", return_value=200):
            bar.tt_check_visibility()
        self.assertIsNone(bar.tt_invisible_since)
        self.assertEqual(bar.tt_heal_level, 0)

    def test_no_status_item_is_safe(self):
        bar = self._bar(visible=False)
        bar.tt_status = None
        bar.tt_check_visibility()   # 不抛异常即可

    def test_periodic_nudge_toggles_visibility(self):
        """无条件轻推：isVisible 探测不到的卡隐藏，靠周期 setVisible 翻转恢复。"""
        bar = self._bar(visible=True)
        bar.tt_last_nudge = 0.0
        with patch.object(self.mb.time, "time", return_value=300):
            bar.tt_nudge()
        self.assertEqual(bar.tt_status.setVisible_.call_count, 2)
        self.assertEqual([c.args[0] for c in bar.tt_status.setVisible_.call_args_list],
                         [False, True])

    def test_nudge_without_item_is_safe(self):
        bar = self._bar(visible=True)
        bar.tt_status = None
        bar.tt_nudge()

    def test_module_has_json_for_get(self):
        """_get 依赖 json；重写时曾漏 import 导致轮询静默失效（回归防护）。"""
        self.assertTrue(hasattr(self.mb, "json"))

class UnitYiTest(unittest.TestCase):
    """「亿」单位开关：≥1e8 以亿显示，状态栏与界面共用同一格式化。"""

    def test_fmt_tokens_yi(self):
        self.assertEqual(menubar_fmt.fmt_tokens(5.5e8, yi=True), "5.50亿")
        self.assertEqual(menubar_fmt.fmt_tokens(1e8, yi=True), "1.00亿")
        self.assertEqual(menubar_fmt.fmt_tokens(99_999_999, yi=True), "100.00M")
        self.assertEqual(menubar_fmt.fmt_tokens(5.5e8), "550.00M")   # 关闭时保持原样

    def test_title_segments_yi(self):
        entry = {"id": "claude", "windows": [{"pct": 12, "source": "official"}]}
        segs = menubar_fmt.fmt_segments({"tokens": 550_000_000}, [entry], "claude",
                                        compact=True, yi=True)
        self.assertIn(("5.50亿", "tokens"), segs)
        self.assertEqual(menubar_fmt.fmt_title({"tokens": 550_000_000}, [entry],
                                               "claude", compact=True, yi=True),
                         "⚡5.50亿·C12%")

    def test_today_line_yi(self):
        segs = menubar_fmt.today_line_segments({"tokens": 3.3e8, "cost": 1.5}, yi=True)
        self.assertIn(("3.30亿", "tokens"), segs)
