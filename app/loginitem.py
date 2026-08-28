"""开机自动启动：macOS LaunchAgent（~/Library/LaunchAgents/com.tokentracker.login.plist）。

仅对打包后的 .app 生效（sys.frozen）；开发模式下 supported() 为 False，
设置页会禁用该开关。状态栏轮询发现设置变化后调用 set_enabled 应用。
"""
from __future__ import annotations

import os
import plistlib
import sys

LABEL = "com.tokentracker.login"


def plist_path() -> str:
    return os.path.join(os.path.expanduser("~"), "Library", "LaunchAgents",
                        LABEL + ".plist")


def supported() -> bool:
    """仅打包后的 .app 支持（此时 sys.executable 指向 .app 内的可执行文件）。"""
    return bool(getattr(sys, "frozen", False))


def is_enabled() -> bool:
    try:
        with open(plist_path(), "rb") as f:
            return plistlib.load(f).get("Label") == LABEL
    except (OSError, ValueError):
        return False


def set_enabled(flag: bool) -> bool:
    """写入/移除 LaunchAgent。返回是否成功（不支持时视为成功，无副作用）。"""
    if not supported():
        return True
    try:
        path = plist_path()
        if flag:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                plistlib.dump({
                    "Label": LABEL,
                    "ProgramArguments": [sys.executable],
                    "RunAtLoad": True,
                    "ProcessType": "Interactive",
                }, f)
        else:
            os.unlink(path)
        return True
    except OSError:
        return False
