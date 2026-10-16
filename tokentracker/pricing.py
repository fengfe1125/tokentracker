"""Event-time price lookup shared with the Swift app via ~/.tokentracker/prices.json.

Rates are USD per million tokens. Model matching is provider-aware and exact;
unknown providers or model IDs remain unpriced while their tokens are retained.
"""
from __future__ import annotations

import json
import os

DEFAULT_PRICES = {"schema_version": 1, "versions": []}


def prices_path() -> str:
    override = os.environ.get("TOKENTRACKER_PRICES")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "prices.json")


def _provider(value: str) -> str:
    name = str(value or "").strip().lower()
    return {
        "claude": "anthropic", "anthropic": "anthropic",
        "open_ai": "openai", "codex": "openai", "openai": "openai",
        "dsh": "deepseek", "deepseek": "deepseek",
        "kimi": "moonshot", "moonshotai": "moonshot", "moonshot": "moonshot",
        "x-ai": "xai", "grok": "xai", "xai": "xai",
        "gemini": "google", "google_ai": "google", "google": "google",
        "mini-max": "minimax", "minimax": "minimax",
    }.get(name, name)


def _legacy_provider(model: str) -> str | None:
    value = model.lower()
    if value.startswith("claude-"):
        return "anthropic"
    if value.startswith(("gpt-", "o1", "o3", "o4", "codex-")):
        return "openai"
    if value.startswith("deepseek-"):
        return "deepseek"
    if value.startswith("kimi-"):
        return "moonshot"
    if value.startswith("grok-"):
        return "xai"
    if value.startswith("gemini-"):
        return "google"
    if value.startswith("minimax-"):
        return "minimax"
    return None


def _normalize_document(data: dict) -> dict:
    """Read current format and explicit legacy model keys; never import default."""
    if isinstance(data.get("versions"), list):
        try:
            schema_version = int(data.get("schema_version") or 1)
        except (TypeError, ValueError):
            return DEFAULT_PRICES.copy()
        if schema_version != 1:
            return DEFAULT_PRICES.copy()
        return {
            "schema_version": schema_version,
            "last_attempt_at_ms": int(data.get("last_attempt_at_ms") or 0),
            "last_success_at_ms": int(data.get("last_success_at_ms") or 0),
            "sync_status": str(data.get("sync_status") or "never"),
            "sync_message": str(data.get("sync_message") or ""),
            "versions": [v for v in data["versions"] if isinstance(v, dict)],
        }
    models = data.get("models") if isinstance(data.get("models"), dict) else data
    versions = []
    for model, rate in models.items():
        if model == "default" or not isinstance(rate, dict):
            continue
        provider = _legacy_provider(model)
        if provider is None:
            continue
        versions.append({
            "id": f"legacy:{provider}:{model}", "provider": provider,
            "model": model, "aliases": [], "effective_at_ms": 0,
            "fetched_at_ms": 0, "source_url": "legacy local price file",
            "rates": {
                "input": rate.get("input", 0), "output": rate.get("output", 0),
                "cache_read": rate.get("cache_read", 0), "cache_write": rate.get("cache_write", 0),
            },
            "conditions": ["Legacy local rate; source and effective date are unknown."],
        })
    return {"schema_version": 1, "versions": versions,
            "last_attempt_at_ms": 0, "last_success_at_ms": 0,
            "sync_status": "legacy", "sync_message": ""}


def load_prices(path: str | None = None) -> dict:
    try:
        with open(path or prices_path(), encoding="utf-8") as stream:
            data = json.load(stream)
        if not isinstance(data, dict):
            return DEFAULT_PRICES.copy()
        return _normalize_document(data)
    except (OSError, ValueError, TypeError):
        return DEFAULT_PRICES.copy()


def quote_for(prices: dict, model: str, input_t: int, output_t: int,
              cache_read: int = 0, cache_write: int = 0, *,
              provider: str | None = None, event_ts: int = 0,
              interval_start: int | None = None) -> tuple[float | None, str | None, str | None]:
    """Return (USD cost, resolved provider, price version ID), or unpriced None."""
    if not model:
        return None, None, None
    model_key = model.strip().lower()
    provider_key = _provider(provider) if provider else None
    versions = [v for v in prices.get("versions", []) if isinstance(v, dict)]
    matching = []
    for version in versions:
        names = [version.get("model", ""), *(version.get("aliases") or [])]
        if model_key not in {str(name).strip().lower() for name in names}:
            continue
        version_provider = _provider(version.get("provider", ""))
        if provider_key is None or provider_key == version_provider:
            matching.append(version)
    if not matching:
        return None, None, None
    providers = {_provider(v.get("provider", "")) for v in matching}
    if provider_key is None and len(providers) != 1:
        return None, None, None

    at = event_ts if event_ts and event_ts > 0 else 2**63 - 1
    eligible = [v for v in matching if int(v.get("effective_at_ms") or 0) <= at]
    if not eligible:
        return None, None, None
    if interval_start and interval_start < at and any(
        interval_start < int(v.get("effective_at_ms") or 0) <= at for v in matching
    ):
        return None, None, None
    selected = max(eligible, key=lambda v: int(v.get("effective_at_ms") or 0))
    rate = selected.get("rates") or {}
    cost = (input_t * float(rate.get("input", 0))
            + output_t * float(rate.get("output", 0))
            + cache_read * float(rate.get("cache_read", 0))
            + cache_write * float(rate.get("cache_write", 0))) / 1_000_000
    return round(cost, 8), _provider(selected.get("provider", "")), str(selected.get("id") or "")


def cost_for(prices: dict, model: str, input_t: int, output_t: int,
             cache_read: int = 0, cache_write: int = 0, *,
             provider: str | None = None, event_ts: int = 0,
             interval_start: int | None = None) -> tuple[float | None, str | None]:
    """Return (USD cost, selected price-version ID)."""
    cost, _resolved_provider, version_id = quote_for(
        prices, model, input_t, output_t, cache_read, cache_write,
        provider=provider, event_ts=event_ts, interval_start=interval_start)
    return cost, version_id
