"""会话恢复：按工具生成 resume 命令、解析工作目录、在终端中打开。

命令矩阵为本机实测（docs/session-resume-plan.md）；DSH 无 CLI，不支持恢复。
安全约定：所有进 shell / AppleScript 的片段一律转义——session_id 与 project
虽来自本地库，仍按不可信处理。本模块无 AppKit 依赖，tests 直接单测。
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess

# 工具 → resume 命令前缀（id 追加在最后）
RESUME_PREFIX = {
    "claude": ("claude", "--resume"),
    "codex": ("codex", "resume"),
    "kimi": ("kimi", "--session"),
    "opencode": ("opencode", "--session"),
    "pi": ("pi", "--session"),
    "hermes": ("hermes", "--resume"),
}

# 终端偏好（settings 键 terminal_app）→ 应用名 / 打开方式
TERMINAL_APPS = ("auto", "terminal", "iterm", "wezterm", "ghostty")
_AUTO_ORDER = ("iterm", "wezterm", "ghostty", "terminal")   # Terminal 保底必在
_APP_NAMES = {"terminal": "Terminal", "iterm": "iTerm",
              "wezterm": "WezTerm", "ghostty": "Ghostty"}


def resume_argv(tool: str, session_id: str) -> list[str] | None:
    """工具不支持或无会话 ID → None。"""
    prefix = RESUME_PREFIX.get(tool)
    if not prefix or not session_id:
        return None
    return [*prefix, session_id]


def cli_missing(argv: list[str]) -> str | None:
    """CLI 不在 PATH 时返回可执行文件名，否则 None。"""
    return argv[0] if shutil.which(argv[0]) is None else None


def _claude_cwd_from_jsonl(session_id: str, root: str | None = None) -> str | None:
    """claude 的 project 是 slug（含连字符的路径不可逆），jsonl 首行的 cwd 才可靠。"""
    root = root or os.path.join(os.path.expanduser("~"), ".claude", "projects")
    try:
        for proj in os.listdir(root):
            path = os.path.join(root, proj, session_id + ".jsonl")
            if not os.path.isfile(path):
                continue
            with open(path, encoding="utf-8") as f:
                for line in f:
                    try:
                        cwd = json.loads(line).get("cwd")
                    except ValueError:
                        continue
                    if isinstance(cwd, str) and cwd:
                        return cwd
    except OSError:
        pass
    return None


def resolve_cwd(tool: str, session_id: str, project: str = "",
                claude_root: str | None = None) -> str | None:
    """恢复会话前 cd 的目录；解析不到或目录已不存在 → None。"""
    candidates = []
    if tool == "claude":
        cwd = _claude_cwd_from_jsonl(session_id, claude_root)
        if cwd:
            candidates.append(cwd)
        if project.startswith("-"):   # slug 启发式兜底（与 open_in_finder 同款）
            candidates.append("/" + project[1:].replace("-", "/"))
    if project.startswith("/"):
        candidates.append(project)
    for c in candidates:
        if os.path.isdir(c):
            return c
    return None


def shell_line(tool: str, session_id: str, project: str = "",
               cwd_override: str | None = None,
               claude_root: str | None = None) -> tuple[str | None, str | None]:
    """返回 (终端里执行的整行, 不可用原因)。每段 shlex.quote；目录存在才加 cd。"""
    argv = resume_argv(tool, session_id)
    if argv is None:
        reason = "缺少会话 ID" if tool in RESUME_PREFIX else f"{tool} 不支持恢复会话"
        return None, reason
    missing = cli_missing(argv)
    if missing:
        return None, f"未找到命令 {missing}（未安装或不在 PATH）"
    cmd = " ".join(shlex.quote(a) for a in argv)
    cwd = None
    if cwd_override and os.path.isdir(cwd_override):
        cwd = cwd_override
    elif not cwd_override:
        cwd = resolve_cwd(tool, session_id, project, claude_root)
    if cwd:
        cmd = f"cd {shlex.quote(cwd)} && {cmd}"
    return cmd, None


def info(tool: str, session_id: str, project: str = "") -> dict:
    """前端按钮可用性 + 展示用命令。ok=False 时 reason 为人类可读原因。"""
    argv = resume_argv(tool, session_id or "")
    if argv is None:
        reason = "缺少会话 ID" if tool in RESUME_PREFIX else "该工具不支持恢复会话"
        return {"ok": False, "reason": reason, "command": "", "cwd": "", "cwd_missing": False}
    cmd, reason = shell_line(tool, session_id, project or "")
    if cmd is None:
        return {"ok": False, "reason": reason, "command": "", "cwd": "", "cwd_missing": False}
    cwd = resolve_cwd(tool, session_id, project or "")
    return {"ok": True, "reason": "", "command": cmd,
            "cwd": cwd or "", "cwd_missing": cwd is None}


# ------------------------------------------------------------ 终端打开 ----
def _app_installed(app_name: str) -> bool:
    return (os.path.isdir(f"/Applications/{app_name}.app") or
            os.path.isdir(os.path.expanduser(f"~/Applications/{app_name}.app")))


def pick_terminal(pref: str = "auto") -> str:
    """显式偏好但应用已卸载时回退 Terminal。"""
    if pref and pref != "auto":
        return pref if _app_installed(_APP_NAMES.get(pref, "")) else "terminal"
    for key in _AUTO_ORDER:
        if _app_installed(_APP_NAMES[key]):
            return key
    return "terminal"


def _applescript_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def open_terminal(cmd: str, pref: str = "auto", run=subprocess.run) -> bool:
    """按偏好在终端新窗口执行 cmd（cmd 必须是已 quote 的整行）。失败返回 False。"""
    key = pick_terminal(pref)
    try:
        if key in ("terminal", "iterm"):
            app = _APP_NAMES[key]
            if key == "terminal":
                body = f'activate\n  do script "{_applescript_escape(cmd)}"'
            else:
                body = ('create window with default profile command '
                        f'"{_applescript_escape(cmd)}"')
            run(["osascript", "-e", f'tell application "{app}"\n  {body}\nend tell'],
                check=True, capture_output=True, timeout=15)
        elif key == "wezterm":
            run(["open", "-na", "WezTerm", "--args", "start", "--always-new-process",
                 "--", "/bin/bash", "-lc", cmd],
                check=True, capture_output=True, timeout=15)
        else:  # ghostty
            run(["open", "-na", "Ghostty", "--args", "-e", "/bin/bash", "-lc", cmd],
                check=True, capture_output=True, timeout=15)
        return True
    except Exception:
        return False


def copy_to_clipboard(text: str, run=subprocess.run) -> bool:
    try:
        run(["pbcopy"], input=text.encode("utf-8"),
            check=True, capture_output=True, timeout=5)
        return True
    except Exception:
        return False
