"""状态栏标题合成与偏好持久化。

纯 Python、无 AppKit 依赖，供 app/menubar.py 使用、tests 直接单测。
参考 CodexBar 的 Merge Icons 思路：单一状态栏图标，标题 = 今日用量 + 选中平台
最紧窗口的已用百分比（stale 官方数据加 ~ 前缀标记）。
"""
from __future__ import annotations

import json
import os

PROVIDER_GLYPH = {"claude": "C", "codex": "X", "kimi": "K", "go": "G"}
DEFAULT_PROVIDER = "claude"   # 默认：今日用量 + Claude Code 配额；"off" = 仅今日用量


def fmt_tokens(n) -> str:
    n = float(n or 0)
    if n >= 1e9:
        return f"{n / 1e9:.2f}B"
    if n >= 1e6:
        return f"{n / 1e6:.2f}M"
    if n >= 1e4:
        return f"{n / 1e3:.1f}K"
    if n >= 1e3:
        return f"{n / 1e3:.2f}K"
    return str(int(n))


def best_window(entry: dict) -> dict | None:
    """entry 里 pct 最高的窗口（最紧的那个）。"""
    best = None
    for w in (entry or {}).get("windows") or []:
        if w.get("pct") is None:
            continue
        if best is None or w["pct"] > best["pct"]:
            best = w
    return best


def fmt_title(today: dict | None, entries: list | None, provider: str | None) -> str:
    """状态栏标题：`⚡ 12.30M · C 45%`。

    today={"tokens": n} | None；provider 为 quotas entry 的 id，"off"/None = 仅今日用量。
    选中平台无数据时自动降级为仅今日用量；entry 带 note（官方数据 stale）时百分比加 ~。
    """
    base = f"⚡ {fmt_tokens(today['tokens'])}" if today else "⚡ —"
    if not provider or provider == "off":
        return base
    entry = next((e for e in (entries or []) if e.get("id") == provider), None)
    best = best_window(entry)
    if best is None:
        return base
    glyph = PROVIDER_GLYPH.get(provider) or (entry.get("name") or "?")[:1]
    stale = "~" if entry.get("note") else ""
    return f"{base} · {glyph} {stale}{best['pct']:.0f}%"


# ------------------------------------------------------------ 偏好持久化 ----
def prefs_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "settings.json")


def load_prefs() -> dict:
    try:
        with open(prefs_path(), encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_prefs(prefs: dict) -> None:
    try:
        p = prefs_path()
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(prefs, f)
        os.replace(tmp, p)
    except OSError:
        pass
