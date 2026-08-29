"""macOS 顶部状态栏（NSStatusItem）：常驻显示今日用量 + 订阅配额，点击展开菜单。

- 标题：分段着色富文本 `⚡(品牌橙) 12.30M(主色) · C 45%(按紧急度绿/琥珀/红)`；
  紧凑模式去掉所有空格（刘海屏防挤出）；扫描中显示旋转盲文指示
- 动画：扫描旋转 / 数值刷新闪光 / 配额 ≥80% 红色低幅脉冲；
  系统「减少动态效果」开启时全部降级为静态
- 菜单：今日统计 / 配额行（工具色圆点 + 紧急度着色）/「状态栏显示」二级菜单
  （radio + 圆点图标 + 当前标题预览）/ 打开主面板 / 设置… / 立即扫描 / 退出
- 自愈：图标被 macOS 隐藏（菜单栏溢出等）且 10s 不恢复 → 强制重排，
  再不行销毁重建（重新注册必然触发系统重新布局）；失败 30s 退避。
  事件写入 ~/.tokentracker/app.log。
- 后台线程每 5s 轮询扫描状态、每 60s 拉取统计与配额；
  所有 AppKit 调用经 AppHelper.callAfter 切回主线程（pywebview 的 NSApp 事件循环）。

注意：NSObject 子类里的方法名会被 PyObjC 与既有 ObjC 选择器做原型校验
（`install`、`_setup` 这类常见名会直接抛 BadPrototypeError），
所以本类的内部方法一律 tt_ 前缀，ObjC 动作方法用 tt 前缀的驼峰。
"""
from __future__ import annotations

import json
import os
import threading
import time
import urllib.request

from Foundation import NSMakeRect, NSMakeSize  # noqa: F401
from AppKit import (  # noqa: F401  (pyobjc 由 pywebview 依赖带入)
    NSApp, NSAttributedString, NSBezierPath, NSColor,
    NSForegroundColorAttributeName, NSImage, NSMenu, NSMenuItem,
    NSMutableAttributedString, NSObject, NSStatusBar, NSTimer, NSWorkspace,
    NSApplicationActivationPolicyAccessory,
    NSApplicationActivationPolicyRegular,
    NSVariableStatusItemLength,
)
from PyObjCTools import AppHelper

from app import loginitem  # noqa: E402
from app.menubar_fmt import (  # noqa: E402
    CRIT_PCT, FLASH_DUR, TOOL_HEX, best_window, fmt_quota, fmt_segments, fmt_title,
    fmt_tokens, hex_rgb, load_prefs, pulse_alpha, quota_line_segments,
    save_prefs, spinner_frame, flash_alpha, today_line_segments,
)

REFRESH_DATA = 60.0     # 统计/配额刷新间隔
POLL = 5.0              # 扫描状态轮询间隔
ANIM = 0.12             # 动画帧间隔
MAX_QUOTA_LINES = 4     # 菜单里最多展示的配额行数
HEAL_DELAY = 10.0       # 图标不可见多久后触发自愈
HEAL_BACKOFF = 30.0     # 自愈失败后的重试退避
NUDGE_INTERVAL = 60.0   # 无条件重排轻推间隔（治 isVisible 探测不到的卡隐藏）
_ACCENT = hex_rgb("#d97757")   # 品牌橙


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
        # 动画状态
        self.tt_anim_timer = None
        self.tt_flash_start = None     # 数值刷新闪光起点（time.time）
        self.tt_scan_started = None    # 本轮扫描开始时间（旋转指示计帧）
        self.tt_last_plain = None      # 已写入 button 的纯文本（跳过重复赋值）
        self.tt_last_anim = None       # 已写入的动画帧 key
        # 自愈状态
        self.tt_invisible_since = None
        self.tt_heal_level = 0         # 0 = 未自愈过（先重排），1 = 重排无效（重建）
        self.tt_last_heal = 0.0
        self.tt_last_nudge = 0.0
        # 状态栏标题里显示哪个平台的配额（"off" = 仅今日用量），持久化到 settings.json
        self.tt_prefs = load_prefs()
        self.tt_provider = self.tt_prefs.get("menubar_provider", "claude")
        self.tt_compact = bool(self.tt_prefs.get("menubar_compact"))
        self.tt_yi = bool(self.tt_prefs.get("unit_yi"))
        self.tt_login_applied = loginitem.is_enabled()

    # --------------------------------------------------------- 颜色 ----
    def tt_color(self, role: str):
        """段落 role → NSColor（语义色自适应明暗模式）。纯数据在 menubar_fmt。"""
        if role == "bolt":
            return NSColor.colorWithCalibratedRed_green_blue_alpha_(*_ACCENT, 1.0)
        if role == "tokens" or role == "ink":
            return NSColor.labelColor()
        if role in ("dim", "glyph", "cost"):
            return NSColor.secondaryLabelColor()
        if role == "marker":
            return NSColor.tertiaryLabelColor()
        if role == "quota_ok":
            return NSColor.systemGreenColor()
        if role == "quota_warn":
            return NSColor.systemOrangeColor()
        if role == "quota_crit":
            return NSColor.systemRedColor()
        if role.startswith("dot_"):
            rgb = TOOL_HEX.get(role[4:])
            if rgb:
                return NSColor.colorWithCalibratedRed_green_blue_alpha_(*hex_rgb(rgb), 1.0)
            return NSColor.tertiaryLabelColor()   # 未知名（如 off）→ 灰点
        return NSColor.labelColor()

    def tt_attr(self, parts) -> "NSMutableAttributedString":
        """[(文本, NSColor)] → 富文本串。"""
        attr = NSMutableAttributedString.alloc().init()
        for text, color in parts:
            attr.appendAttributedString_(NSAttributedString.alloc().initWithString_attributes_(
                text, {NSForegroundColorAttributeName: color}))
        return attr

    def tt_set_attributed(self, item, segments) -> None:
        item.setAttributedTitle_(self.tt_attr(
            [(text, self.tt_color(role)) for text, role in segments]))

    def tt_dot_image(self, role: str):
        """菜单项用的工具色圆点图标（10pt，非模板色）。"""
        img = NSImage.alloc().initWithSize_(NSMakeSize(12, 12))
        img.lockFocus()
        self.tt_color(role).set()
        NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(2.5, 2.5, 7, 7)).fill()
        img.unlockFocus()
        img.setTemplate_(False)
        return img

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
        self.tt_add_action(menu, "设置…", "ttOpenSettings:", key=",")
        self.tt_add_action(menu, "立即扫描", "ttRescan:")
        menu.addItem_(NSMenuItem.separatorItem())
        self.tt_add_action(menu, "退出 TokenTracker", "ttQuitApp:", key="q")
        self.tt_status.setMenu_(menu)

    def tt_add_action(self, menu, title, action, key=""):
        it = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, key)
        it.setTarget_(self)
        menu.addItem_(it)
        return it

    # --------------------------------------------------------- 标题渲染 ----
    def tt_render(self, spin_i=None, flash=None, pulse=None):
        """渲染状态栏标题。动画参数为 None 时用静态值（闪烁/脉冲关闭）。

        macOS 26 Tahoe 缺陷：重复设置相同 attributedTitle 会导致图标消失，
        因此只在内容或动画值变化时才写 button（纯文本与富文本都跳过重复赋值）。
        """
        if not self.tt_status:
            return
        btn = self.tt_status.button()
        if self.tt_scanning:
            frame = spinner_frame(spin_i) if spin_i is not None else "⟳"
            plain = f"{frame} 扫描中…"
            key = (plain, None, None, spin_i)
            if key != self.tt_last_anim:
                self.tt_last_anim = key
                self.tt_last_plain = None
                btn.setTitle_(plain)
                btn.setAttributedTitle_(self.tt_attr(
                    [(plain, self.tt_color("dim"))]))
            return
        segs = fmt_segments(self.tt_info.get("today"), self.tt_info.get("entries"),
                            self.tt_provider, self.tt_compact, self.tt_yi)
        plain = "".join(text for text, _ in segs)
        parts = []
        for text, role in segs:
            color = self.tt_color(role)
            if role == "tokens" and flash is not None:
                # 闪光：品牌橙 → 主色
                color = self.tt_color("bolt").blendedColorWithFraction_ofColor_(flash, color)
            elif role == "quota_crit" and pulse is not None:
                color = color.colorWithAlphaComponent_(pulse)
            parts.append((text, color))
        key = (plain, flash, pulse, None)
        if plain != self.tt_last_plain:
            self.tt_last_plain = plain
            # NSVariableStatusItemLength 只按 setTitle_ 的纯文本测量宽度，
            # 只设 attributedTitle 会让项宽为 0 → 图标彻底不显示；两者必须同时设。
            btn.setTitle_(plain)
        if key != self.tt_last_anim:
            self.tt_last_anim = key
            btn.setAttributedTitle_(self.tt_attr(parts))

    def tt_apply_title(self):
        self.tt_render()

    # --------------------------------------------------------- 动画 ----
    def tt_reduce_motion(self) -> bool:
        """系统「减少动态效果」：所有动画降级为静态。"""
        try:
            return bool(NSWorkspace.sharedWorkspace()
                        .accessibilityDisplayShouldReduceMotion())
        except Exception:
            return False

    def tt_flash_window(self):
        """闪光进度 0..1；已结束返回 None 并清状态。"""
        if self.tt_flash_start is None:
            return None
        elapsed = time.time() - self.tt_flash_start
        if elapsed >= FLASH_DUR:
            self.tt_flash_start = None
            return None
        return flash_alpha(elapsed)

    def tt_pulse_active(self) -> bool:
        """选中平台最紧窗口 ≥ CRIT_PCT 时脉冲。"""
        entries = self.tt_info.get("entries") or []
        entry = next((e for e in entries if e.get("id") == self.tt_provider), None)
        best = best_window(entry)
        return best is not None and (best.get("pct") or 0) >= CRIT_PCT

    def tt_sync_anim(self):
        """按需启停动画计时器（空闲零开销）。"""
        if not self.tt_status or self.tt_reduce_motion():
            self.tt_stop_anim()
            return
        want = (self.tt_scanning or self.tt_flash_start is not None
                or self.tt_pulse_active())
        if want and self.tt_anim_timer is None:
            self.tt_anim_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                ANIM, self, "ttAnimTick:", None, True)
        elif not want:
            self.tt_stop_anim()

    def tt_stop_anim(self):
        if self.tt_anim_timer is not None:
            try:
                self.tt_anim_timer.invalidate()
            except Exception:
                pass
            self.tt_anim_timer = None

    def ttAnimTick_(self, timer):
        spin = None
        if self.tt_scanning:
            origin = self.tt_scan_started or time.time()
            spin = int((time.time() - origin) / ANIM)
        flash = self.tt_flash_window()
        pulse = pulse_alpha(time.time()) if self.tt_pulse_active() else None
        if not (self.tt_scanning or flash is not None or pulse is not None):
            self.tt_stop_anim()
        self.tt_render(spin, flash, pulse)

    # --------------------------------------------------------- 自愈 ----
    def tt_log(self, msg: str):
        try:
            path = os.path.join(os.path.expanduser("~"), ".tokentracker", "app.log")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
        except OSError:
            pass

    def tt_check_visibility(self):
        """图标被系统隐藏 → 延迟后自愈（先强制重排，再销毁重建），失败退避。"""
        if not self.tt_status:
            return
        try:
            visible = bool(self.tt_status.isVisible())
        except Exception:
            return
        now = time.time()
        if visible:
            if self.tt_invisible_since is not None:
                self.tt_log("状态栏图标恢复可见")
            self.tt_invisible_since = None
            self.tt_heal_level = 0
            return
        if self.tt_invisible_since is None:
            self.tt_invisible_since = now
            self.tt_log("状态栏图标不可见，观察中")
            return
        if (now - self.tt_invisible_since < HEAL_DELAY
                or now - self.tt_last_heal < HEAL_BACKOFF):
            return
        self.tt_last_heal = now
        if self.tt_heal_level == 0:
            self.tt_log("自愈：强制重排状态栏项")
            try:
                self.tt_status.setVisible_(False)
                self.tt_status.setVisible_(True)
            except Exception:
                pass
            self.tt_heal_level = 1
        else:
            self.tt_log("自愈：重建状态栏项")
            self.tt_recreate_status_item()
            self.tt_heal_level = 0

    def tt_recreate_status_item(self):
        """销毁并重建状态栏项（重新注册触发系统重新布局）。"""
        old = self.tt_status
        self.tt_status = None
        if old is not None:
            try:
                old.setVisible_(False)
            except Exception:
                pass
        self.tt_install_ui()
        self.tt_last_plain = None
        self.tt_last_anim = None
        self.tt_render()

    def tt_nudge(self):
        """无条件重排轻推：刘海溢出导致的卡隐藏无法经 isVisible 探测（实测返回 True），
        周期性 setVisible 翻转强制系统重新布局；同 runloop 内完成，无可见闪烁。"""
        if not self.tt_status:
            return
        try:
            self.tt_status.setVisible_(False)
            self.tt_status.setVisible_(True)
        except Exception:
            pass

    def tt_tick_main(self):
        """轮询线程每 5s 汇总到主线程的一件事：渲染 / 动画启停 / 自愈检查 / 周期轻推。"""
        if self.tt_anim_timer is None:
            self.tt_render()      # 动画运行中由计时器负责渲染，避免抢帧
        self.tt_sync_anim()
        self.tt_check_visibility()
        now = time.time()
        if now - self.tt_last_nudge >= NUDGE_INTERVAL:
            self.tt_last_nudge = now
            self.tt_nudge()

    # ------------------------------------------------------- 菜单动作（ObjC）----
    def ttOpenMain_(self, sender):
        self.tt_show_main()

    def ttOpenSettings_(self, sender):
        api = self.tt_api
        if hasattr(api, "open_settings"):
            api.open_settings()
        else:
            self.tt_show_main()

    def tt_pick_provider(self, pid):
        if not pid or pid == self.tt_provider:
            return
        self.tt_provider = pid
        prefs = load_prefs()
        prefs["menubar_provider"] = pid
        save_prefs(prefs)
        self.tt_apply_title()

    def tt_reload_prefs(self):
        """设置页（/api/settings）写入后热生效：标题平台、紧凑模式、开机自启。"""
        prefs = load_prefs()
        if prefs == self.tt_prefs:
            return
        self.tt_prefs = prefs
        self.tt_provider = prefs.get("menubar_provider", "claude")
        self.tt_compact = bool(prefs.get("menubar_compact"))
        self.tt_yi = bool(prefs.get("unit_yi"))
        want_login = bool(prefs.get("launch_at_login"))
        if want_login != self.tt_login_applied and loginitem.set_enabled(want_login):
            self.tt_login_applied = want_login
        AppHelper.callAfter(self.tt_apply_title)

    def ttPickProvider_(self, sender):
        self.tt_pick_provider(str(sender.representedObject() or ""))

    def ttQuitApp_(self, sender):
        self.tt_api.quit()

    def menuNeedsUpdate_(self, menu):
        self.tt_set_attributed(self.tt_mi_today,
                               today_line_segments(self.tt_info.get("today"), self.tt_yi))
        entries = (self.tt_info.get("entries") or [])[:MAX_QUOTA_LINES]
        for i, it in enumerate(self.tt_mi_quota):
            if i < len(entries):
                self.tt_set_attributed(it, quota_line_segments(entries[i]))
                it.setHidden_(False)
            else:
                it.setHidden_(True)
        self.tt_rebuild_display_menu()

    def tt_rebuild_display_menu(self):
        """按 /api/quotas 的 entries 重建「状态栏显示」子菜单（radio 勾选当前项）。"""
        entries = self.tt_info.get("entries") or []
        sub = NSMenu.alloc().init()
        preview = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "当前：" + fmt_title(self.tt_info.get("today"), entries,
                                self.tt_provider, self.tt_compact, self.tt_yi), None, "")
        preview.setEnabled_(False)
        sub.addItem_(preview)
        sub.addItem_(NSMenuItem.separatorItem())
        for e in entries:
            pid = e.get("id")
            if pid:
                self.tt_add_provider_item(sub, pid, f"今日用量 + {e.get('name', '?')}",
                                          dot=f"dot_{pid}")
        if entries:
            sub.addItem_(NSMenuItem.separatorItem())
        self.tt_add_provider_item(sub, "off", "仅今日用量", dot="dot_off")
        self.tt_mi_display.setSubmenu_(sub)

    def tt_add_provider_item(self, sub, pid, title, dot=None):
        it = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, "ttPickProvider:", "")
        it.setTarget_(self)
        it.setRepresentedObject_(pid)
        it.setState_(1 if pid == self.tt_provider else 0)
        if dot:
            it.setImage_(self.tt_dot_image(dot))
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

    def ttRescan_(self, sender):
        threading.Thread(target=self.tt_trigger_scan, daemon=True).start()

    def tt_fetch_data(self):
        try:
            stats = _get(self.tt_url + "/api/stats?range=day")
            t = stats.get("total") or {}
            tokens = t.get("tokens") or 0
            prev = (self.tt_info.get("today") or {}).get("tokens")
            if prev is not None and prev != tokens:
                self.tt_flash_start = time.time()   # 数值刷新闪光
            self.tt_info["today"] = {"tokens": tokens, "cost": t.get("cost") or 0}
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
                scanning = bool(st.get("running"))
                if scanning and not was_scanning:
                    self.tt_scan_started = time.time()
                self.tt_scanning = scanning
            except Exception:
                self.tt_scanning = False
            now = time.time()
            if now - last_data >= REFRESH_DATA or (was_scanning and not self.tt_scanning):
                self.tt_fetch_data()
                last_data = now
            was_scanning = self.tt_scanning
            self.tt_reload_prefs()      # 设置页改动 5 秒内生效
            AppHelper.callAfter(self.tt_tick_main)
            time.sleep(POLL)

    # --------------------------------------------------------- 调试 ----
    def tt_debug_state(self) -> dict:
        try:
            title = self.tt_status.button().title() if self.tt_status else None
        except Exception:
            title = None
        try:
            visible = bool(self.tt_status.isVisible()) if self.tt_status else None
        except Exception:
            visible = None
        return {"installed": self.tt_status is not None, "title": title,
                "visible": visible, "provider": self.tt_provider,
                "compact": self.tt_compact, "info": dict(self.tt_info)}


def install_menubar(api, url: str) -> MenuBar:
    """创建并安装状态栏（须在 webview.start 的 func 回调里调用）。"""
    bar = MenuBar.alloc().init()
    bar.tt_setup(api, url)
    AppHelper.callAfter(bar.tt_install_ui)
    bar.tt_log("状态栏已安装")
    threading.Thread(target=bar.tt_loop, daemon=True).start()
    return bar
