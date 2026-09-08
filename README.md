# TokenTracker

统计本机 **Claude Code · Kimi Code · Codex · DSH · Pi · opencode · Hermes Agent**
七个 AI 编程工具的 Token 用量、成本与订阅配额。

用量日志只在本机读取和保存。官方配额查询及登录刷新会访问对应服务，
不会上传本地用量日志。

## macOS App

<img src="assets/icon_1024.png" width="128" height="128" alt="TokenTracker App 图标">

当前桌面实现是 `swift/` 下的原生 SwiftUI App，支持：

- 状态栏实时显示今日用量与订阅配额；
- 概览、手绘趋势、模型排行、会话列表和独立会话详情窗口；
- Agent 工具与 Skill 活动总览、榜单、时间线和 Agent × 工具矩阵；
- 自动扫描、手动刷新、开机启动和应用内更新；
- Codex 多账号本地保存与切换；
- 从会话详情在 Terminal、iTerm2、WezTerm 或 Ghostty 中继续会话；
- macOS 14 Sonoma 及以上版本。

构建与运行：

```bash
./scripts/build_swift_app.sh
open dist/TokenTracker.app
```

发行包：

```bash
./scripts/release_swift.sh
```

脚本默认使用本地 ad-hoc 签名。Developer ID 签名与公证要求见脚本说明。

### macOS 26 状态栏权限

首次使用可能需要在“系统设置 → 菜单栏”中允许 TokenTracker。
App 会避免 Tahoe 的重复标题赋值问题，并带有状态栏重排和重建自愈逻辑。
排障记录见[状态栏说明](docs/menubar-visibility-plan.md)。

## 命令行工具

过渡期继续保留 Python CLI：

```bash
./tt detect
./tt scan
./tt scan --tool codex
./tt scan --full
./tt scan --reset --tool opencode
./tt stats
./tt stats --range week
./tt stats --tool claude
./tt activity --range week --group tool --confidence exact
./tt quotas
```

Swift Package 同时提供原生 CLI：

```bash
swift build -c release --package-path swift
swift/.build/release/tt-swift detect
swift/.build/release/tt-swift scan --full
swift/.build/release/tt-swift stats --range week
swift/.build/release/tt-swift activity --range week --group tool --confidence exact
swift/.build/release/tt-swift quotas
```

两个 CLI 读写同一个 `~/.tokentracker/usage.db`。Python CLI 暂时保留用于完整参数兼容
和 Swift 差分测试；浏览器仪表盘已经退役。

## 数据来源

| 工具 | 默认位置 | 统计来源 |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | assistant usage |
| Codex | `~/.codex/sessions/**/*.jsonl`、`~/.codex/logs_*.sqlite` | token_count 与 turn 遥测 |
| Kimi Code | `~/.kimi-code/server/events/session_*.jsonl` | turn.step.completed |
| DSH | `~/.dsh/sessions/**/session.jsonl.zstd` | usage 事件 |
| Pi | `~/.pi/agent/sessions/**/*.jsonl` | message usage |
| opencode | `~/.local/share/opencode/opencode.db` | 会话累计量 |
| Hermes Agent | `~/.hermes/**/*.db` | session_model_usage |

可以通过环境变量覆盖数据源路径，完整列表以各扫描器和 `ScanRoots` 为准。

## 数据与口径

- 数据库：`~/.tokentracker/usage.db`
- 设置：`~/.tokentracker/settings.json`
- 官方配额缓存：`~/.tokentracker/official_cache.json`
- 价格表：仓库根目录 `prices.json`
- 本地配额配置：仓库根目录 `quotas.json`

Token、成本、观察区间和未分配历史的计算规则见[指标口径](docs/metrics.md)，
数据库兼容与恢复方式见[迁移说明](docs/migrations.md)。

Agent Activity 只保存工具名、会话、时间、状态和证据等级等元数据；不会保存
工具参数、命令、提示词或输出正文。确认数据与保守推断始终分开统计。

## 项目结构

```text
swift/
  Sources/TokenTrackerCore/       扫描、存储、计价、配额、恢复与更新
  Sources/TokenTrackerApp/        SwiftUI/AppKit macOS App
  Sources/tt-swift/               原生 CLI
  Tests/TokenTrackerCoreTests/    Swift 测试
tokentracker/                      过渡期 Python CLI 与差分 oracle
tests/differential/               跨实现固定语料与基线
assets/                            App 图标源文件与 ICNS
scripts/                           Swift 构建、发布和图标验证
```

SwiftUI 重构过程和模块映射见[迁移记录](docs/swiftui-migration-plan.md)，
图标来源与离线验证见[图标说明](docs/icon-design.md)。

## 测试

```bash
python3 -m unittest discover -s tests -v
swift test --package-path swift
python3 scripts/check_icon.py
```

Swift 差分测试会使用 `tests/differential/expected_python.json` 作为冻结基线；
首次生成虚构语料需要系统安装 `zstd`。
