"""状态栏标题合成与偏好持久化。

纯 Python、无 AppKit 依赖，供 app/menubar.py 使用、tests 直接单测。
参考 CodexBar 的 Merge Icons 思路：单一状态栏图标，标题 = 今日用量 + 选中平台
最紧窗口的已用百分比（stale 官方数据加 ~ 前缀标记）。
"""
from __future__ import annotations

from tokentracker import prefs as _prefs

PROVIDER_GLYPH = {"claude": "C", "codex": "X", "kimi": "K", "go": "G"}
DEFAULT_PROVIDER = _prefs.DEFAULTS["menubar_provider"]  # "off" = 仅今日用量


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


def fmt_quota(window: dict) -> str:
    """Mark the selected window's actual source, independently of entry notes."""
    if window.get("source") == "official":
        marker = "~" if window.get("stale") else ""
    else:
        marker = "≈"
    return f"{marker}{window['pct']:.0f}%"


def fmt_title(today: dict | None, entries: list | None, provider: str | None,
              compact: bool = False) -> str:
    """状态栏标题：`⚡ 12.30M · C 45%`；紧凑模式 `⚡12.30M·C45%`。

    today={"tokens": n} | None；provider 为 quotas entry 的 id，"off"/None = 仅今日用量。
    选中平台无数据时降级为仅今日用量；官方 stale 加 ~，本地估算加 ≈。
    紧凑模式去掉所有空格（刘海屏 / 菜单栏图标拥挤时防止被挤出屏幕）。
    """
    sep, mid = ("", "·") if compact else (" ", " · ")
    base = f"⚡{sep}{fmt_tokens(today['tokens'])}" if today else f"⚡{sep}—"
    if not provider or provider == "off":
        return base
    entry = next((e for e in (entries or []) if e.get("id") == provider), None)
    best = best_window(entry)
    if best is None:
        return base
    glyph = PROVIDER_GLYPH.get(provider) or (entry.get("name") or "?")[:1]
    return f"{base}{mid}{glyph}{sep}{fmt_quota(best)}"


# ------------------------------------------------------------ 偏好持久化 ----
# 规范实现位于 tokentracker.prefs（服务端设置页也要读写）；此处包一层转发，
# 调用方 patch 本模块的 prefs_path 仍然生效（测试隔离依赖这一点）。
def prefs_path() -> str:
    return _prefs.prefs_path()


def load_prefs() -> dict:
    return _prefs.load_prefs(prefs_path())


def save_prefs(prefs: dict) -> None:
    _prefs.save_prefs(prefs, prefs_path())
