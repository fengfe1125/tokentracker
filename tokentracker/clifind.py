"""CLI 可执行文件解析：打包 App 的 PATH 极简化（launchd 只给 /usr/bin 等），
而用户级 CLI 装在 ~/.local/bin、~/.npm-global/bin、~/.kimi-code/bin 等目录。

三级兜底，进程内缓存：
  ① shutil.which（进程 PATH）
  ② 登录 shell 探测 zsh -lic 'command -v <name>'（与用户 Terminal 行为一致）
  ③ 常见安装目录直接探测
返回绝对路径；命令行里用绝对路径，App 端与 Terminal 端都不再依赖 PATH。
"""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess

_COMMON_DIRS = (
    "~/.local/bin", "~/.npm-global/bin", "~/.kimi-code/bin", "~/.opencode/bin",
    "~/.volta/bin", "~/.bun/bin", "~/.deno/bin", "~/.asdf/shims", "~/.cargo/bin",
    "~/.local/share/mise/shims", "/opt/homebrew/bin", "/usr/local/bin",
)

_cache: dict[str, str | None] = {}


def _probe_login_shell(name: str, run=subprocess.run) -> str | None:
    """登录 shell 探测：拿到用户 .zprofile/.zshrc 里的真实 PATH。"""
    if os.name != "posix" or not os.path.exists("/bin/zsh"):
        return None
    try:
        r = run(["/bin/zsh", "-lic", f"command -v {shlex.quote(name)}"],
                capture_output=True, text=True, timeout=4)
        out = (r.stdout or "").strip().splitlines()
        # 取最后一行：rc 文件可能回显提示语；command -v 输出绝对路径
        for line in reversed(out):
            line = line.strip()
            if line.startswith("/") and os.path.isfile(line):
                return line
    except Exception:
        pass
    return None


def _probe_common_dirs(name: str) -> str | None:
    for d in _COMMON_DIRS:
        path = os.path.join(os.path.expanduser(d), name)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def resolve(name: str, *, run=subprocess.run) -> str | None:
    """解析 CLI 绝对路径；找不到返回 None。结果进程内缓存。"""
    if name in _cache:
        return _cache[name]
    path = shutil.which(name)
    if not path:
        path = _probe_login_shell(name, run=run)
    if not path:
        path = _probe_common_dirs(name)
    _cache[name] = path
    return path


def clear_cache() -> None:
    _cache.clear()
