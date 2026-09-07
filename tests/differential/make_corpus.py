#!/usr/bin/env python3
"""生成差分测试语料库 tests/differential/corpus/（纯虚构数据，可重复生成）。

覆盖 7 个工具的「正常路径」数据形状（每工具 1–2 个会话、含缓存 token、
含 priced/unpriced 模型、聚合工具的官方成本字段）。边界场景（计数器重置、
截断增量、坏行等）由 Phase 1 移植 unittest 时逐条覆盖，不进语料。

产物全部确定性：固定时间戳、固定主键。opencode/hermes 的观察时间戳由
export_python.py 固定时钟兜底（本脚本不写时间相关字段）。

用法：python3 tests/differential/make_corpus.py [输出目录]
依赖：系统 zstd 命令（DSH 压缩事件流）。
"""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# 固定到 /tmp 下与机器无关的路径：expected_python.json 里嵌着绝对路径
# （codex src_key、快照 source_scope），仓库内路径会让基线绑定特定机器。
DEFAULT_OUT = "/tmp/tt_diff_corpus"

# 固定时间戳（ms），与真实数据无关
T1 = 1787619600000          # 2026-08-25T01:00:00Z
T2 = 1787623200000          # 2026-08-25T02:00:00Z
ISO1 = "2026-08-25T01:00:00Z"
ISO2 = "2026-08-25T02:00:00Z"


def write_jsonl(path, objects):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for obj in objects:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")


# ------------------------------------------------------------------ claude ----
def make_claude(base):
    root = os.path.join(base, "claude", "projects")
    write_jsonl(os.path.join(root, "webapp", "s-claude-1.jsonl"), [
        {"type": "user", "timestamp": ISO1,
         "message": {"role": "user", "content": "帮我修一下登录页样式"}},
        {"type": "assistant", "timestamp": ISO1,
         "message": {"id": "msg_1", "model": "claude-sonnet-4-5", "role": "assistant",
                     "usage": {"input_tokens": 1200, "output_tokens": 300,
                               "cache_read_input_tokens": 4000,
                               "cache_creation_input_tokens": 800}}},
        {"type": "assistant", "timestamp": ISO2,
         "message": {"id": "msg_2", "model": "claude-sonnet-4-5", "role": "assistant",
                     "usage": {"input_tokens": 900, "output_tokens": 150,
                               "cache_read_input_tokens": 0,
                               "cache_creation_input_tokens": 0}}},
        {"type": "assistant", "timestamp": ISO2,      # 零用量：不产生事件
         "message": {"id": "msg_3", "model": "claude-sonnet-4-5", "role": "assistant",
                     "usage": {"input_tokens": 0, "output_tokens": 0}}},
    ])


# ------------------------------------------------------------------- codex ----
def make_codex(base):
    root = os.path.join(base, "codex")
    # rollout JSONL：session_meta → turn_context → 累计 token_count 差量 →
    # 重复通知（last_token_usage 兜底去重）→ task_complete
    write_jsonl(os.path.join(root, "sessions", "2026", "08", "25", "rollout-1.jsonl"), [
        {"type": "session_meta", "timestamp": ISO1,
         "payload": {"id": "codex-sess-1", "cwd": "/repo/webapp"}},
        {"type": "turn_context", "timestamp": ISO1,
         "payload": {"model": "gpt-5.6-luna", "turn_id": "turn-1"}},
        {"timestamp": ISO1, "type": "event_msg", "payload": {
            "type": "token_count", "turn_id": "turn-1",
            "info": {"total_token_usage": {"input_tokens": 5000, "cached_input_tokens": 1000,
                                           "cache_write_input_tokens": 500, "output_tokens": 200},
                     "last_token_usage": {"input_tokens": 5000, "cached_input_tokens": 1000,
                                          "cache_write_input_tokens": 500, "output_tokens": 200}}}},
        {"timestamp": ISO2, "type": "event_msg", "payload": {
            "type": "token_count", "turn_id": "turn-1",
            "info": {"total_token_usage": {"input_tokens": 9000, "cached_input_tokens": 2000,
                                           "cache_write_input_tokens": 500, "output_tokens": 450},
                     "last_token_usage": {"input_tokens": 4000, "cached_input_tokens": 1000,
                                          "cache_write_input_tokens": 0, "output_tokens": 250}}}},
        {"timestamp": ISO2, "type": "event_msg",
         "payload": {"type": "task_complete", "turn_id": "turn-1"}},
    ])
    # logs_2.sqlite：独立 thread（不被 JSONL 覆盖），turn 遥测 body
    body = ('codex.turn.token_usage.input_tokens=3000 '
            'codex.turn.token_usage.cached_input_tokens=600 '
            'codex.turn.token_usage.cache_write_input_tokens=100 '
            'codex.turn.token_usage.output_tokens=120 '
            'model=gpt-5 thread.id=thread-sqlite-1 turn.id=turn-9')
    db_file = os.path.join(root, "logs_2.sqlite")
    os.makedirs(root, exist_ok=True)
    conn = sqlite3.connect(db_file)
    try:
        conn.execute("CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, feedback_log_body TEXT)")
        conn.execute("INSERT INTO logs VALUES (1, ?, 0, ?)", (T1 // 1000, body))
        conn.commit()
    finally:
        conn.close()


# ----------------------------------------------------------------- opencode ----
def make_opencode(base):
    root = os.path.join(base, "opencode")
    os.makedirs(root, exist_ok=True)
    conn = sqlite3.connect(os.path.join(root, "opencode.db"))
    try:
        conn.execute(
            "CREATE TABLE session (id TEXT,directory TEXT,title TEXT,model TEXT,"
            "tokens_input INT,tokens_output INT,tokens_reasoning INT,"
            "tokens_cache_read INT,tokens_cache_write INT,cost REAL,"
            "time_created INT,time_updated INT)")
        conn.execute("INSERT INTO session VALUES "
                     "('oc-sess-1','/repo/webapp','重构侧边栏','\"gpt-5.6-luna\"',"
                     "20000,800,0,5000,1000,0.0315,1,1)")
        conn.execute("INSERT INTO session VALUES "
                     "('oc-sess-2','/repo/api','修测试','{\"id\":\"gpt-5\"}',"
                     "9000,300,0,0,0,0.014,1,1)")
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------- dsh ----
def make_dsh(base):
    root = os.path.join(base, "dsh", "sessions")
    lines = [
        {"type": "session", "id": "dsh-sess-1", "cwd": "/repo/webapp", "time": T1},
        {"type": "request/header", "time": T1,
         "data": {"header": {"config": {"model": "deepseek-v4-pro"}}}},
        {"type": "assistant/chunk", "time": T1, "data": {"turn": 0, "step": 0,
            "chunk": {"type": "usage", "usage": {
                "inputTokens": 7000, "outputTokens": 350,
                "cacheReadTokens": 2000, "cacheWriteTokens": 0}}}},
        {"type": "assistant/chunk", "time": T2, "data": {"turn": 0, "step": 1,
            "chunk": {"type": "usage", "usage": {
                "inputTokens": 4000, "outputTokens": 200,
                "cacheReadTokens": 500, "cacheWriteTokens": 100}}}},
        {"type": "usage", "seq": 99, "time": T2,
         "data": {"usage": {"inputTokens": 100, "outputTokens": 10}}},
    ]
    raw = "".join(json.dumps(o, ensure_ascii=False) + "\n" for o in lines)
    out = os.path.join(root, "ws-webapp", "dsh-sess-1")
    os.makedirs(out, exist_ok=True)
    proc = subprocess.run(["zstd", "-q", "-o", os.path.join(out, "session.jsonl.zstd")],
                          input=raw.encode(), check=False)
    if proc.returncode != 0:
        raise SystemExit("需要系统 zstd 命令生成 DSH 语料（brew install zstd）")


# -------------------------------------------------------------------- hermes ----
def make_hermes(base):
    root = os.path.join(base, "hermes")
    os.makedirs(root, exist_ok=True)
    conn = sqlite3.connect(os.path.join(root, "state.db"))
    try:
        conn.executescript(
            "CREATE TABLE sessions(id TEXT,display_name TEXT);"
            "INSERT INTO sessions VALUES ('hermes-sess-1','每日巡检');"
            "INSERT INTO sessions VALUES ('hermes-sess-2','临时任务');"
            "CREATE TABLE session_model_usage("
            "session_id TEXT,model TEXT,input_tokens INT,output_tokens INT,"
            "cache_read_tokens INT,cache_write_tokens INT,reasoning_tokens INT,"
            "estimated_cost_usd REAL,actual_cost_usd REAL,"
            "first_seen INT,last_seen INT,api_call_count INT,"
            "billing_provider TEXT,billing_base_url TEXT,billing_mode TEXT,task TEXT)")
        conn.execute("INSERT INTO session_model_usage VALUES "
                     "('hermes-sess-1','claude-sonnet-4-5',15000,600,3000,0,0,"
                     "0,0.052,1,1,3,'anthropic','https://api.anthropic.com','sub','chat')")
        conn.execute("INSERT INTO session_model_usage VALUES "
                     "('hermes-sess-2','unpriced-model-x',4000,120,0,0,0,"
                     "0,0,1,1,1,'local','http://localhost:11434','api','chat')")
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------- kimi ----
def make_kimi(base):
    root = os.path.join(base, "kimi-code", "server", "events")
    write_jsonl(os.path.join(root, "session_kimi-1.jsonl"), [
        {"kind": "journal_header", "seq": 0, "version": 1},
        {"kind": "event", "seq": 1, "envelope": {"type": "event.session.created",
            "timestamp": ISO1, "payload": {"session": {"metadata": {"cwd": "/repo/api"}}}}},
        {"kind": "event", "seq": 2, "envelope": {"type": "turn.started",
            "timestamp": ISO1, "payload": {"prompt": "把导出按钮挪到右上角"}}},
        {"kind": "event", "seq": 3, "envelope": {"type": "turn.step.completed",
            "timestamp": ISO1, "payload": {"model": {"id": "kimi-k3"},
                "usage": {"inputOther": 5000, "output": 220,
                          "inputCacheRead": 1500, "inputCacheCreation": 300}}}},
        {"kind": "event", "seq": 4, "envelope": {"type": "turn.step.completed",
            "timestamp": ISO2, "payload": {"model": {"id": "kimi-k3"},
                "usage": {"inputOther": 3000, "output": 130,
                          "inputCacheRead": 900, "inputCacheCreation": 0}}}},
    ])


# ------------------------------------------------------------------------ pi ----
def make_pi(base):
    root = os.path.join(base, "pi", "sessions")
    write_jsonl(os.path.join(root, "webapp", "pi-sess-1.jsonl"), [
        {"type": "session", "id": "pi-sess-1", "cwd": "/repo/webapp"},
        {"type": "message", "id": "m1", "timestamp": ISO1,
         "message": {"role": "user", "content": "帮我加一个深色模式"}},
        {"type": "message", "id": "m2", "timestamp": ISO1,
         "message": {"role": "assistant", "model": "claude-sonnet-4-5",
                     "usage": {"input": 6000, "output": 260, "cacheRead": 1800,
                               "cacheWrite": 200,
                               "cost": {"input": 0.01, "output": 0.002, "total": 0.021}}}},
        {"type": "message", "id": "m3", "timestamp": ISO2,
         "message": {"role": "assistant", "model": "unpriced-model-x",
                     "usage": {"input": 1500, "output": 60, "cacheRead": 0,
                               "cacheWrite": 0, "cost": {"total": 0}}}},
    ])


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    make_claude(out)
    make_codex(out)
    make_opencode(out)
    make_dsh(out)
    make_hermes(out)
    make_kimi(out)
    make_pi(out)
    print(f"语料已生成: {out}")


if __name__ == "__main__":
    main()
