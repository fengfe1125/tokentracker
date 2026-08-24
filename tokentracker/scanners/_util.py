"""扫描器公共小工具。"""
from __future__ import annotations

import json
import os
import subprocess


def expand(path: str) -> str:
    return os.path.expanduser(os.path.expandvars(path))


def stat_key(path: str) -> dict:
    st = os.stat(path)
    return {"m": round(st.st_mtime, 3), "s": st.st_size}


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
        ["zstd", "-d", "-c", path],
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