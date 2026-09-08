#!/usr/bin/env python3
"""差分导出：用 Python 版扫描器扫 tests/differential/corpus/，输出规范化 JSON。

这是 Swift 移植的对照基准（oracle）。规范化规则（Swift 侧必须一致）：

- events：usage_events 全行，按 (tool, src_key) 排序；cost 四舍五入到 6 位小数
  （屏蔽浮点末位差异），NULL 保持 null；
- session_meta：按 (tool, session_id) 排序，不含 updated_at（真实时间）；
- scan_results：run_all 返回的 added/updated/files/counter_resets/warning/skipped；
- snapshots：aggregate_snapshots 的 values_json 解析后同样按 6 位小数规范化。

确定性保障：语料时间戳固定；db.time.time 被冻结（opencode/hermes 的
observed_at 依赖墙钟）；PI_HOME 之外的 ~/.omp、kimi-cli 目录被屏蔽；
TOKENTRACKER_PRICES 指向本目录的稳定价格表（不随仓库根 prices.json 漂移）。

用法：
    python3 tests/differential/export_python.py            # 写到 expected_python.json
    python3 tests/differential/export_python.py -          # 打印到 stdout
"""
from __future__ import annotations

import json
import hashlib
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CORPUS = "/tmp/tt_diff_corpus"
CANONICAL_CORPUS = "/private/tmp/tt_diff_corpus"
EXPECTED = os.path.join(HERE, "expected_python.json")
FIXED_NOW = 1787626800.0  # 2026-08-25T03:00:00Z，语料时间戳之后

sys.path.insert(0, ROOT)


def round6(value):
    return round(value, 6) if isinstance(value, float) else value


def canonical_corpus_path(value: str) -> str:
    """Normalize realpath-only fixture paths across macOS and Linux.

    macOS resolves /tmp to /private/tmp while Linux keeps /tmp. Production
    source identities intentionally use real paths; only the differential
    export rewrites fixture paths to one stable representation.
    """
    real_corpus = os.path.realpath(CORPUS)
    if value == real_corpus:
        return CANONICAL_CORPUS
    if value.startswith(real_corpus + os.sep):
        return CANONICAL_CORPUS + value[len(real_corpus):]
    return value


def export() -> dict:
    if not os.path.isdir(CORPUS):
        print(f"语料不存在，先生成: python3 {os.path.join(HERE, 'make_corpus.py')}",
              file=sys.stderr)
        raise SystemExit(1)

    os.environ["TOKENTRACKER_PRICES"] = os.path.join(HERE, "prices.json")
    os.environ["CLAUDE_PROJECTS_DIR"] = os.path.join(CORPUS, "claude", "projects")
    os.environ["CODEX_SESSIONS_DIR"] = os.path.join(CORPUS, "codex", "sessions")
    os.environ["CODEX_LOGS_DB"] = os.path.join(CORPUS, "codex", "logs_2.sqlite")
    os.environ["OPENCODE_DB"] = os.path.join(CORPUS, "opencode", "opencode.db")
    os.environ["DSH_SESSIONS_DIR"] = os.path.join(CORPUS, "dsh", "sessions")
    os.environ["HERMES_HOME"] = os.path.join(CORPUS, "hermes")
    os.environ["KIMI_CODE_HOME"] = os.path.join(CORPUS, "kimi-code", "server", "events")
    os.environ["PI_HOME"] = os.path.join(CORPUS, "pi", "sessions")

    from tokentracker import db, pricing
    from tokentracker.scanners import kimi, pi, run_all

    # 冻结墙钟：聚合快照的 observed_at / put_event 的兜底 ts 都变成常量。
    db.time.time = lambda: FIXED_NOW  # type: ignore[attr-defined]
    # 屏蔽本机真实数据源（语料之外的 ~/.omp、~/.kimi/sessions）。
    pi.roots = lambda: [os.environ["PI_HOME"]]  # type: ignore[attr-defined]
    kimi.cli_dir = lambda: os.path.join(CORPUS, "kimi-cli-nonexistent")  # type: ignore[attr-defined]

    prices = pricing.load_prices()
    tmp = tempfile.TemporaryDirectory(prefix="tt_differential_")
    conn = db.connect(os.path.join(tmp.name, "usage.db"))
    try:
        scan_results = run_all(conn, prices)
        db.reprice(conn, prices)
        events = [dict(r) for r in conn.execute(
            "SELECT tool,src_key,session_id,project,ts,model,input,output,"
            "cache_read,cache_write,cost,time_quality,interval_start,cost_source,"
            "source_kind,source_scope FROM usage_events ORDER BY tool,src_key")]
        for e in events:
            e["cost"] = round6(e["cost"])
        activities = [dict(r) for r in conn.execute(
            "SELECT agent,session_id,turn_id,raw_name,canonical_name,namespace,call_id,"
            "parent_call_id,started_at,ended_at,duration_ms,status,source_kind,confidence,"
            "skill_name,skill_confidence,src_key FROM agent_activity_events "
            "ORDER BY agent,src_key")]
        meta = [dict(r) for r in conn.execute(
            "SELECT tool,session_id,title FROM session_meta ORDER BY tool,session_id")]
        snapshots = []
        for r in conn.execute(
                "SELECT tool,source_scope,identity,values_json,observed_at,revision "
                "FROM aggregate_snapshots ORDER BY tool,source_scope,identity"):
            row = dict(r)
            values = json.loads(row.pop("values_json"))
            snapshots.append({**row, "values": {k: round6(v) for k, v in values.items()}})

        # Aggregate src_key digests include source_scope. Normalize the fixture
        # realpath before comparing the committed baseline so Linux and macOS
        # exercise identical data without changing production identity rules.
        digest_map = {}
        for snapshot in snapshots:
            scope = snapshot["source_scope"]
            canonical_scope = canonical_corpus_path(scope)
            if canonical_scope != scope:
                old = hashlib.sha256(json.dumps([scope, snapshot["identity"]]).encode()).hexdigest()
                new = hashlib.sha256(
                    json.dumps([canonical_scope, snapshot["identity"]]).encode()
                ).hexdigest()
                digest_map[old] = new
                snapshot["source_scope"] = canonical_scope
        for event in events:
            event["source_scope"] = canonical_corpus_path(event["source_scope"])
            if event["src_key"].startswith("aggregate|"):
                parts = event["src_key"].split("|", 2)
                parts[1] = digest_map.get(parts[1], parts[1])
                event["src_key"] = "|".join(parts)
        for event in activities:
            event["src_key"] = canonical_corpus_path(event["src_key"])
    finally:
        conn.close()
        tmp.cleanup()
    return {"format_version": 2, "events": events, "activities": activities,
            "session_meta": meta,
            "scan_results": scan_results, "snapshots": snapshots}


def main():
    out = export()
    text = json.dumps(out, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    if len(sys.argv) > 1 and sys.argv[1] == "-":
        sys.stdout.write(text)
    else:
        with open(EXPECTED, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"已写出: {EXPECTED}（events={len(out['events'])}）")


if __name__ == "__main__":
    main()
