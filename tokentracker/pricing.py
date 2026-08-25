"""价格表：prices.json（用户可编辑），单位 = 美元 / 每百万 token。

字段：input / output / cache_read / cache_write。未匹配到模型时返回 None（不计费）。
匹配规则：先精确匹配，再对 model 字符串做不区分大小写的子串匹配，最后回退 default。
"""
from __future__ import annotations

import json
import os

DEFAULT_PRICES = {
    "default": {"input": 2.0, "output": 10.0, "cache_read": 0.4, "cache_write": 2.0},
    "models": {
        "claude-opus-4-5": {"input": 5.0, "output": 25.0, "cache_read": 0.5, "cache_write": 1.25},
        "claude-sonnet-4-5": {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 0.75},
        "claude-haiku": {"input": 1.0, "output": 5.0, "cache_read": 0.1, "cache_write": 0.25},
        "gpt-5": {"input": 1.25, "output": 10.0, "cache_read": 0.125, "cache_write": 1.25},
        "gpt-5.6-luna": {"input": 2.0, "output": 12.0, "cache_read": 0.2, "cache_write": 2.0},
        "deepseek-v4-flash": {"input": 0.22, "output": 0.66, "cache_read": 0.007, "cache_write": 0.22},
        "deepseek-v4-pro": {"input": 0.66, "output": 1.98, "cache_read": 0.022, "cache_write": 0.66},
        "kimi-k2": {"input": 0.6, "output": 2.5, "cache_read": 0.1, "cache_write": 0.6},
        "kimi-k3": {"input": 0.6, "output": 2.5, "cache_read": 0.1, "cache_write": 0.6},
        "grok-4.6": {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.0},
    },
}


def prices_path() -> str:
    env = os.environ.get("TOKENTRACKER_PRICES")
    if env:
        return env
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "prices.json")


def load_prices(path: str | None = None) -> dict:
    p = path or prices_path()
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        if "models" not in data:
            data = {"models": data}
        return data
    except (OSError, ValueError):
        return DEFAULT_PRICES


def cost_for(prices: dict, model: str, input_t: int, output_t: int,
             cache_read: int = 0, cache_write: int = 0):
    """返回 (cost_usd | None, matched_key | None)。"""
    if not model:
        return None, None
    models = prices.get("models", {})
    m = model.lower()
    rate = None
    if m in models:
        rate = models[m]
    else:
        # 子串匹配取最长命中键，避免 "gpt-5" 抢先命中 "gpt-5.6-luna"
        best = -1
        for key, val in models.items():
            k = key.lower()
            if k in m and len(k) > best:
                best = len(k)
                rate = val
    if rate is None:
        rate = prices.get("default")
    if not rate:
        return None, None
    cost = (input_t * rate.get("input", 0) + output_t * rate.get("output", 0)
            + cache_read * rate.get("cache_read", 0) + cache_write * rate.get("cache_write", 0)) / 1e6
    return round(cost, 8), None