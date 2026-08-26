"""官方订阅配额抓取（只读，本地发起，凭据只在本进程内存中使用，绝不落盘）。

参考实现（GitHub 调研结论）：
- Claude：GET https://api.anthropic.com/api/oauth/usage
  （CodexBar docs/claude.md；Bearer 用凭据里的 accessToken；
   字段是 utilization（0-100）+ resets_at（ISO）；头 anthropic-beta: oauth-2025-04-20）
  凭据解析顺序：macOS 钥匙串「Claude Code-credentials」→ ~/.claude/.credentials.json
  （macOS 上 Claude Code 把登录态写在钥匙串，credentials.json 常是过期残留——
   只读文件会导致拿到过期 token、接口 429，表现为「一直监测不出来」）。
  accessToken 过期时自动用 refreshToken 换新的并写回来源（轮换刷新令牌必须回写，
  否则 Claude Code 本体下次刷新会失败被登出）。
- Kimi：先 POST https://auth.kimi.com/api/oauth/token 用 refresh_token 换新 access token
  （kimi-code 源码 packages/oauth/src/oauth.ts：client_id=17e5f671-...，15 分钟实效），
  再 GET https://api.kimi.com/coding/v1/usages ---官方 CLI 真正使用的接口
  （CodexBar docs/kimi.md + parseCodeAPIUsage），返回请求次数的 5 小时窗口与周期配额。
- Codex：spawn `codex -s read-only -a untrusted app-server`，JSON-RPC over stdio
  （claude-usage-rs/src/menubar.rs：initialize → initialized → account/rateLimits/read），
  返回 primary/secondary 窗口 usedPercent + windowDurationMins(300=5h,10080=周) + resetsAt(秒)
  + planType + credits 余额。无需登录：直接复用本机已登录的 Codex CLI。

凭据过期/无效时返回 {"error": ...}，由上层降级为本地窗口估算，绝不阻塞。
"""
from __future__ import annotations

import json
import os
import re
import select
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

_KIMI_CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098"
_CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
_CLAUDE_UA = "claude-cli/2.0.0 (external, cli)"
_CLAUDE_TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
_CLAUDE_KC_SERVICE = "Claude Code-credentials"
_CLAUDE_PLAN = {"pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"}
_KIMI_PLAN = {"LEVEL_BASIC": "基础版", "LEVEL_INTERMEDIATE": "中级版", "LEVEL_PREMIUM": "高级版",
              "LEVEL_UNLIMITED": "无限版", "LEVEL_PRO": "专业版"}
_GO_QUOTA_URL = "https://opencode.ai/zen/go/v1/usage"
_GO_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
_CODEX_WIN_BY_MIN = {300: "5h", 10_080: "7d", 43_200: "month", 44_640: "month"}
_TTL_OK = 120     # 成功结果缓存
_TTL_ERR = 120    # 失败退避（限流接口不宜高频重试）
_STALE_MAX = 24 * 3600   # 磁盘兜底缓存最长可用 24h
_cache: dict = {}


def _disk_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".tokentracker", "official_cache.json")


def _disk_load(key: str):
    """读磁盘缓存的成功结果 → (ts, data) | (None, None)。"""
    try:
        with open(_disk_path(), encoding="utf-8") as f:
            store = json.load(f)
        ts, data = store[key]
        if time.time() - ts > _STALE_MAX:
            return None, None
        return ts, data
    except (OSError, ValueError, KeyError, TypeError):
        return None, None


def _disk_store(key: str, ts: float, data: dict):
    """成功结果落盘（跨进程共享，限流时互为兜底）；只存配额数字，不含凭据。"""
    try:
        store = {}
        try:
            with open(_disk_path(), encoding="utf-8") as f:
                store = json.load(f)
        except (OSError, ValueError):
            pass
        store[key] = [ts, data]
        os.makedirs(os.path.dirname(_disk_path()), exist_ok=True)
        tmp = _disk_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(store, f)
        os.replace(tmp, _disk_path())
    except OSError:
        pass


def _cached(key: str, fn):
    """stale-if-error：成功写内存+磁盘；失败回退最近一次成功结果并标记 _stale_min。"""
    now = time.time()
    hit = _cache.get(key)
    if hit:
        ttl = _TTL_OK if hit[1].get("_ok") else _cache_ttl.get(key, _TTL_ERR)
        if now - hit[0] < ttl:
            return hit[1]
    try:
        data = fn()
        data = dict(data, _ok=not data.get("error"))
    except Exception as e:  # noqa: BLE001
        data = {"error": "network", "detail": str(e), "_ok": False}
    if data.get("_ok"):
        _cache[key] = (now, data)
        _disk_store(key, now, data)
        return data
    stale_ts, stale = (hit if hit and hit[1].get("_ok") else (None, None))
    if stale is None:
        stale_ts, stale = _disk_load(key)
    if stale is not None:
        out = dict(stale, _stale_min=max(1, int((now - stale_ts) / 60)),
                   _err=data.get("detail") or data.get("error") or "")
        return out
    # 失败入缓存：接口返回 Retry-After（如 429）时按其时长退避，避免把限流越刷越长
    _cache_ttl[key] = max(_TTL_ERR, min(int(data.get("_retry_after") or 0), 24 * 3600))
    _cache[key] = (now, data)
    return data


_cache_ttl: dict = {}


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
        if isinstance(data, dict):
            try:
                ra = int(e.headers.get("Retry-After") or 0)
            except (TypeError, ValueError):
                ra = 0
            if ra > 0:
                data["_retry_after"] = ra
        return e.code, data
    except Exception as e:  # noqa: BLE001
        return 0, {"error": str(e)}


def _pct(v) -> float | None:
    if v is None:
        return None
    p = float(v)
    return p * 100 if 0 < p <= 1 else p


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


def _claude_credentials():
    """解析 Claude 凭据 → (oauth_dict, write_back(oauth)->None)。

    钥匙串与 ~/.claude/.credentials.json 两处都试，挑 accessToken 最新的一份；
    write_back 会把刷新后的 oauth 写回它原来的来源。
    """
    cands = []
    kc = _kc_read()
    if kc:
        def kc_save(oauth, _kc=kc):
            _kc_write(dict(_kc, claudeAiOauth=oauth))
        cands.append((kc["claudeAiOauth"], kc_save))
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
            cands.append((cred["claudeAiOauth"], file_save))
    except (OSError, ValueError):
        pass
    if not cands:
        return None, None
    cands.sort(key=lambda c: c[0].get("expiresAt") or 0, reverse=True)
    return cands[0]


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


def claude_oauth_usage() -> dict:
    """GET api.anthropic.com/api/oauth/usage → {windows:{5h,7d,..}, plan}"""
    oauth, save = _claude_credentials()
    if not oauth:
        return {"error": "no_credentials",
                "detail": "未找到 Claude 登录态（钥匙串 / ~/.claude/.credentials.json）"}
    tok = oauth.get("accessToken")
    if not tok:
        return {"error": "no_token", "detail": "凭据里没有 accessToken（未登录）"}
    exp = oauth.get("expiresAt") or 0
    if exp and time.time() * 1000 > exp - 60_000:  # 已过期或 1 分钟内过期 → 自动刷新
        rt = oauth.get("refreshToken")
        if not rt:
            return {"error": "expired", "detail": "Claude 登录态已过期，请在 Claude Code 重新登录"}
        try:
            d = _claude_refresh(rt)
        except Exception as e:  # noqa: BLE001
            return {"error": "refresh_failed",
                    "detail": f"Claude token 刷新失败({e})，请在 Claude Code 重新登录"}
        # 刷新令牌会轮换：必须写回来源，否则 Claude Code 本体下次刷新会被登出
        oauth["accessToken"] = d["access_token"]
        if d.get("refresh_token"):
            oauth["refreshToken"] = d["refresh_token"]
        oauth["expiresAt"] = int(time.time() * 1000) + int(d.get("expires_in", 28800)) * 1000
        if save:
            save(oauth)
        tok = oauth["accessToken"]
    status, data = _http_json(
        "https://api.anthropic.com/api/oauth/usage",
        {"Authorization": f"Bearer {tok}",
         "anthropic-beta": "oauth-2025-04-20",
         "Content-Type": "application/json"},
    )
    if status == 401:
        return {"error": "expired", "detail": "Claude access token 失效，请在 Claude Code 重新登录"}
    if status == 429:
        return {"error": "http_429", "detail": "Claude usage 接口限流，稍后自动重试",
                "_retry_after": data.get("_retry_after") if isinstance(data, dict) else None}
    if status != 200:
        return {"error": f"http_{status}", "detail": f"Claude usage 接口返回 {status}"}
    if not isinstance(data, dict):
        return {"error": "parse", "detail": "接口响应格式异常"}
    windows = {}
    for key, label in (("five_hour", "5h"), ("seven_day", "7d"),
                       ("seven_day_sonnet", "7d_sonnet"), ("seven_day_opus", "7d_opus")):
        w = data.get(key)
        if isinstance(w, dict):
            pct = _pct(w.get("utilization") if w.get("utilization") is not None
                       else w.get("used_percentage"))
            if pct is not None:
                windows[label] = {"pct": pct, "resets_at": _iso_ms(w.get("resets_at"))}
    if not windows:
        return {"error": "no_windows", "detail": "接口未返回窗口数据"}
    extra = data.get("extra_usage") or {}
    plan = (data.get("plan") or data.get("rate_limit_tier")
            or _CLAUDE_PLAN.get(str(oauth.get("subscriptionType") or "").lower())
            or oauth.get("subscriptionType") or "")
    return {"windows": windows,
            "plan": plan,
            "extra": {"used_credits": extra.get("used_credits"),
                      "monthly_limit": extra.get("monthly_limit"),
                      "disabled": extra.get("disabled_reason")}}


# ------------------------------------------------------------------ Kimi ----
def _kimi_refresh(refresh_token: str) -> str:
    body = urllib.parse.urlencode({
        "client_id": _KIMI_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    }).encode()
    status, data = _http_json(
        "https://auth.kimi.com/api/oauth/token",
        {"Content-Type": "application/x-www-form-urlencoded"}, body=body, method="POST")
    tok = data.get("access_token") if isinstance(data, dict) else None
    if status != 200 or not tok:
        raise RuntimeError(f"token 刷新失败(HTTP {status})")
    return tok


def kimi_usage() -> dict:
    """刷新 → GET api.kimi.com/coding/v1/usages → {windows:{5h,7d}, plan, unit}"""
    try:
        with open(os.path.expanduser("~/.kimi-code/credentials/kimi-code.json"), encoding="utf-8") as f:
            cred = json.load(f)
    except OSError:
        return {"error": "no_credentials", "detail": "未找到 ~/.kimi-code/credentials/kimi-code.json"}
    rt = cred.get("refresh_token")
    if not rt:
        return {"error": "no_token", "detail": "kimi-code.json 无 refresh_token，请在 Kimi Code 重新登录"}
    try:
        tok = _kimi_refresh(rt)
    except Exception as e:  # noqa: BLE001
        return {"error": "refresh_failed", "detail": f"Kimi token 刷新失败({e})，请在 Kimi Code 重新登录"}
    status, data = _http_json(
        "https://api.kimi.com/coding/v1/usages",
        {"Authorization": f"Bearer {tok}", "Accept": "application/json"})
    if status != 200 or not isinstance(data, dict):
        return {"error": f"http_{status}", "detail": f"Kimi usages 接口返回 {status}"}
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


def codex_usage() -> dict:
    """codex app-server RPC → {windows:{5h?,7d}, plan, credits}"""
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
            "plan": rl.get("planType") or "",
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
        return {"error": f"http_{status}", "detail": f"Go 额度接口返回 {status}（{last_err}）"}
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