# TokenTracker

统计本机 **Claude Code · Kimi Code · Codex · DSH · Pi · opencode · Hermes Agent**
七个 AI 编程工具的 Token 用量与成本。数据 100% 本地读取各工具自己的日志，不上传任何东西。

## 桌面 App（macOS 状态栏常驻 · 白色简洁 UI）

> **屏幕顶部系统状态栏常驻**（⚡ 实时今日用量，点开菜单看成本/配额、立即扫描、唤出主面板）
> + 无边框白色简洁主面板，关闭只隐藏不退出，状态栏随时唤回。

```bash
./scripts/build_app.sh              # 一键打包 → dist/TokenTracker.app（自包含，双击即用）
open dist/TokenTracker.app
```

开发模式（无需打包）：

```bash
.venv/bin/pip install pywebview    # 首次
.venv/bin/python app/desktop.py    # 状态栏图标 + 主面板
```

- 状态栏：标题实时显示今日 tokens（扫描中显示 ⟳）；菜单含今日统计、各订阅配额
  最紧窗口、「打开主面板」「立即扫描」「退出」。无 Dock 图标（主面板打开时临时出现）。
- 主面板：概览（4 统计卡 / 每日趋势图 / 订阅配额 / 模型榜）+ 会话记录两个视图；
  侧栏展示 7 个工具的数据源状态与今日量，点击工具直达其会话列表；
  会话表可点表头排序、点行展开详情抽屉（按模型分解，可一键在 Finder 打开项目目录）；
  快捷键 ⌘1/⌘2 切视图、⌘R 扫描、⌘W 关闭面板；「扫描日志」按钮可随时增量扫描。
  红点关闭仅隐藏面板，真正退出走状态栏菜单。
- 自动扫描：App 启动时自动增量扫描一次，之后主面板每 60s 自动刷新（新日志自动入库）。

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

1. **官方**（凭据有效时）：显示官方百分比与重置倒计时，徽标同时标注走的那条路（`官方 · 桌面采样 / API / wham / RPC`）；凭据失效自动降级并在卡片标注原因。
   - **Claude** 三级回退链：① 桌面 App 采样文件（`~/Library/Application Support/Claude/plan-usage-history.json`，桌面 App 每 ~5 分钟自采，无需凭据，<30min 有效；不受 Claude Code 2.1.x 清空钥匙串的官方 bug 影响）→ ② `api.anthropic.com/api/oauth/usage`（凭据遍历钥匙串 / `~/.claude/.credentials.json` / 本地快照 `~/.tokentracker/claude_cred_backup.json`，跳过被清空的空壳条目逐个尝试；手写刷新失败再委托官方 CLI `claude auth login` 环境变量刷新）→ ③ 提示重新登录。见到有效凭据自动快照，官方存储再被清空也能自行复活。
   - **Kimi**：`auth.kimi.com` 自动刷新 15 分钟短效 token → `api.kimi.com/coding/v1/usages`。
   - **Codex**：主路 `chatgpt.com/backend-api/wham/usage`（复用 `~/.codex/auth.json`，401 自动刷新并原子写回），`codex app-server` RPC 兑底。
2. **本地估算**（always 可用）：从汇总库统计各窗口真实用量（token 或估算成本），对比 `quotas.json` 里配置的上限。

内置条目（`quotas.json` 可改）：

| 卡片 | 窗口 | 数据 |
|---|---|---|
| Claude Code | 5h / 7d | **官方**：桌面 App 采样文件 → `api.anthropic.com/api/oauth/usage` 回退链（见上） |
| Kimi | 5h / 7d / 月度 | **官方**：`auth.kimi.com` 自动刷新 15 分钟短效 token → `api.kimi.com/coding/v1/usages`（请求次数配额）；月度窗口本地测算 |
| **OpenCode Go** | 5h / 7d / 月度 | **官方** `opencode.ai/zen/go/v1/usage`（Key 自动发现：`~/.local/share/opencode/auth.json` 或 `OPENCODE_GO_API_KEY`；实现参考 DSH cost-meter 插件 queryGoQuota） |
| Codex | 5h / 7d | **官方**：`chatgpt.com/backend-api/wham/usage`（CodexBar/headroom 同款），`codex app-server` RPC 兑底 |
| opencode | 月度=$60 | GO 月度等值；用量=opencode 本地成本 |

```bash
./tt quotas   # 终端查看全部窗口
```

官方抓取实现参考：[CodexBar docs/claude.md](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)、[CodexBar docs/codex.md](https://github.com/steipete/CodexBar/blob/main/docs/codex.md)、[zach-source/ccswitch](https://github.com/zach-source/ccswitch)（CLI 委托刷新 + 凭据快照思路）、[headroom](https://github.com/chopratejas/headroom)（wham/usage 端点）、[OpenCode Go 文档](https://opencode.ai/docs/go/)。

## 每日趋势图 Y 轴

数据里有极端大值的天会把其他日期压扁——点图右上角 **「Y 轴」** 按钮在线性/对数刻度间切换；存在明显极端值时默认自动切到对数。

## 目录结构

```
tokentracker/
├── tt                        # 启动器
├── prices.json               # 可编辑价格表
├── web/index.html            # 单页仪表盘（Chart.js 已内置离线）
├── app/                      # 桌面 App（pywebview 玻璃风主面板 + 状态栏常驻）
│   ├── desktop.py            # 入口：主面板 + NSStatusItem 状态栏
│   ├── menubar.py            # 状态栏：今日用量标题 + 下拉菜单
│   └── web/                  # 主界面 index.html / app.css / app.js
├── scripts/
│   ├── build_app.sh          # 一键打包 → dist/TokenTracker.app
│   └── make_icon.py          # 图标生成（纯 Python）
└── tokentracker/
    ├── __main__.py           # CLI: scan / stats / detect / serve
    ├── db.py                 # SQLite 汇总库 + 查询
    ├── pricing.py            # 成本估算
    ├── server.py             # 本地 HTTP 服务（含 /app/* GUI 静态路由）
    └── scanners/             # 7 个工具的适配器
```

## 参考项目

- [tokscale](https://github.com/junhoyeo/tokscale) — 多客户端用量统计（数据位置表）
- [ccusage](https://github.com/ccusage/ccusage) — Claude Code 解析权威实现
- [tokentelemetry](https://github.com/VasiHemanth/tokentelemetry) — Hermes + Claude + Codex 仪表盘
- [claude-usage](https://github.com/joshhu/claude-usage) — Claude Dashboard 形态