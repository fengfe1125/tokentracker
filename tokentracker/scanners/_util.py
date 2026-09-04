"""扫描器公共小工具。"""
from __future__ import annotations

import json
import os
import shutil
import subprocess


def _find_tool(name: str) -> str:
    """解析外部命令：PATH → 常见安装目录。.app 图形化启动时 PATH 极简，
    直接写 "zstd" 会 FileNotFoundError，这里兜底绝对路径。"""
    p = shutil.which(name)
    if p:
        return p
    home = os.path.expanduser("~")
    for d in ("/opt/homebrew/bin", "/usr/local/bin",
              f"{home}/.local/bin", f"{home}/.npm-global/bin"):
        c = os.path.join(d, name)
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return name


_ZSTD = _find_tool("zstd")


def expand(path: str) -> str:
    return os.path.expanduser(os.path.expandvars(path))


def stat_key(path: str) -> dict:
    st = os.stat(path)
    # Preserve sub-millisecond writes and detect a replaced file of the same size.
    return {"m": st.st_mtime_ns, "s": st.st_size, "i": st.st_ino, "d": st.st_dev}


def changed(cursor: dict, path: str) -> bool:
    try:
        return cursor.get(path) != stat_key(path)
    except OSError:
        return True


def iter_jsonl(path: str):
    """yield (line_no, obj)。解析失败的行跳过。"""
    with open(path, encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield i, json.loads(line)
            except ValueError:
                continue


def iter_zstd_jsonl(path: str):
    """zstd 压缩 JSONL（DSH），通过系统 zstd 二进制解压。"""
    proc = subprocess.Popen(
        [_ZSTD, "-d", "-c", path],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, errors="replace",
    )
    try:
        for i, line in enumerate(proc.stdout, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield i, json.loads(line)
            except ValueError:
                continue
    finally:
        proc.stdout.close()
        proc.wait()


def sqlite_ro(path: str):
    """只读打开 SQLite（工具可能正在写库）。"""
    import sqlite3
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def fmt_ms(ms: int) -> str:
    import datetime
    return datetime.datetime.fromtimestamp(ms / 1000).isoformat(timespec="seconds")


# ------------------------------------------------------------ 会话标题 ----
_CONTEXT_PREFIXES = ("# AGENTS.md", "<INSTRUCTIONS>", "<environment_context>",
                     "<system-reminder>", "Caveat:", "<command-", "<local-command",
                     "<recommended_plugins", "<user_instructions",
                     "## Referenced ChatGPT conversation",
                     "The following is the Codex agent history")


def _content_text(content) -> str:
    """消息 content：纯字符串或块列表（claude text / codex input_text）。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(str(b.get("text", "")) for b in content
                        if isinstance(b, dict) and b.get("type") in ("text", "input_text"))
    return ""


def user_text(obj) -> str:
    """从 JSONL 行提取首个真实用户消息（跳过 AGENTS.md/环境上下文等注入）。

    覆盖 claude(type=user)、pi(type=message role=user)、codex(response_item
    role=user)。无匹配返回 ""。
    """
    text = ""
    kind = obj.get("type") if isinstance(obj, dict) else None
    if kind in ("user", "message"):
        msg = obj.get("message") or {}
        if isinstance(msg, dict) and msg.get("role") == "user":
            text = _content_text(msg.get("content"))
    elif kind == "response_item":
        payload = obj.get("payload") or {}
        if isinstance(payload, dict) and payload.get("role") == "user":
            text = _content_text(payload.get("content"))
    text = " ".join((text or "").split())
    if not text or text.startswith(_CONTEXT_PREFIXES):
        return ""
    return text[:120]
