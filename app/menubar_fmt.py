"""状态栏标题合成与偏好持久化。

纯 Python、无 AppKit 依赖，供 app/menubar.py 使用、tests 直接单测。
参考 CodexBar 的 Merge Icons 思路：单一状态栏图标，标题 = 今日用量 + 选中平台
最紧窗口的已用百分比（stale 官方数据加 ~ 前缀标记）。
"""
from __future__ import annotations

import math

from tokentracker import prefs as _prefs

PROVIDER_GLYPH = {"claude": "C", "codex": "X", "kimi": "K", "go": "G"}
DEFAULT_PROVIDER = _prefs.DEFAULTS["menubar_provider"]  # "off" = 仅今日用量

# 配额紧急度阈值（百分比）
WARN_PCT = 50.0
CRIT_PCT = 80.0

# 工具标识色（与网页端 TOOL 色板一致；菜单圆点/标题 glyph 用）
TOOL_HEX = {
    "claude": "#d97757", "codex": "#5b8def", "opencode": "#34b3a0",
    "dsh": "#b98ae0", "hermes": "#e0a13e", "kimi": "#e06a9a", "pi": "#7fb069",
    "go": "#8b7bd8",
}

# 动画参数
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"   # 扫描中旋转指示（10 帧盲文）
FLASH_DUR = 0.6        # 数值刷新闪光时长（秒）：accent → 主色
PULSE_PERIOD = 2.0     # 配额告急脉冲周期（秒）
PULSE_MIN = 0.45       # 脉冲透明度下限（低幅度，不吵）


def hex_rgb(value: str) -> tuple[float, float, float]:
    v = (value or "").lstrip("#")
    return (int(v[0:2], 16) / 255, int(v[2:4], 16) / 255, int(v[4:6], 16) / 255)


def quota_urgency(pct) -> str:
    """配额紧急度 → 段落 role：quota_ok / quota_warn / quota_crit。"""
    p = float(pct or 0)
    if p >= CRIT_PCT:
        return "quota_crit"
    if p >= WARN_PCT:
        return "quota_warn"
    return "quota_ok"


def quota_marker(window: dict) -> str:
    """官方过期 ~ / 本地估算 ≈ / 官方新鲜 无标记。"""
    if window.get("source") == "official":
        return "~" if window.get("stale") else ""
    return "≈"


def fmt_tokens(n, yi: bool = False) -> str:
    n = float(n or 0)
    if yi and n >= 1e6:            # 亿模式：≥1M 都用亿（0.03亿 = 3M）
        return f"{n / 1e8:.2f}亿"
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
              compact: bool = False, yi: bool = False, ring: bool = False) -> str:
    """纯文本标题（= 分段渲染的拼接；调试/预览/测试用）。语义见 fmt_segments。"""
    return "".join(text for text, _ in fmt_segments(today, entries, provider, compact, yi, ring))


def fmt_segments(today: dict | None, entries: list | None, provider: str | None,
                 compact: bool = False, yi: bool = False,
                 ring: bool = False) -> list[tuple[str, str]]:
    """状态栏标题分段：[(文本, role)]，role 由 AppKit 层映射为颜色。

    `⚡ 12.30M · C 45%`；紧凑模式 `⚡12.30M·C45%`（无空格，防刘海挤出）；
    yi=True 时 ≥1 亿的 token 以「亿」显示（如 `⚡0.55亿·C12%`）。
    ring=True（圆环模式）时由 AppKit 层的彩色扇形圆承担品牌位与百分比表达，
    文本里去掉 ⚡ 与百分比数字，只留 `12.30M·C`（估算/过期标记仍保留）。
    role：bolt ⚡品牌橙 / tokens 主色 / dim 弱化 / glyph 平台字母 /
    marker 过期估算标记 / quota_ok|warn|crit 配额紧急度。
    选中平台无数据时降级为仅今日用量；today 无数据时显示 ⚡ —。
    """
    sep = "" if compact else " "
    lead = "" if ring else sep        # 圆环模式下图标与标题的间距由 AppKit 排版负责
    segs: list[tuple[str, str]] = [] if ring else [("⚡", "bolt")]
    if today:
        segs.append((f"{lead}{fmt_tokens(today['tokens'], yi)}", "tokens"))
    else:
        segs.append((f"{lead}—", "dim"))
    if not provider or provider == "off":
        return segs
    entry = next((e for e in (entries or []) if e.get("id") == provider), None)
    best = best_window(entry)
    if best is None:
        return segs
    glyph = PROVIDER_GLYPH.get(provider) or (entry.get("name") or "?")[:1]
    segs.append(("·" if compact else " · ", "dim"))
    segs.append((glyph, "glyph"))
    marker = quota_marker(best)
    if ring:
        if marker:
            segs.append((marker, "marker"))
        return segs
    if marker:
        segs.append((f"{sep}{marker}", "marker"))
        segs.append((f"{best['pct']:.0f}%", quota_urgency(best.get("pct"))))
    else:
        segs.append((f"{sep}{best['pct']:.0f}%", quota_urgency(best.get("pct"))))
    return segs


# ------------------------------------------------------------ 配额圆环 ----
RING_PT = 14.0            # 状态栏圆环边长（pt）
RING_GLYPHS = "○◔◑◕●"     # 纯文本近似（菜单预览/测试用；真身是 AppKit 矢量图）


def ring_spec(entries: list | None, provider: str | None) -> dict:
    """状态栏配额圆的绘制参数：{"pct": 0..100 | None, "role": ...}。

    pct=None（灰色空心圆）= 选中平台无配额数据 / 仅今日用量模式；
    role 复用标题的紧急度口径（quota_ok|warn|crit，阈值 50/80），
    无数据时为 quota_none。
    """
    if provider and provider != "off":
        entry = next((e for e in (entries or []) if e.get("id") == provider), None)
        best = best_window(entry)
        if best is not None and best.get("pct") is not None:
            pct = max(0.0, min(100.0, float(best["pct"])))
            return {"pct": pct, "role": quota_urgency(pct)}
    return {"pct": None, "role": "quota_none"}


def ring_glyph(spec: dict | None) -> str:
    """圆环的纯文本近似字符（菜单里的「当前：」预览用）。"""
    pct = (spec or {}).get("pct")
    if pct is None:
        return RING_GLYPHS[0]
    idx = int(round(float(pct) / 100.0 * (len(RING_GLYPHS) - 1)))
    return RING_GLYPHS[max(0, min(len(RING_GLYPHS) - 1, idx))]


def today_line_segments(today: dict | None, yi: bool = False) -> list[tuple[str, str]]:
    """菜单首行分段：今日 xx tokens · $cost。"""
    if not today:
        return [("今日暂无数据（点「立即扫描」）", "dim")]
    return [("今日 ", "dim"), (fmt_tokens(today["tokens"], yi), "tokens"),
            (" tokens", "dim"), (" · ", "dim"), (f"${today['cost']:.2f}", "cost")]


def quota_line_segments(entry: dict) -> list[tuple[str, str]]:
    """菜单配额行分段：●(工具色点) 名称 · 窗口 label pct(紧急度色)。"""
    name = entry.get("name", "?")
    best = best_window(entry)
    if not best:
        return [(name, "ink")]
    dot = f"dot_{entry.get('id', '')}"
    label = best.get("label", "")
    return [("● ", dot), (name, "ink"), (f" · {label} ", "dim"),
            (fmt_quota(best), quota_urgency(best.get("pct")))]


# ------------------------------------------------------------ 动画曲线 ----
def spinner_frame(index: int) -> str:
    return SPINNER[index % len(SPINNER)]


def flash_alpha(elapsed: float, dur: float = FLASH_DUR) -> float:
    """数值刷新闪光：0 = 全品牌橙，1 = 完全回到主色；超出时长钳制为 1。"""
    if elapsed <= 0:
        return 0.0
    return min(1.0, elapsed / dur)


def pulse_alpha(elapsed: float, period: float = PULSE_PERIOD) -> float:
    """配额告急脉冲透明度：[PULSE_MIN, 1] 正弦低幅波动。"""
    return PULSE_MIN + (1 - PULSE_MIN) * (0.5 + 0.5 * math.sin(2 * math.pi * elapsed / period))


# ------------------------------------------------------------ 偏好持久化 ----
# 规范实现位于 tokentracker.prefs（服务端设置页也要读写）；此处包一层转发，
# 调用方 patch 本模块的 prefs_path 仍然生效（测试隔离依赖这一点）。
def prefs_path() -> str:
    return _prefs.prefs_path()


def load_prefs() -> dict:
    return _prefs.load_prefs(prefs_path())


def save_prefs(prefs: dict) -> None:
    _prefs.save_prefs(prefs, prefs_path())
