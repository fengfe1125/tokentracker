"""应用设置（~/.tokentracker/settings.json）的读写与默认值。

CLI 服务（tokentracker.server）与桌面状态栏（app.menubar）共用此文件：
设置页写入后，状态栏轮询发现文件变化即热生效，无需重启。
"""
from __future__ import annotations

import json
import os

DEFAULTS = {
    "menubar_provider": "claude",   # 状态栏标题追加显示的平台配额；"off" = 仅今日用量
    "menubar_compact": False,       # 紧凑标题（刘海屏 / 菜单栏图标多时防被挤出）
    "launch_at_login": False,       # 开机自动启动（桌面 App 写入 LaunchAgent）
}


def prefs_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "settings.json")


def load_prefs(path: str | None = None) -> dict:
    try:
        with open(path or prefs_path(), encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_prefs(prefs: dict, path: str | None = None) -> None:
    try:
        p = path or prefs_path()
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(prefs, f)
        os.replace(tmp, p)
    except OSError:
        pass
