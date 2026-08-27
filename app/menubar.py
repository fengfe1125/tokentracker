"""macOS 顶部状态栏（NSStatusItem）：常驻显示今日用量 + 订阅配额，点击展开菜单。

- 标题：`⚡ <今日 tokens> · <平台 glyph><最紧窗口%>`（CodexBar Merge Icons 思路）；
  扫描中显示 `⟳ 扫描中…`
- 菜单：今日统计行 / 各订阅配额最紧的窗口 / 「状态栏显示」二级菜单（radio 切换
  显示哪个平台的配额，选择持久化到 ~/.tokentracker/settings.json）/
  打开主面板 / 立即扫描 / 退出
- 后台线程每 5s 轮询扫描状态、每 60s 拉取统计与配额；
  所有 AppKit 调用经 AppHelper.callAfter 切回主线程（pywebview 的 NSApp 事件循环）。

注意：NSObject 子类里的方法名会被 PyObjC 与既有 ObjC 选择器做原型校验
（`install`、`_setup` 这类常见名会直接抛 BadPrototypeError），
所以本类的内部方法一律 tt_ 前缀，ObjC 动作方法用 tt 前缀的驼峰。
"""
from __future__ import annotations

import json
import threading
import time
import urllib.request

from AppKit import (  # noqa: F401  (pyobjc 由 pywebview 依赖带入)
    NSApp, NSMenu, NSMenuItem, NSObject, NSStatusBar,
    NSApplicationActivationPolicyAccessory,
    NSApplicationActivationPolicyRegular,
    NSVariableStatusItemLength,
)
from PyObjCTools import AppHelper

from app.menubar_fmt import (  # noqa: E402
    DEFAULT_PROVIDER, best_window, fmt_quota, fmt_title, fmt_tokens, load_prefs, save_prefs,
)

REFRESH_DATA = 60.0   # 统计/配额刷新间隔
POLL = 5.0            # 扫描状态轮询间隔
MAX_QUOTA_LINES = 4   # 菜单里最多展示的配额行数


def _get(url: str, timeout: float = 8):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


class MenuBar(NSObject):
    """状态栏控制器。入口：install_menubar(api, server_url)。"""

    def tt_setup(self, api, url: str):
        self.tt_api = api
        self.tt_url = url
        self.tt_status = None
        self.tt_info = {}          # {"today": {...}, "quotas": [str, ...], "entries": [...]}
        self.tt_scanning = False
        # 状态栏标题里显示哪个平台的配额（"off" = 仅今日用量），持久化到 settings.json
        self.tt_provider = load_prefs().get("menubar_provider", DEFAULT_PROVIDER)

    # --------------------------------------------------------- UI（主线程）----
    def tt_install_ui(self):
        # 菜单栏应用：无 Dock 图标；打开主面板时再临时切回 Regular
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        self.tt_status = NSStatusBar.systemStatusBar().statusItemWithLength_(
            NSVariableStatusItemLength)
        self.tt_status.button().setTitle_("⚡ —")

        menu = NSMenu.alloc().init()
        menu.setDelegate_(self)

        self.tt_mi_today = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "今日暂无数据", None, "")
        self.tt_mi_today.setEnabled_(False)
        menu.addItem_(self.tt_mi_today)

        self.tt_mi_quota = []
        for _ in range(MAX_QUOTA_LINES):
            it = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("", None, "")
            it.setEnabled_(False)
            it.setHidden_(True)
            menu.addItem_(it)
            self.tt_mi_quota.append(it)

        menu.addItem_(NSMenuItem.separatorItem())
        # 「状态栏显示」二级菜单：radio 切换标题里展示的平台配额（menuNeedsUpdate 时重建）
        self.tt_mi_display = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "状态栏显示", None, "")
        self.tt_mi_display.setSubmenu_(NSMenu.alloc().init())
        menu.addItem_(self.tt_mi_display)

        menu.addItem_(NSMenuItem.separatorItem())
        self.tt_add_action(menu, "打开主面板", "ttOpenMain:")
        self.tt_add_action(menu, "立即扫描", "ttRescan:")
        menu.addItem_(NSMenuItem.separatorItem())
        self.tt_add_action(menu, "退出 TokenTracker", "ttQuitApp:", key="q")
        self.tt_status.setMenu_(menu)

    def tt_add_action(self, menu, title, action, key=""):
        it = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, key)
        it.setTarget_(self)
        menu.addItem_(it)
        return it

    def tt_apply_title(self):
        if not self.tt_status:
            return
        if self.tt_scanning:
            self.tt_status.button().setTitle_("⟳ 扫描中…")
            return
        self.tt_status.button().setTitle_(
            fmt_title(self.tt_info.get("today"),
                      self.tt_info.get("entries"), self.tt_provider))

    # ------------------------------------------------------- 菜单动作（ObjC）----
    def ttOpenMain_(self, sender):
        self.tt_show_main()

    def ttRescan_(self, sender):
        threading.Thread(target=self.tt_trigger_scan, daemon=True).start()

    def ttPickProvider_(self, sender):
        pid = str(sender.representedObject() or "")
        if not pid or pid == self.tt_provider:
            return
        self.tt_provider = pid
        prefs = load_prefs()
        prefs["menubar_provider"] = pid
        save_prefs(prefs)
        self.tt_apply_title()

    def ttQuitApp_(self, sender):
        self.tt_api.quit()

    def menuNeedsUpdate_(self, menu):
        today = self.tt_info.get("today")
        if today:
            self.tt_mi_today.setTitle_(
                f"今日 {fmt_tokens(today['tokens'])} tokens · ${today['cost']:.2f}")
        else:
            self.tt_mi_today.setTitle_("今日暂无数据（点「立即扫描」）")
        lines = self.tt_info.get("quotas") or []
        for i, it in enumerate(self.tt_mi_quota):
            if i < len(lines):
                it.setTitle_(lines[i])
                it.setHidden_(False)
            else:
                it.setHidden_(True)
        self.tt_rebuild_display_menu()

    def tt_rebuild_display_menu(self):
        """按 /api/quotas 的 entries 重建「状态栏显示」子菜单（radio 勾选当前项）。"""
        entries = self.tt_info.get("entries") or []
        sub = NSMenu.alloc().init()
        for e in entries:
            pid = e.get("id")
            if pid:
                self.tt_add_provider_item(sub, pid, f"今日用量 + {e.get('name', '?')}")
        if entries:
            sub.addItem_(NSMenuItem.separatorItem())
        self.tt_add_provider_item(sub, "off", "仅今日用量")
        self.tt_mi_display.setSubmenu_(sub)

    def tt_add_provider_item(self, sub, pid, title):
        it = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, "ttPickProvider:", "")
        it.setTarget_(self)
        it.setRepresentedObject_(pid)
        it.setState_(1 if pid == self.tt_provider else 0)
        sub.addItem_(it)

    # --------------------------------------------------------- 窗口显隐 ----
    def tt_show_main(self):
        def _():
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
            NSApp.activateIgnoringOtherApps_(True)
            w = self.tt_api.main
            if w:
                try:
                    w.restore()
                except Exception:
                    pass
                w.show()
        AppHelper.callAfter(_)

    def tt_hide_main(self):
        def _():
            w = self.tt_api.main
            if w:
                try:
                    w.hide()
                except Exception:
                    pass
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        AppHelper.callAfter(_)

    # --------------------------------------------------------- 数据线程 ----
    def tt_trigger_scan(self):
        if self.tt_scanning:
            return
        try:
            req = urllib.request.Request(
                self.tt_url + "/api/scan", data=b"{}",
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=8)
        except Exception:
            pass

    def tt_fetch_data(self):
        try:
            stats = _get(self.tt_url + "/api/stats?range=day")
            t = stats.get("total") or {}
            self.tt_info["today"] = {
                "tokens": t.get("tokens") or 0,
                "cost": t.get("cost") or 0,
            }
        except Exception:
            self.tt_info.pop("today", None)
        try:
            q = _get(self.tt_url + "/api/quotas", timeout=30)
            entries = q.get("entries") or []
            self.tt_info["entries"] = entries
            lines = []
            for e in entries:
                best = best_window(e)
                if best:
                    lines.append(f"{e.get('name', '?')} · {best.get('label', '')} "
                                 f"{fmt_quota(best)}")
            self.tt_info["quotas"] = lines[:MAX_QUOTA_LINES]
        except Exception:
            self.tt_info.pop("entries", None)
            self.tt_info.pop("quotas", None)

    def tt_loop(self):
        last_data = 0.0
        was_scanning = False
        while True:
            try:
                st = _get(self.tt_url + "/api/scan/status", timeout=4)
                self.tt_scanning = bool(st.get("running"))
            except Exception:
                self.tt_scanning = False
            now = time.time()
            if now - last_data >= REFRESH_DATA or (was_scanning and not self.tt_scanning):
                self.tt_fetch_data()
                last_data = now
            was_scanning = self.tt_scanning
            AppHelper.callAfter(self.tt_apply_title)
            time.sleep(POLL)

    # --------------------------------------------------------- 调试 ----
    def tt_debug_state(self) -> dict:
        try:
            title = self.tt_status.button().title() if self.tt_status else None
        except Exception:
            title = None
        return {"installed": self.tt_status is not None, "title": title,
                "provider": self.tt_provider, "info": dict(self.tt_info)}


def install_menubar(api, url: str) -> MenuBar:
    """创建并安装状态栏（须在 webview.start 的 func 回调里调用）。"""
    bar = MenuBar.alloc().init()
    bar.tt_setup(api, url)
    AppHelper.callAfter(bar.tt_install_ui)
    threading.Thread(target=bar.tt_loop, daemon=True).start()
    return bar
