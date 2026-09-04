"""GitHub Releases 更新检查：缓存 24h，网络失败静默，绝不阻塞启动。

主动联网只发生在桌面 App 的后台线程（启动后延迟 30s）；
HTTP API 只读缓存文件（/api/version 不触发网络请求）。
"""
from __future__ import annotations

import json
import os
import time
import urllib.request

from . import __version__

REPO = "fengfe1125/tokentracker"
CACHE_TTL = 24 * 3600


def cache_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "update_check.json")


def parse_version(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in (v or "").lstrip("v").split(".") if x.isdigit())


def read_cache() -> dict | None:
    try:
        with open(cache_path(), encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) and d.get("latest") else None
    except (OSError, ValueError):
        return None


def _write_cache(d: dict) -> None:
    try:
        os.makedirs(os.path.dirname(cache_path()), exist_ok=True)
        with open(cache_path(), "w", encoding="utf-8") as f:
            json.dump(d, f)
    except OSError:
        pass


def check(force: bool = False, fetch=None) -> dict | None:
    """返回 {"latest","url","checked_at"} 或 None（离线/无 release）。"""
    cached = read_cache()
    if not force and cached and time.time() - cached.get("checked_at", 0) < CACHE_TTL:
        return cached
    fetch = fetch or urllib.request.urlopen
    try:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{REPO}/releases/latest",
            headers={"User-Agent": "TokenTracker-update-check"})
        with fetch(req, timeout=5) as r:
            d = json.loads(r.read().decode("utf-8"))
        info = {"latest": d.get("tag_name") or "", "url": d.get("html_url") or "",
                "checked_at": time.time()}
        _write_cache(info)
        return info
    except Exception:
        return cached   # 失败静默：用过期缓存或 None


def update_available(info: dict | None) -> bool:
    if not info or not info.get("latest"):
        return False
    return parse_version(info["latest"]) > parse_version(__version__)
