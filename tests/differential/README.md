# 差分测试基建（Swift 重构对照基准）

SwiftUI 重构（`docs/swiftui-migration-plan.md`）的质量地基：**同一份语料，
Python 与 Swift 两套扫描器的结果必须逐字段一致**。

## 组成

| 文件 | 作用 |
|---|---|
| `make_corpus.py` | 生成虚构语料库 `corpus/`（7 个工具的数据源形状，固定时间戳，可重复生成；不提交 git） |
| `prices.json` | 差分专用稳定价格表（不随仓库根 `prices.json` 漂移） |
| `export_python.py` | Python 版扫描器扫语料 → 规范化 JSON（排序、cost 按 6 位小数舍入、冻结墙钟） |
| `expected_python.json` | 已提交的基线（oracle）。Swift 侧由 `DifferentialExportTests` 解码校验 |

## 流程

```bash
python3 tests/differential/make_corpus.py     # 生成语料（需要系统 zstd）
python3 tests/differential/export_python.py   # 重新生成基线 expected_python.json
python3 tests/differential/export_python.py - # 打印到 stdout（不写文件）
```

`tests/test_differential.py` 已挂进 unittest：连续两次导出逐字节一致 +
与基线一致。若对扫描器做了**有意**的行为变更，重跑 `export_python.py`
更新基线并在提交信息里说明。

## 规范化约定（Swift 侧 Phase 1 必须遵守）

- `events`：按 `(tool, src_key)` 升序；`cost` 四舍五入到 6 位小数，`NULL → null`；
  不含自增 `id`；
- `session_meta`：按 `(tool, session_id)` 排序；不含 `updated_at`（真实时间）；
- `snapshots`：`values_json` 解析为对象，浮点同样 6 位舍入；按
  `(tool, source_scope, identity)` 排序；
- `scan_results`：`run_all` 原始返回（added/updated/files/counter_resets/…）。

## 语料覆盖范围

正常路径：每工具 1–2 个会话、含缓存 token、命中价格表/走 default/模型为空
不计费、codex 双源（rollout JSONL + logs_2.sqlite）、opencode/hermes 聚合
快照（native / 估算成本、unallocated 时间质量）、DSH zstd 压缩流、
Kimi 逐步增量、Pi 官方成本。**边界场景**（计数器重置、截断增量、坏行、
身份冲突等）不进语料，由 Phase 1 逐条移植 `tests/test_scanners.py` /
`test_aggregate_scanners.py` 的用例覆盖。
