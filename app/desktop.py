#!/usr/bin/env python3
"""TokenTracker 桌面应用：macOS 状态栏常驻 + 白色简洁主面板（按需唤出）。

入口：python3 app/desktop.py   （或打包后的 TokenTracker.app）
依赖：pywebview（macOS 使用系统 WKWebView，无额外二进制）

形态：
- 启动后只在屏幕顶部系统状态栏放一个常驻图标（⚡ 今日用量），无 Dock 图标；
- 状态栏菜单：今日统计 / 配额概览 / 打开主面板 / 立即扫描 / 退出；
- 主面板是原生 macOS 窗口（红绿灯 + 原生阴影，标题文字隐藏、内容一体化），
  关闭（红灯/⌘W）只隐藏不退出，从状态栏随时唤回。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading

# 仓库根加入 sys.path（PyInstaller 打包后自动在 _MEIPASS，无需此步）
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import webview  # noqa: E402

from app import loginitem  # noqa: E402
from app.menubar import install_menubar  # noqa: E402
from tokentracker import prefs, resume, server  # noqa: E402

MAIN_W, MAIN_H = 1180, 780


class Api:
    """暴露给主窗口的 JS 桥接（window.pywebview.api.*）。"""

    def __init__(self):
        self.main = None
        self.menubar = None
        self.quitting = False

    # ------------------------------------------------------------ 窗口 ----
    def get_main_pos(self):
        if self.main:
            return [self.main.x, self.main.y]
        return [0, 0]

    def move_main(self, x: int, y: int):
        if self.main:
            try:
                self.main.move(int(x), int(y))
            except Exception:
                pass

    def minimize_main(self):
        if self.main:
            self.main.minimize()

    def hide_main(self):
        """关闭主面板：只隐藏，进程留在状态栏。"""
        if self.menubar:
            self.menubar.tt_hide_main()
        elif self.main:
            try:
                self.main.hide()
            except Exception:
                pass

    def show_main(self):
        if self.menubar:
            self.menubar.tt_show_main()
        elif self.main:
            try:
                self.main.show()
            except Exception:
                pass

    def open_settings(self):
        """唤出主面板并切到设置视图（状态栏菜单「设置…」）。"""
        self.show_main()

        def _eval():
            if self.main:
                try:
                    self.main.evaluate_js(
                        "typeof switchView==='function'&&switchView('settings')")
                except Exception:
                    pass

        # evaluate_js 在 macOS 上会派发到主线程并同步等待结果；
        # 菜单动作本身就在主线程，直接调用会死锁（主线程等主线程）。
        threading.Thread(target=_eval, daemon=True).start()

    def launch_at_login_supported(self) -> bool:
        return loginitem.supported()

    def open_menubar_settings(self) -> bool:
        """macOS 26 Tahoe：状态栏图标需系统设置 → 菜单栏 里手动允许（StatusKit 门控）。"""
        try:
            subprocess.Popen(["open",
                              "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"])
            return True
        except Exception:
            return False

    def open_data_folder(self) -> bool:
        """在 Finder 打开本地数据目录（不存在则先创建）。"""
        path = os.path.join(os.path.expanduser("~"), ".tokentracker")
        try:
            os.makedirs(path, exist_ok=True)
        except OSError:
            pass
        return self.open_in_finder(path)

    # ------------------------------------------------------------ 继续会话 ----
    def resume_session(self, tool: str, session_id: str,
                       project: str = "", cwd: str = "") -> dict:
        """在终端恢复会话；终端打不开时自动复制命令到剪贴板兜底。"""
        cmd, reason = resume.shell_line(tool, session_id or "", project or "",
                                        cwd_override=cwd or None)
        if cmd is None:
            return {"ok": False, "copied": False, "reason": reason, "command": ""}
        term = prefs.load_prefs().get("terminal_app", "auto")
        if resume.open_terminal(cmd, term):
            return {"ok": True, "copied": False, "reason": "", "command": cmd}
        copied = resume.copy_to_clipboard(cmd)
        return {"ok": False, "copied": copied, "command": cmd,
                "reason": "终端打开失败" + ("，命令已复制到剪贴板" if copied else "")}

    def copy_resume_command(self, tool: str, session_id: str, project: str = "") -> str:
        cmd, _ = resume.shell_line(tool, session_id or "", project or "")
        if cmd:
            resume.copy_to_clipboard(cmd)
        return cmd or ""

    def pick_resume_directory(self) -> str:
        """项目目录已移动/改名时，原生面板改选工作目录。"""
        if not self.main:
            return ""
        try:
            result = self.main.create_file_dialog(webview.FOLDER_DIALOG)
            return result[0] if result else ""
        except Exception:
            return ""

    def open_in_finder(self, path: str) -> bool:
        """在 Finder 中打开目录。claude 的 project 是 slug（/→-），尝试还原。"""
        cands = []
        if isinstance(path, str):
            if path.startswith("/"):
                cands.append(path)
            elif path.startswith("-"):
                cands.append("/" + path[1:].replace("-", "/"))
        for p in cands:
            try:
                if os.path.exists(p):
                    subprocess.Popen(["open", p])
                    return True
            except Exception:
                pass
        return False

    def quit(self):
        self.quitting = True          # 让 closing 拦截器放行，真正退出
        server.stop()
        try:
            webview.destroy()
        except Exception:
            os._exit(0)


def main():
    url = server.serve(8765, auto_scan=os.environ.get("TOKENTRACKER_NO_AUTOSCAN") != "1")

    api = Api()
    api.main = webview.create_window(
        "TokenTracker",
        url + "/app/index.html",
        width=MAIN_W, height=MAIN_H,
        js_api=api, min_size=(960, 640),
    )

    def _on_closing():
        """红灯/⌘W：菜单栏应用只隐藏不退出；状态栏「退出」时才真正关闭。"""
        if api.quitting:
            return True
        api.hide_main()
        return False

    api.main.events.closing += _on_closing

    def _style_native_window():
        """原生红绿灯 + 隐藏标题文字 + 内容延伸到标题栏（简洁一体化）。"""
        import time as _time
        from AppKit import (NSApp, NSWindowStyleMaskFullSizeContentView,
                            NSWindowTitleHidden)
        from PyObjCTools import AppHelper
        win = None
        for _ in range(20):
            for w in NSApp.windows():
                try:
                    if w.title() == "TokenTracker":
                        win = w
                        break
                except Exception:
                    pass
            if win:
                break
            _time.sleep(0.25)
        if not win:
            return

        def _apply():
            try:
                win.setTitlebarAppearsTransparent_(True)
                win.setTitleVisibility_(NSWindowTitleHidden)
                win.setStyleMask_(win.styleMask() | NSWindowStyleMaskFullSizeContentView)
            except Exception:
                pass
        AppHelper.callAfter(_apply)

    def _after_start():
        # 事件循环已就绪：原生窗口修饰 + 状态栏图标；扫描由Python服务定时执行。
        _style_native_window()
        api.menubar = install_menubar(api, url)
        if os.environ.get("TT_SELFCHECK") == "1":
            threading.Thread(target=_selfcheck, daemon=True).start()

    def _selfcheck():
        """开发自检：抓取主窗口渲染状态与状态栏状态写入 /tmp/tt_selfcheck.json。"""
        import time
        time.sleep(9)
        out = {}
        try:
            js = (
                "JSON.stringify({errs: window.__errs || [], "
                "bodyLen: document.body ? document.body.innerText.length : -1, "
                "cards: document.querySelector('#statCards') ? "
                "document.querySelector('#statCards').childElementCount : -1, "
                "quota: document.querySelector('#quotaList') ? "
                "document.querySelector('#quotaList').childElementCount : -1, "
                "models: document.querySelector('#modelList') ? "
                "document.querySelector('#modelList').childElementCount : -1, "
                "sides: document.querySelector('#sideTools') ? "
                "document.querySelector('#sideTools').childElementCount : -1})"
            )
            out["main"] = json.loads(api.main.evaluate_js(js))
        except Exception as e:  # noqa: BLE001
            out["main"] = {"error": str(e)}
        try:
            out["menubar"] = api.menubar.tt_debug_state() if api.menubar else None
        except Exception as e:  # noqa: BLE001
            out["menubar"] = {"error": str(e)}
        try:
            with open("/tmp/tt_selfcheck.json", "w", encoding="utf-8") as f:
                json.dump(out, f, ensure_ascii=False, indent=1)
        except OSError:
            pass
        if os.environ.get("TT_QUIT_AFTER") == "1":
            api.quit()   # 验证退出路径（穿过 closing 拦截器）

    try:
        webview.start(func=_after_start)  # 阻塞事件循环
    finally:
        server.stop(url)


if __name__ == "__main__":
    main()
