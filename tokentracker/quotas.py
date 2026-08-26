"""订阅配额：固定窗口（5小时 / 7天 / 月度），官方数据优先，本地估算兜底。

数据来源两级：
1. 官方（凭据有效时）：Claude OAuth usage 接口、Kimi gateway usages——
   显示官方百分比与重置倒计时（billing.py）。
2. 本地估算（always 可用）：从汇总库算各窗口的真实用量，
   与 quotas.json 里配置的窗口上限对比出进度。

OpenCode Go 的上限是官方公开固定值（$12/5h、$30/7d、$60/月），无需登录，
用量直接用本地 DSH deepseek 模型的估算成本统计。
窗口固定，不随仪表盘的时间范围（今天/本周/本月/全部）变化。
"""
from __future__ import annotations

import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

from . import billing as _billing
from . import db

DEFAULT_QUOTAS = {
    "entries": [
        {"id": "claude", "name": "Claude Code", "plan": "Pro/Max",
         "tool": "claude", "official": "claude-oauth",
         "windows": {
             "5h":   {"label": "5 小时", "limit_tokens": 100_000_000},
             "7d":   {"label": "周 (7天)", "limit_tokens": 400_000_000},
         }},
        {"id": "kimi", "name": "Kimi", "plan": "Kimi for Coding",
         "tool": "kimi", "official": "kimi",
         "windows": {
             "5h":   {"label": "5 小时", "limit_tokens": 50_000_000},
             "7d":   {"label": "周 (7天)", "limit_tokens": 200_000_000},
             "month": {"label": "月度", "limit_tokens": 800_000_000},
         }},
        {"id": "go", "name": "OpenCode Go", "plan": "GO 订阅 ($12/5h, $30/周, $60/月)",
         "tool": "dsh", "model_prefix": "deepseek", "official": "go",
         "windows": {
             "5h":   {"label": "5 小时", "limit_usd": 12},
             "7d":   {"label": "周 (7天)", "limit_usd": 30},
             "month": {"label": "月度", "limit_usd": 60},
         }},
        {"id": "codex", "name": "Codex", "plan": "ChatGPT 订阅",
         "tool": "codex", "official": "codex",
         "windows": {
             "7d": {"label": "周 (7天)", "limit_tokens": 500_000_000},
         }},
    ],
}

_WIN_ORDER = ["5h", "7d", "month"]
_WIN_OFFICIAL = {"5h": "5h", "7d": "7d", "month": "month"}


def quotas_path() -> str:
    env = os.environ.get("TOKENTRACKER_QUOTAS")
    if env:
        return env
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "quotas.json")


def load_quotas(path: str | None = None) -> dict:
    p = path or quotas_path()
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or "entries" not in data:
            raise ValueError
        return data
    except (OSError, ValueError):
        return DEFAULT_QUOTAS


def _window_start(key: str) -> int:
    now_ms = int(time.time() * 1000)
    if key == "5h":
        return now_ms - 5 * 3600 * 1000
    if key == "7d":
        return now_ms - 7 * 24 * 3600 * 1000
    if key == "month":
        now = datetime.now()
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        return int(start.timestamp() * 1000)
    return now_ms - 24 * 3600 * 1000


def compute(conn) -> dict:
    cfg = load_quotas()
    # 官方抓取并行执行，任一失败/超时（≤8s）不阻塞整体
    oauths = {e.get("official") for e in cfg.get("entries", []) if e.get("official")}
    official_cache: dict = {}
    if oauths:
        def _fetch(name: str):
            fn = {"claude-oauth": _billing.claude_oauth_usage,
                  "kimi": _billing.kimi_usage,
                  "codex": _billing.codex_usage,
                  "go": _billing.go_usage}.get(name)
            return _billing._cached(name, fn) if fn else None
        with ThreadPoolExecutor(max_workers=len(oauths)) as pool:
            for name, res in zip(oauths, pool.map(_fetch, oauths)):
                official_cache[name] = res
    entries = []
    for e in cfg.get("entries", []):
        tool = e.get("tool")
        prefix = e.get("model_prefix")
        include_cache = bool(e.get("include_cache"))
        wins = e.get("windows") or {}
        official = official_cache.get(e.get("official")) if e.get("official") else None

        windows = []
        any_official = False
        for key in _WIN_ORDER:
            if key not in wins:
                continue
            lim = wins[key]
            unit = "usd" if "limit_usd" in lim else "tokens"
            limit = lim.get("limit_usd") if unit == "usd" else lim.get("limit_tokens", 0)
            start = _window_start(key)
            used = db.window_usage(conn, start, tool=tool, model_prefix=prefix,
                                   include_cache=include_cache, usd=(unit == "usd"))
            # 官方覆盖
            ow = None
            if official and official.get("windows"):
                ow = official["windows"].get(_WIN_OFFICIAL.get(key))
            if ow and ow.get("pct") is not None:
                any_official = True
                windows.append({
                    "key": key, "label": lim.get("label", key),
                    "unit": ow.get("unit") or "pct",
                    "pct": round(ow["pct"], 1),
                    "used": ow.get("used"), "limit": ow.get("limit"),
                    "resets_at": ow.get("resets_at"), "source": "official",
                })
                continue
            pct = (used / limit * 100) if limit else (0.0 if used == 0 else None)
            windows.append({
                "key": key, "label": lim.get("label", key),
                "unit": unit,
                "used": round(used, 2) if unit == "usd" else int(used),
                "limit": limit,
                "pct": round(pct, 1) if pct is not None else None,
                "resets_at": None, "source": "local",
            })
        status = ""
        if official and official.get("_stale_min"):
            status = (f"官方接口暂时不可用（{official.get('_err') or '限流'}），"
                      f"显示 {official['_stale_min']} 分钟前的官方数据")
        elif official and official.get("error"):
            status = official.get("detail") or official.get("error")
        plan = e.get("plan", "")
        if official and official.get("plan"):
            op = str(official["plan"])
            # 官方 plan 与配置重复时只保留信息量更大的一边（如 "Pro" vs "Pro / Max"）
            plan = plan if not plan or op.lower() in plan.lower() else f"{op} · {plan}".strip(" ·")
        entries.append({
            "id": e["id"], "name": e["name"], "plan": plan,
            "source": "official" if any_official else "local",
            "note": status, "windows": windows,
        })
    return {"entries": entries}