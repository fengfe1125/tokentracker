"""官方订阅配额抓取（只读优先；仅在 token 轮换时回写来源，防止把官方 CLI 登出）。

参考实现（GitHub 调研结论）：
- Claude：三级回退链（CodexBar docs/claude.md + zach-source/ccswitch）
  1. 桌面 App 采样文件 ~/Library/Application Support/Claude/plan-usage-history.json
     （桌面 App 每 ~5 分钟自采，无需凭据；Claude Code 2.1.x 会清空自己钥匙串里的
      claudeAiOauth（官方 bug #84331/#88583），这条路完全不受影响，样本 <30min 有效）
  2. GET https://api.anthropic.com/api/oauth/usage（Bearer + anthropic-beta: oauth-2025-04-20）
     凭据来源遍历：钥匙串「Claude Code-credentials」→ ~/.claude/.credentials.json
     → 本地快照 ~/.tokentracker/claude_cred_backup.json（见到有效凭据就快照，
     官方存储被清空时从快照复活）；跳过空壳条目，逐个尝试直到成功。
     刷新失败时委托官方 CLI（隔离 CLAUDE_CONFIG_DIR + CLAUDE_CODE_OAUTH_REFRESH_TOKEN
     跑 `claude auth login`，ccswitch 同款），抗端点/UA 协议变更。
  3. 全灭 → 提示 claude auth login 重新登录 / 打开桌面 App。
- Kimi：只读 KIMI_CODE_HOME（默认 ~/.kimi-code）中的现有凭据，
  GET https://api.kimi.com/coding/v1/usages；返回请求次数的 5 小时窗口与周期配额。
  access_token 只有 ~15 分钟寿命且 Kimi Code 仅活跃时才会刷新（闲置即过期），
  故过期时 TokenTracker 自刷新：POST {auth}/api/oauth/token（grant_type=refresh_token，
  public client），结果原子写回凭据文件（refresh_token 每次轮换，必须写回——kimi-code
  刷新时从磁盘重读，不写回才会把它登出）。flock 串行化多进程刷新，遇 invalid_grant
  重读磁盘兜底并发竞争。登录流程绝不触碰（无 refresh_token 时报错并提示 kimi login）。
  （端点与 client_id 取自 kimi-code 二进制；CodexBar docs/kimi.md 的只读策略会导致
   闲置期面板长期「暂时不可用」，故升级为自刷新。）
- Codex：主路 GET https://chatgpt.com/backend-api/wham/usage（CodexBar docs/codex.md +
  headroom subscription/codex_rate_limits.py；Bearer 用 ~/.codex/auth.json 的 access_token
  + ChatGPT-Account-Id 头；401 时向 auth.openai.com/oauth/token 刷新并原子写回）。
  兑底 spawn `codex -s read-only -a untrusted app-server` JSON-RPC over stdio
  （新版 codex-cli 上 RPC 协议不稳定，故降为兑底）。结果带 _via 标明走的那条路。

凭据过期/无效时返回 {"error": ...}，由上层降级为本地窗口估算，绝不阻塞。
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import math
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from email.utils import parsedate_to_datetime

_CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
_CLAUDE_UA = "claude-cli/2.0.0 (external, cli)"
_CLAUDE_TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
_CLAUDE_KC_SERVICE = "Claude Code-credentials"
_CLAUDE_PLAN = {"pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"}
_KIMI_PLAN = {"LEVEL_BASIC": "基础版", "LEVEL_INTERMEDIATE": "中级版", "LEVEL_PREMIUM": "高级版",
              "LEVEL_UNLIMITED": "无限版", "LEVEL_PRO": "专业版"}
_KIMI_CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098"   # kimi-code 二进制内置 public client
_GO_QUOTA_URL = "https://opencode.ai/zen/go/v1/usage"
_GO_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
_CODEX_WIN_BY_MIN = {300: "5h", 10_080: "7d", 43_200: "month", 44_640: "month"}
_CODEX_WIN_BY_SEC = {18_000: "5h", 604_800: "7d", 2_592_000: "month", 2_678_400: "month"}
_CODEX_WHAM_URL = "https://chatgpt.com/backend-api/wham/usage"
_CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token"
_CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
_TTL_OK = 120     # 成功结果缓存
_TTL_ERR = 120    # 失败退避（限流接口不宜高频重试）
_STALE_MAX = 24 * 3600   # 磁盘兜底缓存最长可用 24h
_cache: dict = {}
_cache_lock = threading.Lock()
_disk_lock = threading.Lock()


class _ProviderCache:
    def __init__(self):
        self.lock = threading.Lock()
        self.generation = 0
        self.attempt = None
        self.success = None
        self.retry_until = 0.0
        self.rate_limit_until = 0.0
        self.source_version = None


def _disk_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "official_cache.json")


def _disk_load(key: str):
    """读磁盘缓存的成功结果 → (ts, data) | (None, None)。"""
    try:
        with open(_disk_path(), encoding="utf-8") as f:
            store = json.load(f)
        ts, data = store[key]
        if (not isinstance(data, dict) or data.get("error")
                or not 0 <= time.time() - ts <= _STALE_MAX):
            return None, None
        return ts, data
    except (OSError, ValueError, KeyError, TypeError):
        return None, None


def _disk_store(key: str, ts: float, data: dict):
    """成功结果落盘（跨进程共享，限流时互为兜底）；只存配额数字，不含凭据。"""
    tmp = None
    try:
        path = _disk_path()
        directory = os.path.dirname(path)
        os.makedirs(directory, exist_ok=True)
        # The persistent lock file must not be replaced with the JSON inode.
        with _disk_lock, open(path + ".lock", "a+b") as lock_file:
            fcntl.flock(lock_file, fcntl.LOCK_EX)
            store = {}
            try:
                with open(path, encoding="utf-8") as f:
                    loaded = json.load(f)
                if isinstance(loaded, dict):
                    store = loaded
            except (OSError, ValueError):
                pass
            store[key] = [ts, data]
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                             dir=directory, prefix=".official_cache.",
                                             suffix=".tmp", delete=False) as f:
                tmp = f.name
                json.dump(store, f, allow_nan=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
    except (OSError, ValueError, TypeError):
        pass
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _cached_result(key: str, state: _ProviderCache, now: float):
    data = state.attempt[1]
    if data.get("_ok"):
        if now - state.attempt[0] < _TTL_OK:
            return data
        # A successful fallback can still carry an upstream rate limit. Once
        # its normal TTL ends it is stale, not fresh for the entire backoff.
        data = {"error": "http_429", "detail": "官方接口限流，等待 Retry-After", "_ok": False}
    stale_ts, stale = state.success or (None, None)
    if stale is not None and not 0 <= now - stale_ts <= _STALE_MAX:
        state.success = None
        stale = None
    if stale is None:
        stale_ts, stale = _disk_load(key)
        if stale is not None:
            state.success = (stale_ts, stale)
    if stale is not None:
        return dict(stale, _stale_min=max(1, int((now - stale_ts) / 60)),
                    _err=data.get("detail") or data.get("error") or "")
    return data


def _cached(key: str, fn, force: bool = False, version_fn=None):
    """Coalesce provider requests; retain success separately from failed attempts.

    Force skips ordinary TTLs, never server rate limits. Callers arriving during
    an existing request share its result, including simultaneous forced callers.
    """
    with _cache_lock:
        state = _cache.setdefault(key, _ProviderCache())
        generation = state.generation
    with state.lock:
        now = time.time()
        force = force and generation == state.generation
        version = version_fn() if version_fn else None
        source_changed = version != state.source_version
        if state.attempt and (now < state.rate_limit_until
                              or (not force and not source_changed and now < state.retry_until)):
            return _cached_result(key, state, now)
        # Snapshot before reading credentials: a concurrent CLI write is noticed
        # on the next poll. Only file metadata is retained, never token values.
        state.source_version = version
        try:
            data = fn()
            data = dict(data, _ok=not data.get("error"))
        except Exception as e:  # noqa: BLE001
            data = {"error": "network", "detail": str(e), "_ok": False}
        now = time.time()
        state.attempt = (now, data)
        try:
            retry_after = max(0.0, float(data.get("_retry_after") or 0))
        except (TypeError, ValueError, OverflowError):
            retry_after = 0.0
        if not math.isfinite(retry_after):
            retry_after = 0.0
        if data.get("_ok"):
            state.success = (now, data)
            state.retry_until = now + max(_TTL_OK, retry_after)
            _disk_store(key, now, data)
        else:
            state.retry_until = now + max(_TTL_ERR, retry_after)
        state.rate_limit_until = (state.retry_until if retry_after > 0
                                  or data.get("error") == "http_429" else 0.0)
        result = _cached_result(key, state, now)
        state.generation += 1
        return result


def _iso_ms(s) -> int | None:
    """ISO 时间串 → epoch 毫秒。"""
    if not s:
        return None
    try:
        return int(datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp() * 1000)
    except (ValueError, TypeError):
        return None


def _http_json(url: str, headers: dict, body: bytes | None = None, method: str = "GET"):
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            raw = r.read().decode("utf-8", "replace")
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        try:
            data = json.loads(e.read().decode("utf-8", "replace"))
        except ValueError:
            data = {}
        if not isinstance(data, dict):
            data = {}
        retry_after = (e.headers or {}).get("Retry-After")
        try:
            ra = int(retry_after or 0)
        except (TypeError, ValueError):
            try:
                ra = math.ceil(parsedate_to_datetime(retry_after).timestamp() - time.time())
            except (TypeError, ValueError, OverflowError, AttributeError):
                ra = 0
        if ra > 0:
            data["_retry_after"] = ra
        return e.code, data
    except Exception as e:  # noqa: BLE001
        return 0, {"error": str(e)}


def _pct(v) -> float | None:
    """Official utilization fields are percentages, including values below 1%."""
    try:
        p = float(v)
    except (TypeError, ValueError, OverflowError):
        return None
    return p if math.isfinite(p) else None


# ---------------------------------------------------------------- Claude ----
def _kc_read() -> dict | None:
    """macOS 钥匙串读 Claude Code 登录态（整个 JSON，含 mcpOAuth 等其他顶层键）。"""
    if sys.platform != "darwin":
        return None
    try:
        r = subprocess.run(["security", "find-generic-password",
                            "-s", _CLAUDE_KC_SERVICE, "-w"],
                           capture_output=True, text=True, timeout=6)
        if r.returncode != 0:
            return None
        data = json.loads(r.stdout.strip())
        return data if isinstance(data, dict) and data.get("claudeAiOauth") else None
    except Exception:  # noqa: BLE001
        return None


def _kc_write(data: dict) -> bool:
    """整体回写钥匙串条目（保留 mcpOAuth 等键）。账号名从条目属性读，读不到就不写。"""
    if sys.platform != "darwin":
        return False
    try:
        r = subprocess.run(["security", "find-generic-password", "-g",
                            "-s", _CLAUDE_KC_SERVICE],
                           capture_output=True, text=True, timeout=6)
        m = re.search(r'"acct"<blob>="([^"]+)"', r.stderr)
        acct = m.group(1) if m else ""
        if not acct:
            return False
        r2 = subprocess.run(["security", "add-generic-password", "-U",
                             "-a", acct, "-s", _CLAUDE_KC_SERVICE,
                             "-w", json.dumps(data)],
                            capture_output=True, timeout=6)
        return r2.returncode == 0
    except Exception:  # noqa: BLE001
        return False


# ------------------------------------------------- Claude 凭据快照（P2） ----
def _claude_snap_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "claude_cred_backup.json")


def _claude_snap_save(oauth: dict):
    """见到有效凭据（含 refreshToken）时快照一份到 ~/.tokentracker/（0600）。

    Claude Code 2.1.x 会清空自己钥匙串里的 claudeAiOauth（官方 bug #84331/#88583），
    有这份快照就能在官方存储被清空后自行复活（ccswitch 同款思路）。
    """
    if not oauth.get("refreshToken"):
        return
    try:
        p = _claude_snap_path()
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"claudeAiOauth": oauth, "saved_at": time.time()}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, p)
    except OSError:
        pass


def _claude_snap_load() -> dict | None:
    try:
        with open(_claude_snap_path(), encoding="utf-8") as f:
            d = json.load(f)
        o = d.get("claudeAiOauth")
        return o if isinstance(o, dict) and (o.get("refreshToken") or o.get("accessToken")) else None
    except (OSError, ValueError):
        return None


def _claude_credentials() -> list:
    """全部凭据来源 → [(oauth_dict, write_back|None, source_label), ...]。

    钥匙串、~/.claude/.credentials.json、本地快照三处都试，跳过被清空的空壳条目
    （accessToken/refreshToken 皆空、expiresAt=0 —— Claude Code 2.1.x bug 的特征）。
    按 expiresAt 从新到旧排序，调用方逐个尝试直到成功。
    """
    cands = []
    kc = _kc_read()
    if kc:
        def kc_save(oauth, _kc=kc):
            _kc_write(dict(_kc, claudeAiOauth=oauth))
        cands.append((kc["claudeAiOauth"], kc_save, "keychain"))
    path = os.path.expanduser("~/.claude/.credentials.json")
    try:
        with open(path, encoding="utf-8") as f:
            cred = json.load(f)
        if isinstance(cred, dict) and cred.get("claudeAiOauth"):
            def file_save(oauth, _cred=cred, _path=path):
                try:
                    tmp = _path + ".tmp"
                    with open(tmp, "w", encoding="utf-8") as f:
                        json.dump(dict(_cred, claudeAiOauth=oauth), f)
                    os.chmod(tmp, 0o600)
                    os.replace(tmp, _path)
                except OSError:
                    pass
            cands.append((cred["claudeAiOauth"], file_save, "file"))
    except (OSError, ValueError):
        pass
    snap = _claude_snap_load()
    if snap:
        def snap_save(oauth):
            _claude_snap_save(oauth)
        cands.append((snap, snap_save, "snapshot"))
    # 跳过空壳（官方 bug 清空的条目）
    cands = [c for c in cands if c[0].get("accessToken") or c[0].get("refreshToken")]
    cands.sort(key=lambda c: c[0].get("expiresAt") or 0, reverse=True)
    return cands


def _claude_refresh(refresh_token: str) -> dict:
    """refresh_token 换新的 access/refresh token（UA 须为 claude-cli，否则 CF 1010）。"""
    body = json.dumps({"grant_type": "refresh_token", "refresh_token": refresh_token,
                       "client_id": _CLAUDE_CLIENT_ID}).encode()
    status, data = _http_json(
        _CLAUDE_TOKEN_URL,
        {"Content-Type": "application/json", "User-Agent": _CLAUDE_UA},
        body=body, method="POST")
    if status != 200 or not isinstance(data, dict) or not data.get("access_token"):
        raise RuntimeError(f"HTTP {status}")
    return data


def _claude_refresh_cli(refresh_token: str) -> dict:
    """手写刷新失败时，委托官方 CLI 刷新（ccswitch 的思路）：
    隔离 CLAUDE_CONFIG_DIR + CLAUDE_CODE_OAUTH_REFRESH_TOKEN 环境变量跑
    `claude auth login`，端点/UA/scope 全由官方 CLI 决定，抗协议变更。
    返回 {"access_token", "refresh_token"?, "expires_in"}。"""
    claude = shutil.which("claude")
    if not claude:
        raise RuntimeError("未找到 claude CLI")
    import tempfile
    tmp = tempfile.mkdtemp(prefix="tt-refresh-")
    try:
        cred_file = os.path.join(tmp, ".credentials.json")
        with open(cred_file, "w", encoding="utf-8") as f:
            json.dump({"claudeAiOauth": {"refreshToken": refresh_token}}, f)
        os.chmod(cred_file, 0o600)
        with open(os.path.join(tmp, ".claude.json"), "w", encoding="utf-8") as f:
            f.write('{"hasCompletedOnboarding":true}')
        env = dict(os.environ)
        env.update({"CLAUDE_CONFIG_DIR": tmp,
                    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": refresh_token,
                    "CLAUDE_CODE_OAUTH_SCOPES": "openid,profile,email,offline_access"})
        r = subprocess.run([claude, "auth", "login"], env=env, cwd=tmp,
                           capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise RuntimeError((r.stderr or r.stdout or "login failed").strip()[:120])
        with open(cred_file, encoding="utf-8") as f:
            o = (json.load(f).get("claudeAiOauth") or {})
        if not o.get("accessToken"):
            raise RuntimeError("CLI 未返回新 token")
        exp_ms = o.get("expiresAt") or 0
        return {"access_token": o["accessToken"],
                "refresh_token": o.get("refreshToken"),
                "expires_in": max(60, int((exp_ms - time.time() * 1000) / 1000))}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _claude_desktop_usage() -> dict | None:
    """Claude 桌面 App 的配额采样文件（无需凭据）：
    ~/Library/Application Support/Claude/plan-usage-history.json，桌面 App 每 ~5 分钟
    采样一次 {fh: 5h百分比, sd: 7d百分比}。样本 <30 分钟认为有效。"""
    path = os.path.join(os.path.expanduser("~"),
                        "Library", "Application Support", "Claude", "plan-usage-history.json")
    try:
        with open(path, encoding="utf-8") as f:
            samples = (json.load(f).get("samples") or [])
        if not samples:
            return None
        last = samples[-1]
        age_min = (time.time() * 1000 - last.get("t", 0)) / 60000
        if age_min > 30:
            return None
        u = last.get("u") or {}
        windows = {}
        if u.get("fh") is not None:
            windows["5h"] = {"pct": float(u["fh"]), "resets_at": None}
        if u.get("sd") is not None:
            windows["7d"] = {"pct": float(u["sd"]), "resets_at": None}
        if not windows:
            return None
        return {"windows": windows, "_via": "desktop",
                "_sample_age_min": max(0, int(age_min))}
    except (OSError, ValueError, TypeError):
        return None


def _claude_usage_http(tok: str):
    return _http_json(
        "https://api.anthropic.com/api/oauth/usage",
        {"Authorization": f"Bearer {tok}",
         "anthropic-beta": "oauth-2025-04-20",
         "Content-Type": "application/json"},
    )


def _claude_try_source(oauth: dict, save) -> dict:
    """单个凭据来源：access token 直接调 → 过期/401 则刷新（手写 → CLI 委托）后重试。
    成功时刷新后的凭据写回来源。失败抛不出，返回 {"error": ...}。"""
    tok = oauth.get("accessToken")
    exp = oauth.get("expiresAt") or 0
    need_refresh = not tok or (exp and time.time() * 1000 > exp - 60_000)
    if not need_refresh:
        status, data = _claude_usage_http(tok)
        if status == 200:
            return {"data": data, "oauth": oauth}
        if status == 429:
            return {"error": "http_429", "detail": "Claude usage 接口限流，稍后自动重试",
                    "_retry_after": data.get("_retry_after") if isinstance(data, dict) else None}
        if status != 401:
            return {"error": f"http_{status}", "detail": f"Claude usage 接口返回 {status}"}
        need_refresh = True  # 401 → 尝试刷新
    rt = oauth.get("refreshToken")
    if not rt:
        return {"error": "expired", "detail": "Claude 登录态已过期且无 refreshToken"}
    d = None
    err = ""
    try:
        d = _claude_refresh(rt)
    except Exception as e:  # noqa: BLE001
        err = str(e)
        try:
            d = _claude_refresh_cli(rt)  # 官方 CLI 委托刷新（抗协议变更）
        except Exception as e2:  # noqa: BLE001
            err = f"{err}；CLI 委托也失败({e2})"
    if not d:
        return {"error": "refresh_failed", "detail": f"Claude token 刷新失败({err})"}
    # 刷新令牌会轮换：必须写回来源，否则 Claude Code 本体下次刷新会被登出
    oauth["accessToken"] = d["access_token"]
    if d.get("refresh_token"):
        oauth["refreshToken"] = d["refresh_token"]
    oauth["expiresAt"] = int(time.time() * 1000) + int(d.get("expires_in", 28800)) * 1000
    if save:
        save(oauth)
    status, data = _claude_usage_http(oauth["accessToken"])
    if status == 200:
        return {"data": data, "oauth": oauth}
    if status == 429:
        return {"error": "http_429", "detail": "Claude usage 接口限流，稍后自动重试",
                "_retry_after": data.get("_retry_after") if isinstance(data, dict) else None}
    return {"error": f"http_{status}", "detail": f"Claude usage 接口刷新后仍返回 {status}"}


def claude_oauth_usage() -> dict:
    """Claude 官方配额，三级回退：
    1. 桌面 App 采样文件（<30min，无需凭据，绕过 Claude Code 2.1.x 清空钥匙串的 bug）
    2. OAuth usage API：遍历钥匙串/文件/本地快照所有凭据源，逐个尝试直到成功
    3. 全灭 → 可操作的错误提示
    """
    # 1) 桌面采样（桌面 App 登录态独立于 CLI，最抗造）
    desk = _claude_desktop_usage()

    # 2) OAuth API（能拿到 resets_at 和更细的 sonnet/opus 窗口，成功则用更丰富的那份）
    cands = _claude_credentials()
    oauth_err = None
    for oauth, save, src in cands:
        r = _claude_try_source(oauth, save)
        if r.get("data") is not None:
            data = r["data"]
            if not isinstance(data, dict):
                oauth_err = {"error": "parse", "detail": "接口响应格式异常"}
                continue
            windows = {}
            for key, label in (("five_hour", "5h"), ("seven_day", "7d"),
                               ("seven_day_sonnet", "7d_sonnet"), ("seven_day_opus", "7d_opus")):
                w = data.get(key)
                if isinstance(w, dict):
                    pct = _pct(w.get("utilization") if w.get("utilization") is not None
                               else w.get("used_percentage"))
                    if pct is not None:
                        windows[label] = {"pct": pct, "resets_at": _iso_ms(w.get("resets_at"))}
            if windows:
                _claude_snap_save(r["oauth"])  # 凭据有效 → 快照（防官方存储再被清空）
                extra = data.get("extra_usage") or {}
                plan = (data.get("plan") or data.get("rate_limit_tier")
                        or _CLAUDE_PLAN.get(str(r["oauth"].get("subscriptionType") or "").lower())
                        or r["oauth"].get("subscriptionType") or "")
                return {"windows": windows, "plan": plan, "_via": "oauth",
                        "extra": {"used_credits": extra.get("used_credits"),
                                  "monthly_limit": extra.get("monthly_limit"),
                                  "disabled": extra.get("disabled_reason")}}
            oauth_err = {"error": "no_windows", "detail": "接口未返回窗口数据"}
            continue
        oauth_err = r
        # 限流是接口问题不是凭据问题，换源无意义，直接停
        if r.get("error") == "http_429":
            break

    # 3) OAuth 全灭 → 桌面采样顶底（标记来源）
    if desk:
        if oauth_err:
            desk["_oauth_err"] = oauth_err.get("error")
            if oauth_err.get("error") == "http_429":
                desk["_retry_after"] = oauth_err.get("_retry_after") or _TTL_ERR
        return desk
    if not cands:
        return {"error": "no_credentials",
                "detail": "未找到 Claude 登录态（钥匙串 / ~/.claude/.credentials.json 均为空）"}
    err = dict(oauth_err or {"error": "unknown"})
    if err.get("error") in ("expired", "refresh_failed"):
        err["detail"] = (err.get("detail", "") +
                         "。请在终端执行 claude auth login 重新登录，或打开一次 Claude 桌面 App")
    return err


# ------------------------------------------------------------------ Kimi ----
def _kimi_credentials_path() -> str:
    root = os.environ.get("KIMI_CODE_HOME") or "~/.kimi-code"
    return os.path.join(os.path.expanduser(root), "credentials", "kimi-code.json")


def _kimi_credentials_version():
    path = _kimi_credentials_path()
    try:
        st = os.stat(path)
        return path, st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size
    except OSError:
        return path, None


def _kimi_oauth_host() -> str:
    """Kimi OAuth host：环境变量覆盖（与 kimi-code 同名）→ region 文件 → CN 默认。
    凭据里不记 region，kimi-code 把它写在 KIMI_CODE_HOME/region（mainland-cn 以外走 .ai）。"""
    env = os.environ.get("KIMI_CODE_OAUTH_HOST") or os.environ.get("KIMI_OAUTH_HOST")
    if env:
        return env.rstrip("/")
    root = os.environ.get("KIMI_CODE_HOME") or "~/.kimi-code"
    try:
        with open(os.path.join(os.path.expanduser(root), "region"), encoding="utf-8") as f:
            if f.read().strip() not in ("", "mainland-cn"):
                return "https://auth.kimi.ai"
    except OSError:
        pass
    return "https://auth.kimi.com"


def _kimi_api_base() -> str:
    """usages 等业务 API 前缀：与 OAuth host 同域族（auth.kimi.com ↔ api.kimi.com）。"""
    m = re.match(r"^(https://)auth\.(.+)$", _kimi_oauth_host())
    return f"{m.group(1)}api.{m.group(2)}/coding/v1" if m else "https://api.kimi.com/coding/v1"


@contextlib.contextmanager
def _kimi_refresh_lock(timeout: float = 5.0):
    """刷新凭据的跨进程互斥（menubar / serve / CLI 多进程都会轮询配额）。
    锁文件常驻不删（与 official_cache.json.lock 同一约定），仅作 flock 载体。"""
    path = os.path.join(os.path.dirname(_kimi_credentials_path()), ".tokentracker-refresh.lock")
    f = open(path, "a+b")
    try:
        deadline = time.time() + timeout
        while True:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() >= deadline:
                    raise TimeoutError("等待 Kimi 刷新锁超时") from None
                time.sleep(0.05)
        yield
    finally:
        try:
            fcntl.flock(f, fcntl.LOCK_UN)
        except OSError:
            pass
        f.close()


def _kimi_write_credentials(path: str, cred: dict) -> None:
    """原子写回凭据（tmp + replace，0600）；保留文件里的全部键。"""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cred, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _kimi_refresh_credentials(cred: dict) -> dict | None:
    """refresh_token 换新凭据；失败（网络/invalid_grant/响应异常）返回 None。
    refresh_token 每次刷新即轮换，旧的一用就废——并发刷新只有一个赢家。"""
    rt = cred.get("refresh_token")
    if not isinstance(rt, str) or not rt.strip():
        return None
    body = urllib.parse.urlencode({
        "client_id": _KIMI_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": rt,
    }).encode()
    status, data = _http_json(
        f"{_kimi_oauth_host()}/api/oauth/token",
        {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
        body=body, method="POST")
    if status != 200 or not isinstance(data, dict) or not data.get("access_token"):
        return None
    try:
        expires_in = float(data.get("expires_in") or 0)
        if not math.isfinite(expires_in) or expires_in <= 0:
            raise ValueError
    except (TypeError, ValueError, OverflowError):
        expires_in = 900   # 实测 TTL ~15min，响应缺省时按同寿命保守处理
    new = dict(cred, access_token=data["access_token"],
               expires_at=time.time() + expires_in)
    if data.get("refresh_token"):
        new["refresh_token"] = data["refresh_token"]
    if data.get("expires_in") is not None:
        new["expires_in"] = data["expires_in"]
    return new


def _kimi_fresh_credentials(timeout: float = 5.0) -> dict | None:
    """过期凭据自愈：加锁 → 锁内重读（可能刚被 kimi-code/别的进程刷新）→
    自刷新 → 原子写回。返回可用凭据；不可恢复返回 None。
    写回是必要的：refresh_token 轮换，kimi-code 下次刷新从磁盘重读新 token，
    不写回才会把它的登录态弄失效。"""
    path = _kimi_credentials_path()
    try:
        with _kimi_refresh_lock(timeout):
            try:
                with open(path, encoding="utf-8") as f:
                    cred = json.load(f)
            except (OSError, ValueError, UnicodeError):
                return None
            if not isinstance(cred, dict):
                return None
            try:
                exp = float(cred.get("expires_at") or 0)
            except (TypeError, ValueError, OverflowError):
                exp = 0
            if exp > time.time() and cred.get("access_token"):
                return cred   # 锁内重读已新鲜：别人刷好了，直接用
            new = _kimi_refresh_credentials(cred)
            if new is None:
                # 可能输给并发刷新（双方拿同一个旧 refresh_token，后动者 invalid_grant）：
                # 赢家已把新凭据写盘，重读一次兜底。
                try:
                    with open(path, encoding="utf-8") as f:
                        again = json.load(f)
                    exp2 = float(again.get("expires_at") or 0) if isinstance(again, dict) else 0
                    if exp2 > time.time() and again.get("access_token"):
                        return again
                except (OSError, ValueError, UnicodeError, TypeError):
                    pass
                return None
            try:
                _kimi_write_credentials(path, new)
            except OSError:
                pass   # 写回失败：新 token 仍供本次使用，下轮重试
            return new
    except (TimeoutError, OSError):
        return None


def kimi_usage() -> dict:
    """只读现有登录态；令牌过期时自刷新并原子写回（refresh_token 轮换，
    kimi-code 从磁盘重读，写回才不会把它登出；仅过期才刷新，平常零写）。
    登录流程绝不触碰——无 refresh_token 时报错并提示重新登录。"""
    try:
        with open(_kimi_credentials_path(), encoding="utf-8") as f:
            cred = json.load(f)
    except OSError:
        return {"error": "no_credentials", "detail": "无法读取 Kimi 凭据，请检查 KIMI_CODE_HOME 或打开 Kimi Code"}
    except (ValueError, UnicodeError):
        return {"error": "parse", "detail": "Kimi 凭据格式暂不可读，等待 Kimi Code 更新"}
    if not isinstance(cred, dict):
        return {"error": "parse", "detail": "Kimi 凭据格式异常，应为 JSON 对象"}
    tok = cred.get("access_token")
    if tok is not None and not isinstance(tok, str):
        return {"error": "parse", "detail": "Kimi access_token 格式异常"}
    if not tok or not tok.strip():
        return {"error": "no_token", "detail": "Kimi 凭据暂为空，等待 Kimi Code 更新登录态"}
    try:
        expires = float(cred.get("expires_at") or 0)
        if not math.isfinite(expires) or expires < 0:
            raise ValueError("invalid expiry")
    except (TypeError, ValueError, OverflowError):
        return {"error": "parse", "detail": "Kimi 凭据有效期格式异常"}
    if expires and expires <= time.time():
        # 已过期：Kimi Code 仅活跃时才刷新，闲置期干等会让面板长期「暂时不可用」。
        fresh = _kimi_fresh_credentials()
        fresh_tok = (fresh or {}).get("access_token")
        if fresh and isinstance(fresh_tok, str) and fresh_tok.strip():
            cred, tok = fresh, fresh_tok
        elif not cred.get("refresh_token"):
            return {"error": "expired",
                    "detail": "Kimi 访问令牌已过期且无 refresh_token，请运行 kimi login 重新登录"}
        else:
            return {"error": "expired",
                    "detail": "Kimi 访问令牌过期且自动刷新失败（refresh_token 可能已轮换），"
                              "请运行 kimi login 重新登录"}
    status, data = _http_json(
        f"{_kimi_api_base()}/usages",
        {"Authorization": f"Bearer {tok}", "Accept": "application/json"})
    if status == 401:
        # 磁盘 token 看着没过期却被拒（被别处轮换过）：走一次自愈，换新 token 重试一次。
        fresh = _kimi_fresh_credentials()
        fresh_tok = (fresh or {}).get("access_token")
        if fresh and isinstance(fresh_tok, str) and fresh_tok.strip() and fresh_tok != tok:
            tok = fresh_tok
            status, data = _http_json(
                f"{_kimi_api_base()}/usages",
                {"Authorization": f"Bearer {tok}", "Accept": "application/json"})
    if status == 401:
        return {"error": "expired", "detail": "Kimi 访问令牌已过期，请运行 kimi login 重新登录"}
    if status != 200 or not isinstance(data, dict):
        return {"error": f"http_{status}", "detail": f"Kimi usages 接口返回 {status}",
                "_retry_after": data.get("_retry_after") if isinstance(data, dict) else None}
    windows = {}
    usage = data.get("usage") or {}
    limits = data.get("limits") or []
    # 周期配额（周/计划周期，按 resetTime 命名）；used 缺省时用 limit-remaining 反推
    if isinstance(usage, dict):
        lim = usage.get("limit")
        used = usage.get("used")
        if used is None and usage.get("remaining") is not None:
            used = float(lim) - float(usage["remaining"])
        if lim is not None and used is not None:
            try:
                pct = float(used) / float(lim) * 100
            except (ValueError, ZeroDivisionError):
                pct = None
            windows["7d"] = {"pct": pct, "resets_at": _iso_ms(usage.get("resetTime")),
                             "used": used, "limit": lim, "unit": "requests"}
    # 5 小时窗口（limits[0].duration=300 分钟）；同上反推
    for lt in limits:
        detail = lt.get("detail") or {}
        win = lt.get("window") or {}
        if detail.get("limit") is None:
            continue
        lim = detail["limit"]
        used = detail.get("used")
        if used is None and detail.get("remaining") is not None:
            used = float(lim) - float(detail["remaining"])
        if used is None:
            continue
        try:
            pct = float(used) / float(lim) * 100
        except (ValueError, ZeroDivisionError):
            pct = None
        key = "5h" if str(win.get("duration")) == "300" else "7d"
        windows[key] = {"pct": pct, "resets_at": _iso_ms(detail.get("resetTime")),
                        "used": used, "limit": lim, "unit": "requests"}
    if not windows:
        return {"error": "no_windows", "detail": "Kimi 接口未返回可用配额"}
    user = data.get("user") or {}
    membership = user.get("membership") or {}
    return {"windows": windows,
            "plan": _KIMI_PLAN.get(membership.get("level"), membership.get("level") or ""),
            "unit": "requests"}


# ------------------------------------------------------------------ Codex ----
def _extra_bin_dirs() -> list:
    """图形化启动（.app / Finder）时 PATH 只有 /usr/bin:/bin…，Node 工具链找不到。
    补齐常见安装位置（codex 是 npm 全局脚本，shebang 为 #!/usr/bin/env node）。"""
    home = os.path.expanduser("~")
    dirs = [f"{home}/.npm-global/bin", f"{home}/.local/bin", f"{home}/.volta/bin",
            f"{home}/.bun/bin", f"{home}/Library/pnpm", f"{home}/.yarn/bin",
            "/opt/homebrew/bin", "/usr/local/bin"]
    # nvm：取最新一个版本的 bin
    try:
        nvm = os.path.join(home, ".nvm", "versions", "node")
        vers = sorted(os.listdir(nvm))
        if vers:
            dirs.insert(0, os.path.join(nvm, vers[-1], "bin"))
    except OSError:
        pass
    return [d for d in dirs if os.path.isdir(d)]


def _spawn_env() -> dict:
    env = dict(os.environ)
    extra = _extra_bin_dirs()
    env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    return env


def _find_codex() -> str | None:
    p = shutil.which("codex")
    if p:
        return p
    for d in _extra_bin_dirs():
        c = os.path.join(d, "codex")
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def _codex_rpc(bin_path: str) -> dict:
    """JSON-RPC over stdio 调 codex app-server，返回 account/rateLimits/read 的 result。"""
    env = _spawn_env()
    proc = subprocess.Popen(
        [bin_path, "-s", "read-only", "-a", "untrusted", "app-server"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, env=env)
    got_any_line = False
    try:
        def send(obj):
            proc.stdin.write(json.dumps(obj) + "\n")
            proc.stdin.flush()

        def recv(want_id: int, timeout: float = 15):
            nonlocal got_any_line
            end = time.time() + timeout
            while time.time() < end:
                if proc.poll() is not None:  # 进程提前死掉（如 node 没找到）
                    err = ""
                    try:
                        err = (proc.stderr.read() or "")[:200].strip()
                    except Exception:  # noqa: BLE001
                        pass
                    raise RuntimeError(
                        f"codex 进程提前退出(code={proc.returncode})：{err or '无输出'}")
                r, _, _ = select.select([proc.stdout], [], [], 0.5)
                if not r:
                    continue
                line = proc.stdout.readline()
                if not line:
                    break
                got_any_line = True
                try:
                    env_msg = json.loads(line)
                except ValueError:
                    continue
                if env_msg.get("id") != want_id:
                    continue
                if env_msg.get("error"):
                    raise RuntimeError(env_msg["error"].get("message", "rpc error"))
                return env_msg.get("result")
            raise TimeoutError("codex app-server 无响应")

        send({"id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "tokentracker", "version": "0.1"}}})
        recv(1)
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "account/rateLimits/read", "params": {}})
        return recv(2) or {}
    except Exception as e:  # noqa: BLE001
        _codex_debug(e, bin_path, env, proc, got_any_line)
        raise
    finally:
        proc.kill()
        proc.wait()


def _codex_debug(err, bin_path, env, proc, got_any_line):
    """失败诊断落盘（不影响主流程）：打包 App 里出问题时可查 ~/.tokentracker/codex_debug.log。"""
    try:
        alive = proc.poll() is None
        lines = [f"[{datetime.now().isoformat(timespec='seconds')}] {type(err).__name__}: {err}",
                 f"  bin={bin_path}",
                 f"  proc_alive={alive} got_any_line={got_any_line}",
                 f"  PATH={env.get('PATH')}"]
        if alive:
            r, _, _ = select.select([proc.stderr], [], [], 0.2)
            if r:
                lines.append("  stderr: " + (proc.stderr.readline() or "").strip()[:200])
        p = os.path.join(os.path.expanduser("~"), ".tokentracker", "codex_debug.log")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    except Exception:  # noqa: BLE001
        pass


def _codex_auth_path() -> str:
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    return os.path.join(home, "auth.json")


def _codex_credentials():
    """读 ~/.codex/auth.json → (tokens_dict, write_back(tokens)->None)。"""
    path = _codex_auth_path()
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None, None
    tokens = data.get("tokens")
    if not isinstance(tokens, dict) or not tokens.get("access_token"):
        return None, None

    def save(new_tokens, _path=path, _data=data):
        try:
            _data["tokens"] = new_tokens
            _data["last_refresh"] = datetime.now().astimezone().isoformat()
            tmp = _path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(_data, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, _path)
        except OSError:
            pass
    return tokens, save


def _codex_refresh(refresh_token: str) -> dict:
    """refresh_token 换新 token（与 Codex CLI 同一 public client）。"""
    body = json.dumps({"grant_type": "refresh_token", "refresh_token": refresh_token,
                       "client_id": _CODEX_CLIENT_ID}).encode()
    status, data = _http_json(
        _CODEX_TOKEN_URL, {"Content-Type": "application/json"}, body=body, method="POST")
    if status != 200 or not isinstance(data, dict) or not data.get("access_token"):
        raise RuntimeError(f"HTTP {status}")
    return data


def _codex_usage_wham() -> dict:
    """GET chatgpt.com/backend-api/wham/usage（CodexBar/headroom 同款端点）。

    比 spawn `codex app-server` 稳：不依赖 CLI 版本协议，实测 codex-cli 0.150.1
    上 app-server RPC 已挂而本端点正常。401 时用 refresh_token 换新并原子写回
    auth.json（refresh token 轮换，不写回会把 Codex CLI 登出）。
    """
    tokens, save = _codex_credentials()
    if not tokens:
        return {"error": "no_credentials", "detail": "未找到 ~/.codex/auth.json 登录态"}

    def _call(tok):
        headers = {"Authorization": f"Bearer {tok}", "Accept": "application/json",
                   "User-Agent": "codex_cli_rs/0.150.1"}
        if tokens.get("account_id"):
            headers["ChatGPT-Account-Id"] = tokens["account_id"]
        return _http_json(_CODEX_WHAM_URL, headers)

    status, data = _call(tokens["access_token"])
    if status == 401 and tokens.get("refresh_token"):
        try:
            d = _codex_refresh(tokens["refresh_token"])
        except Exception as e:  # noqa: BLE001
            return {"error": "refresh_failed",
                    "detail": f"Codex token 刷新失败({e})，请运行 codex 重新登录"}
        tokens["access_token"] = d["access_token"]
        if d.get("refresh_token"):
            tokens["refresh_token"] = d["refresh_token"]
        if d.get("id_token"):
            tokens["id_token"] = d["id_token"]
        if save:
            save(tokens)
        status, data = _call(tokens["access_token"])
    if status != 200 or not isinstance(data, dict):
        return {"error": f"http_{status}", "detail": f"wham/usage 返回 {status}",
                "_retry_after": data.get("_retry_after") if isinstance(data, dict) else None}
    rl = data.get("rate_limit") or {}
    windows = {}
    for w in (rl.get("primary_window"), rl.get("secondary_window")):
        if not isinstance(w, dict):
            continue
        key = _CODEX_WIN_BY_SEC.get(w.get("limit_window_seconds"))
        pct = w.get("used_percent")
        if key and pct is not None:
            resets = w.get("reset_at")
            windows[key] = {"pct": float(pct),
                            "resets_at": int(resets * 1000) if resets and resets < 1e12 else resets}
    if not windows:
        return {"error": "no_windows", "detail": "wham/usage 无窗口数据"}
    credits = data.get("credits") or {}
    return {"windows": windows, "plan": data.get("plan_type") or "", "_via": "wham",
            "extra": {"balance": credits.get("balance"),
                      "unlimited": credits.get("unlimited"),
                      "spend_reached": (data.get("spend_control") or {}).get("reached")}}


def codex_usage() -> dict:
    """wham/usage HTTP 端点为主，app-server RPC 兑底（结果带 _via 标明走的那条路）。"""
    r = _codex_usage_wham()
    if not r.get("error") or r.get("error") == "http_429":
        return r
    wham_err = r
    r = _codex_usage_rpc()
    if not r.get("error"):
        return r
    # 两条路都挂：报主路错误，附上兑底原因
    return {"error": wham_err.get("error"),
            "detail": f"{wham_err.get('detail')}；RPC 兑底也失败：{r.get('detail')}",
            "_retry_after": wham_err.get("_retry_after")}


def _codex_usage_rpc() -> dict:
    """codex app-server RPC → {windows:{5h?,7d}, plan, credits}（兑底路径）"""
    bin_path = _find_codex()
    if not bin_path:
        return {"error": "no_binary", "detail": "未找到 codex 命令"}
    try:
        data = _codex_rpc(bin_path)
    except Exception as e:  # noqa: BLE001
        return {"error": "rpc_failed", "detail": f"Codex RPC 失败：{e}（请确认已登录 codex）"}
    rl = data.get("rateLimits") or {}
    if not rl:
        return {"error": "no_limits", "detail": "Codex 未返回限额数据"}
    windows = {}
    for w in (rl.get("primary"), rl.get("secondary")):
        if not isinstance(w, dict):
            continue
        key = _CODEX_WIN_BY_MIN.get(w.get("windowDurationMins"))
        pct = w.get("usedPercent")
        if key and pct is not None:
            resets = w.get("resetsAt")
            windows[key] = {"pct": float(pct),
                            "resets_at": int(resets * 1000) if resets and resets < 1e12 else resets}
    if not windows:
        return {"error": "no_windows", "detail": "Codex 无窗口数据"}
    credits = rl.get("credits") or {}
    return {"windows": windows,
            "plan": rl.get("planType") or "", "_via": "rpc",
            "extra": {"balance": credits.get("balance"),
                      "unlimited": credits.get("unlimited"),
                      "spend_reached": rl.get("spendControlReached")}}


# --------------------------------------------------------------------- Go ----
def _go_key() -> str | None:
    """解析 OpenCode Go API Key：环境变量 → opencode auth.json（与 DSH cost-meter 插件同款顺序）。"""
    for name in ("OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"):
        v = os.environ.get(name, "").strip()
        if v:
            return v
    home = os.path.expanduser("~")
    cands = [f"{home}/.local/share/opencode/auth.json", f"{home}/.config/opencode/auth.json"]
    for p in cands:
        try:
            data = json.load(open(p, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        key = (data.get("opencode-go") or {}).get("key")
        if isinstance(key, str) and key:
            return key
    return None


def go_usage() -> dict:
    """GET opencode.ai/zen/go/v1/usage → {windows:{5h,7d,month}, plan}

    参考：DSH cost-meter 插件实现（lib/index.js queryGoQuota）——
    必须带浏览器 User-Agent（否则 Cloudflare error 1010 拦截），
    间歇性连接重置需自动重试，401/403 = 无订阅/Key 无效。
    """
    key = _go_key()
    if not key:
        return {"error": "no_key",
                "detail": "未找到 OpenCode Go API Key：opencode 登录后（auth.json）或用 OPENCODE_GO_API_KEY 环境变量"}
    status, data = 0, {}
    last_err = ""
    for _ in range(3):
        status, data = _http_json(
            _GO_QUOTA_URL,
            {"Authorization": f"Bearer {key}",
             "User-Agent": _GO_UA,
             "Accept": "application/json, text/plain, */*",
             "Connection": "close"})
        if status != 0:
            break
        last_err = data.get("error", "connection reset")
        time.sleep(2)
    if status == 401 or status == 403:
        return {"error": "no_sub", "detail": "没有生效的 OpenCode Go 订阅，或 API Key 无效"}
    if status != 200:
        return {"error": f"http_{status}", "detail": f"Go 额度接口返回 {status}（{last_err}）",
                "_retry_after": data.get("_retry_after") if isinstance(data, dict) else None}
    usage = data.get("usage")
    if not isinstance(usage, dict):
        return {"error": "no_usage", "detail": "Go 额度响应缺少 usage 字段"}
    windows = {}
    for src, key in (("rolling", "5h"), ("weekly", "7d"), ("monthly", "month")):
        w = usage.get(src)
        if isinstance(w, dict) and w.get("percent") is not None:
            windows[key] = {"pct": float(w["percent"]), "resets_at": _iso_ms(w.get("resetsAt"))}
    if not windows:
        return {"error": "no_windows", "detail": "Go 额度响应无可用窗口"}
    return {"windows": windows, "plan": "OpenCode Go"}
