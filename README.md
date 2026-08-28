# TokenTracker

统计本机 **Claude Code · Kimi Code · Codex · DSH · Pi · opencode · Hermes Agent**
七个 AI 编程工具的 Token 用量与成本。用量日志在本机读取和保存；官方配额查询、登录刷新会访问对应服务，不上传用量日志。

## 桌面 App（macOS 状态栏常驻 · 白色简洁 UI）

<img src="assets/icon_1024.png" width="128" height="128" alt="TokenTracker：暖橙色开口圆环与折线">

图标源稿：[Figma · TokenTracker App Icon](https://www.figma.com/design/HFAWys8F1N3MDP3HXZvGIB?node-id=2-2)。
应用使用浅色圆角底板；页面使用同一透明线条符号。构建直接使用仓库资产，不访问 Figma、不重绘图标。
更新流程和验收见[图标说明](docs/icon-design.md)。

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

- 状态栏：标题实时显示今日 tokens + 选中平台最紧的配额窗口（如 `⚡ 12.30M · C 45%`，
  官方数据过期时显示 `~45%`，本地估算显示 `≈45%`；扫描中显示 ⟳）。菜单含今日统计、各订阅配额最紧窗口、
  「状态栏显示」二级菜单（radio 切换标题展示 Claude Code / Codex / Kimi / Go 或仅今日用量，
  选择记住在 `~/.tokentracker/settings.json`）、「打开主面板」「设置…」「立即扫描」「退出」。
  无 Dock 图标（主面板打开时临时出现）。
- 设置界面：主面板侧边栏「设置」（或状态栏菜单「设置…」、快捷键 ⌘,）：
  - **标题显示**：状态栏标题追加哪个平台的最紧配额窗口（等同状态栏二级菜单，双向同步）；
  - **紧凑标题**：更短的状态栏文字（`⚡12.30M·C45%`）——刘海屏 / 菜单栏图标多时可防止被挤出屏幕；
  - **开机自动启动**：登录 macOS 后自动打开（写入 LaunchAgent，仅打包后的 .app 支持）；
  - **本地数据目录**：一键在 Finder 打开 `~/.tokentracker`。
  所有设置保存在 `~/.tokentracker/settings.json`，状态栏 5 秒内自动生效，也可通过
  `GET/POST /api/settings` 读写（仅接受白名单内的键）。
- 主面板：概览（4 统计卡 / 每日趋势图 / 订阅配额 / 模型榜）+ 会话记录两个视图；
  侧栏展示 7 个工具的数据源状态与今日量，点击工具直达其会话列表；
  会话表可点表头排序、点行展开详情抽屉（按模型分解，可一键在 Finder 打开项目目录）；
  快捷键 ⌘1/⌘2 切视图、⌘R 扫描、⌘W 关闭面板；「扫描日志」按钮可随时增量扫描。
  红点关闭仅隐藏面板，真正退出走状态栏菜单。
- 自动扫描：App 启动时扫描一次，此后由 Python 服务每 60 秒调度增量扫描；隐藏主面板仍继续。定时与手动扫描共用锁，运行时跳过重复请求；退出 App 停止调度。

## 数据来源（自动探测）

| 工具 | 数据位置 | 说明 |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | 会话 JSONL 的 `usage` 字段 |
| Codex | `~/.codex/logs_2.sqlite` / `~/.codex/sessions/` | 标准 rollout JSONL 优先；SQLite 按会话/turn 补缺，不将两套来源直接相加 |
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
./tt serve --scan      # 仅启动时扫描一次
./tt serve --auto-scan # 启动时扫描，此后每 60 秒扫描；默认不启用
./tt scan && ./tt serve --open
```

对 `dsh` 之外其他工具也可以用 `python3 -m tokentracker ...`。

## 成本估算

- 总 Token = **非缓存输入 + 输出 + 缓存读取 + 缓存写入**；已包含在输出中的推理 Token 不重复计入。
- 价格表：`prices.json`（本项目根目录），单位 **美元 / 百万 token**，可自行增删改。
- 匹配规则：模型名先精确、再子串（不区分大小写），最后回退 `default`。
- 未匹配到价格的模型：只统计 token、不计费（仪表盘显示 `—`）。
- opencode / Hermes 自带官方成本时优先采用自带值。
- 另可用 `TOKENTRACKER_PRICES=/path/prices.json` 指定价格表。

历史总量保留，但无法确定时间的部分会标注“未分配到时间”，不强行算进今天。累计快照的后续差量标注“按观测时间估算”；观察区间跨越日期/小时边界时，不强行放入单一分桶。见[指标口径](docs/metrics.md)和[迁移说明](docs/migrations.md)。

## 增量扫描

- JSONL：保存读取前的 inode、纳秒 mtime 和 size；读取期间发生变化则下轮重扫，按消息/事件身份去重。
- Codex：识别 `session_meta`、`turn_context`、`event_msg/token_count`、ISO 时间与累计差量；重复通知不重复入库。同 turn 优先 JSONL，SQLite 只补其缺少的差额；没有可靠 turn 身份则按整个会话选择 JSONL。
- opencode / Hermes：持久化每个来源的累计快照。首次存量为未分配历史，后续仅记录差量和观察区间；计数器下降则报告重置、更新基线，不生成负 Token。
- `stats`、普通 `serve` 不会启动后台扫描。`scan --full` 重读源文件但保留历史与快照；`scan --reset` 是显式清空操作，会丢失已积累的时间信息，**不要用它迁移或日常刷新**。

## 环境变量

| 变量 | 作用 |
|---|---|
| `TOKENTRACKER_DB` | 汇总库位置（默认 `~/.tokentracker/usage.db`） |
| `TOKENTRACKER_PRICES` | 价格表位置 |
| `CLAUDE_PROJECTS_DIR` / `CODEX_LOGS_DB` / `CODEX_SESSIONS_DIR` / `OPENCODE_DB` / `DSH_SESSIONS_DIR` / `HERMES_HOME` / `KIMI_CODE_HOME` / `PI_HOME` | 各工具数据源覆盖 |

## 订阅配额进度条（固定窗口）

顶部配额卡片固定显示 **5 小时 / 周 (7天) / 月度** 三个窗口的进度，**不随页面时间范围变化**。数据两级来源：

1. **官方**（凭据有效时）：显示官方百分比与重置倒计时，徽标同时标注走的那条路（`官方 · 桌面采样 / API / wham / RPC`）；凭据失效自动降级并在卡片标注原因。
   - **Claude** 三级回退链：① 桌面 App 采样文件（`~/Library/Application Support/Claude/plan-usage-history.json`，桌面 App 每 ~5 分钟自采，无需凭据，<30min 有效；不受 Claude Code 2.1.x 清空钥匙串的官方 bug 影响）→ ② `api.anthropic.com/api/oauth/usage`（凭据遍历钥匙串 / `~/.claude/.credentials.json` / 本地快照 `~/.tokentracker/claude_cred_backup.json`，跳过被清空的空壳条目逐个尝试；手写刷新失败再委托官方 CLI `claude auth login` 环境变量刷新）→ ③ 提示重新登录。见到有效凭据自动快照，官方存储再被清空也能自行复活。
   - **Kimi**：只读 `${KIMI_CODE_HOME:-~/.kimi-code}/credentials/kimi-code.json` 中的现有 access token，查询 `api.kimi.com/coding/v1/usages`；不主动刷新、不回写凭据、不启动登录流程。令牌过期由 Kimi Code 自身更新，期间显示标记过期的官方缓存或本地估算。
   - **Codex**：主路 `chatgpt.com/backend-api/wham/usage`（复用 `~/.codex/auth.json`，401 自动刷新并原子写回），`codex app-server` RPC 兑底。
2. **本地估算**：从汇总库统计能归入该窗口的用量（token 或估算成本），对比 `quotas.json` 的上限；未分配历史和跨窗口观察区间另行提示，不算入窗口百分比。

成功缓存 120 秒，普通失败退避 120 秒，429 遵守 `Retry-After`（手动刷新也不绕过）。官方旧结果最多保留 24 小时，并明确标记过期。窗口 `source` 表示来源、`stale` 表示过期，说明文案不参与状态判断。升级不会修改用户的配额上限。

Kimi 凭据文件更新后，下次配额轮询会重新读取，不必等完普通失败退避；仍不会绕过429限流。空凭据或401只表示当前读取的访问令牌不可用，不会直接要求重新登录。若 Kimi Code 未运行且令牌已过期，TokenTracker 不会自行维持登录态。

内置条目（`quotas.json` 可改）：

| 卡片 | 窗口 | 数据 |
|---|---|---|
| Claude Code | 5h / 7d | **官方**：桌面 App 采样文件 → `api.anthropic.com/api/oauth/usage` 回退链（见上） |
| Kimi | 5h / 7d / 月度 | **官方**：只读 Kimi Code 的现有 access token → `api.kimi.com/coding/v1/usages`（请求次数配额）；过期由 Kimi 刷新，月度窗口本地测算 |
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
│   ├── build_icon.sh         # 显式将已确认 PNG 转为 ICNS（macOS）
│   └── check_icon.py         # 离线校验 SVG / PNG / ICNS
└── tokentracker/
    ├── __main__.py           # CLI: scan / stats / detect / serve
    ├── db.py                 # SQLite 汇总库 + 查询
    ├── pricing.py            # 成本估算
    ├── server.py             # 本地 HTTP 服务（含 /app/* GUI 静态路由）
    └── scanners/             # 7 个工具的适配器
```

## 测试与升级验收

```bash
python3 -m unittest discover -s tests -v
node --check app/web/app.js
node tests/test_frontend.js
python3 tests/browser_fixture.py  # 可选：仅虚构用量/配额的浏览器验收页面，Ctrl-C结束
```

见[逐项验收记录](docs/audit-acceptance.md)、[指标口径](docs/metrics.md)、[迁移说明](docs/migrations.md)。

## 参考项目

- [tokscale](https://github.com/junhoyeo/tokscale) — 多客户端用量统计（数据位置表）
- [ccusage](https://github.com/ccusage/ccusage) — Claude Code 解析权威实现
- [tokentelemetry](https://github.com/VasiHemanth/tokentelemetry) — Hermes + Claude + Codex 仪表盘
- [claude-usage](https://github.com/joshhu/claude-usage) — Claude Dashboard 形态
