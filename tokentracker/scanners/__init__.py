"""扫描器注册与调度。每个扫描器模块提供：

    NAME    工具名
    detect() -> bool            数据源是否存在
    scan(conn, prices, cursor, full) -> {"added", "updated", "files", "error"}
"""
from __future__ import annotations

import importlib

ALL = ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"]


def load(name: str):
    return importlib.import_module(f"tokentracker.scanners.{name}")


def detect_all() -> dict:
    out = {}
    for name in ALL:
        try:
            mod = load(name)
            out[name] = {
                "installed": bool(mod.detect()),
                "detail": getattr(mod, "DETAIL", ""),
            }
        except Exception as e:  # noqa: BLE001
            out[name] = {"installed": False, "detail": f"模块异常: {e}"}
    return out


def run_all(conn, prices, tools=None, full: bool = False) -> dict:
    """返回 {tool: 统计}。单个扫描器出错不影响其他工具。"""
    results = {}
    for name in ALL if not tools else tools:
        try:
            mod = load(name)
            if not mod.detect():
                results[name] = {"skipped": "未检测到数据源", "added": 0, "updated": 0, "files": 0}
                continue
            results[name] = mod.scan(conn, prices, full=full)
        except Exception as e:  # noqa: BLE001
            results[name] = {"error": str(e), "added": 0, "updated": 0, "files": 0}
    conn.commit()
    return results