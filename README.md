<p align="center">
  <img src="assets/icon_1024.png" width="112" height="112" alt="TokenTracker app icon">
</p>

<h1 align="center">TokenTracker</h1>

<p align="center">
  <strong>Know what your AI coding agents cost — without sending their logs anywhere.</strong><br>
  一眼看清 7 种 AI 编程工具的 Token、成本、订阅配额与 Agent 活动，数据默认留在本机。
</p>

<p align="center">
  <a href="https://github.com/fengfe1125/tokentracker/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/fengfe1125/tokentracker?display_name=tag&sort=semver&style=flat-square"></a>
  <a href="https://github.com/fengfe1125/tokentracker/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/fengfe1125/tokentracker/total?style=flat-square"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="https://github.com/fengfe1125/tokentracker/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/fengfe1125/tokentracker?style=flat-square"></a>
</p>

<p align="center">
  <a href="https://github.com/fengfe1125/tokentracker/releases/latest"><strong>下载最新版</strong></a>
  ·
  <a href="#从源码运行">从源码运行</a>
  ·
  <a href="#命令行工具">CLI</a>
  ·
  <a href="#隐私与数据">隐私说明</a>
</p>

> 如果 TokenTracker 帮你弄清了 AI 编程成本，欢迎点一个 **Star**。它会让更多同时使用多个 Agent 的开发者发现这个项目。

## 为什么需要 TokenTracker？

Claude Code、Codex、Kimi Code 等工具各自记录用量，但格式、价格和配额入口并不统一。TokenTracker 会直接读取它们留在 Mac 上的本地记录，把分散的信息整理成一个原生 macOS App：

| 一个总览 | 本地优先 | 不止 Token |
|---|---|---|
| 跨工具比较今日、趋势、模型、会话与成本 | 用量日志在本机读取和保存，默认不公开 | 同时查看订阅配额、工具调用、Skill 活动与 Agent × 工具关系 |

适合这些场景：

- 同时使用多个 AI 编程 CLI，想知道钱和 Token 花到了哪里；
- 想比较不同模型、工具或会话的实际使用量；
- 需要观察 Agent 调用了哪些工具和 Skill，但不想保存提示词与输出正文；
- 喜欢一个常驻菜单栏、无需浏览器和云端仪表盘的原生工具。

## 支持的 AI 编程工具

| 工具 | Token / 成本 | 订阅配额 | Agent 活动 |
|---|:---:|:---:|:---:|
| Claude Code | ✓ | ✓ | ✓ |
| Codex | ✓ | ✓ | ✓ |
| Kimi Code | ✓ | ✓ | ✓ |
| DSH / OpenCode Go | ✓ | ✓ | ✓ |
| Pi | ✓ | — | ✓ |
| opencode | ✓ | — | ✓ |
| Hermes Agent | ✓ | — | ✓ |

> 配额能力取决于对应服务可用的官方接口或本地登录状态；Token 与成本统计不依赖统一云端账户。

## 你会得到什么

- **菜单栏实时摘要**：随时查看今日用量和订阅配额；
- **原生数据面板**：概览、手绘趋势、模型排行、会话列表和独立详情窗口；
- **Agent Activity**：工具与 Skill 总览、榜单、时间线和 Agent × 工具矩阵；
- **可追溯成本**：按工具、模型、日期和会话拆分 Token 与估算费用；
- **会话继续**：从详情页在 Terminal、iTerm2、WezTerm 或 Ghostty 中恢复会话；
- **日常可用性**：自动扫描、手动刷新、开机启动、应用内更新和 Codex 多账号切换。

## 快速开始

### 安装 macOS App

1. 打开 [Latest Release](https://github.com/fengfe1125/tokentracker/releases/latest)。
2. 下载 `TokenTracker-*.dmg`，把 TokenTracker 拖入“应用程序”。
3. 启动 App，它会自动发现本机已支持工具的日志。

要求 **macOS 14 Sonoma 或更高版本**。当前发行包使用 ad-hoc 签名；如果 macOS 提示无法验证开发者，请在 Finder 中按住 Control 点击 App，选择“打开”。

在 macOS 26 Tahoe 上，首次使用还可能需要前往“系统设置 → 菜单栏”允许 TokenTracker。排障方式见[状态栏说明](docs/menubar-visibility-plan.md)。

### 从源码运行

需要 Xcode Command Line Tools 与 Swift 6：

```bash
git clone https://github.com/fengfe1125/tokentracker.git
cd tokentracker
./scripts/build_swift_app.sh
open dist/TokenTracker.app
```

制作本地 DMG：

```bash
./scripts/release_swift.sh
```

Developer ID 签名与公证要求见发布脚本说明。

## 隐私与数据

TokenTracker 的默认边界很简单：**扫描本机，保存在本机，不上传用量日志。**

- 数据库：`~/.tokentracker/usage.db`
- 设置：`~/.tokentracker/settings.json`
- 官方配额缓存：`~/.tokentracker/official_cache.json`
- 本地价格与配额配置：`prices.json`、`quotas.json`

只有查询官方订阅配额、刷新对应服务登录状态时，才会访问该服务。可选的公开统计功能默认关闭；即使主动启用，也只允许发布基础聚合指标和成本，不包含项目路径、会话 ID、标题、提示词、模型名、主机名或账户信息。

Agent Activity 只保存工具名、会话、时间、状态和证据等级等元数据，不保存工具参数、命令、提示词或输出正文。完整计算规则见[指标口径](docs/metrics.md)，数据库兼容与恢复方式见[迁移说明](docs/migrations.md)。

## 命令行工具

原生 Swift CLI 与 App 共用同一个数据库：

```bash
swift build -c release --package-path swift
swift/.build/release/tt-swift detect
swift/.build/release/tt-swift scan --full
swift/.build/release/tt-swift stats --range week
swift/.build/release/tt-swift activity --range week --group tool --confidence exact
swift/.build/release/tt-swift quotas
```

过渡期保留 Python CLI，用于完整参数兼容和 Swift 差分测试：

```bash
./tt detect
./tt scan --full
./tt stats --range week
./tt activity --range week --group tool --confidence exact
./tt quotas
```

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

数据源路径可以通过环境变量覆盖，完整列表以各扫描器和 `ScanRoots` 为准。

## 项目结构

```text
swift/
  Sources/TokenTrackerCore/       扫描、存储、计价、配额、恢复与更新
  Sources/TokenTrackerApp/        SwiftUI / AppKit macOS App
  Sources/tt-swift/               原生 CLI
  Tests/                          Swift 测试
tokentracker/                      过渡期 Python CLI 与差分 oracle
tests/differential/               跨实现固定语料与基线
assets/                            App 图标源文件与 ICNS
scripts/                           构建、发布和图标验证
```

SwiftUI 重构过程和模块映射见[迁移记录](docs/swiftui-migration-plan.md)，图标来源与离线验证见[图标说明](docs/icon-design.md)。

## 开发与测试

```bash
python3 -m unittest discover -s tests -v
swift test --package-path swift
python3 scripts/check_icon.py
```

Swift 差分测试使用 `tests/differential/expected_python.json` 作为冻结基线；首次生成虚构语料需要系统安装 `zstd`。

---

<p align="center">
  Built for developers who want the benefits of AI coding agents without losing sight of usage, cost, or privacy.<br>
  <a href="https://github.com/fengfe1125/tokentracker/stargazers"><strong>觉得有用？给 TokenTracker 一个 Star ★</strong></a>
</p>
