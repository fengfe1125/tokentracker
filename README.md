# TokenTracker

统计本机 **Claude Code · Kimi Code · Codex · DSH · Pi · opencode · Hermes Agent**
七个 AI 编程工具的 Token 用量与成本。数据 100% 本地读取各工具自己的日志，不上传任何东西。

## 数据来源（自动探测）

| 工具 | 数据位置 | 说明 |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | 会话 JSONL 的 `usage` 字段 |
| Codex | `~/.codex/logs_2.sqlite` / `~/.codex/sessions/` | 新版 SQLite 日志（`codex.turn.token_usage.*`）/ 旧版会话 JSONL |
| opencode | `~/.local/share/opencode/opencode.db` | `session` 表自带 token/cost 聚合 |
| DSH | `~/.dsh/sessions/**/session.jsonl.zstd` | zstd 压缩事件流（需要系统 `zstd` 命令） |
| Hermes Agent | `~/.hermes/state.db`（`session_model_usage` 表） | 含官方估算/实际成本 |
| Kimi Code | `~/.kimi-code/server/events/session_*.jsonl` | `turn.step.completed` 每步增量 |
| Pi | `~/.pi/agent/sessions/**/*.jsonl` | `message.usage` + 官方 cost |

## 快速开始

```bash
cd tokentracker
./tt detect            # 查看各工具数据源是否被识别
./tt scan              # 扫描日志入库（增量，可重复执行）
./tt stats             # 终端表格统计
./tt stats --range week
./tt serve --open      # 启动本地仪表盘（默认 http://127.0.0.1:8765，被占用时自动顺延）
./tt scan && ./tt serve --open
```

对 `dsh` 之外其他工具也可以用 `python3 -m tokentracker ...`。

## 成本估算

- 价格表：`prices.json`（本项目根目录），单位 **美元 / 百万 token**，可自行增删改。
- 匹配规则：模型名先精确、再子串（不区分大小写），最后回退 `default`。
- 未匹配到价格的模型：只统计 token、不计费（仪表盘显示 `—`）。
- opencode / Hermes 自带官方成本时优先采用自带值。
- 另可用 `TOKENTRACKER_PRICES=/path/prices.json` 指定价格表。

## 增量扫描

- JSONL 类（claude / dsh / kimi / pi）：按文件 mtime+size 跳过未变更文件，按内容幂等键（消息 id / turn+step / 事件 seq）去重，日志被工具压缩重写也不会重复计数。
- SQLite 类（codex / opencode）：按行 id / 更新时间游标增量读取；hermes 为全量覆盖更新（表本身幂等）。

## 环境变量

| 变量 | 作用 |
|---|---|
| `TOKENTRACKER_DB` | 汇总库位置（默认 `~/.tokentracker/usage.db`） |
| `TOKENTRACKER_PRICES` | 价格表位置 |
| `CLAUDE_PROJECTS_DIR` / `CODEX_LOGS_DB` / `OPENCODE_DB` / `DSH_SESSIONS_DIR` / `HERMES_HOME` / `KIMI_CODE_HOME` / `PI_HOME` | 各工具数据源覆盖 |

## 订阅配额进度条（固定窗口）

顶部配额卡片固定显示 **5 小时 / 周 (7天) / 月度** 三个窗口的进度，**不随页面时间范围变化**。数据两级来源：

1. **官方**（凭据有效时）：Claude 走 `api.anthropic.com/api/oauth/usage`（复用 `~/.claude/.credentials.json` 的 accessToken）；Kimi 走 `www.kimi.com` gateway usages（复用 `~/.kimi-code/credentials/kimi-code.json` + 设备头）。参考 [CodexBar](https://github.com/steipete/CodexBar) 的调研文档。显示官方百分比与重置倒计时；凭据失效自动降级并在卡片标注原因（重新登录对应工具即可恢复）。
2. **本地估算**（always 可用）：从汇总库统计各窗口真实用量（token 或估算成本），对比 `quotas.json` 里配置的上限。

内置条目（`quotas.json` 可改）：

| 卡片 | 窗口 | 数据 |
|---|---|---|
| Claude Code | 5h / 7d | **官方** `api.anthropic.com/api/oauth/usage`（utilization + 重置倒计时） |
| Kimi | 5h / 7d / 月度 | **官方**：`auth.kimi.com` 自动刷新 15 分钟短效 token → `api.kimi.com/coding/v1/usages`（请求次数配额）；月度窗口本地测算 |
| **OpenCode Go** | 5h / 7d / 月度 | **官方** `opencode.ai/zen/go/v1/usage`（Key 自动发现：`~/.local/share/opencode/auth.json` 或 `OPENCODE_GO_API_KEY`；实现参考 DSH cost-meter 插件 queryGoQuota） |
| Codex | 7d | **官方**：spawn `codex app-server`（JSON-RPC `account/rateLimits/read`，claude-usage-rs 同款实现） |
| opencode | 月度=$60 | GO 月度等值；用量=opencode 本地成本 |

```bash
./tt quotas   # 终端查看全部窗口
```

官方抓取实现参考：[CodexBar docs/claude.md](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)、[CodexBar docs/kimi.md](https://github.com/steipete/CodexBar/blob/main/docs/kimi.md)、[metrik](https://github.com/keros68/metrik) 的 Agent 配额来源表、[OpenCode Go 文档](https://opencode.ai/docs/go/)。

## 每日趋势图 Y 轴

数据里有极端大值的天会把其他日期压扁——点图右上角 **「Y 轴」** 按钮在线性/对数刻度间切换；存在明显极端值时默认自动切到对数。

## 目录结构

```
tokentracker/
├── tt                        # 启动器
├── prices.json               # 可编辑价格表
├── web/index.html            # 单页仪表盘（Chart.js 已内置离线）
└── tokentracker/
    ├── __main__.py           # CLI: scan / stats / detect / serve
    ├── db.py                 # SQLite 汇总库 + 查询
    ├── pricing.py            # 成本估算
    ├── server.py             # 本地 HTTP 服务
    └── scanners/             # 7 个工具的适配器
```

## 参考项目

- [tokscale](https://github.com/junhoyeo/tokscale) — 多客户端用量统计（数据位置表）
- [ccusage](https://github.com/ccusage/ccusage) — Claude Code 解析权威实现
- [tokentelemetry](https://github.com/VasiHemanth/tokentelemetry) — Hermes + Claude + Codex 仪表盘
- [claude-usage](https://github.com/joshhu/claude-usage) — Claude Dashboard 形态