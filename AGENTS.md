# TokenTracker

本机 AI 编程工具用量追踪器：扫描 Claude Code、Codex、Kimi Code、DSH / OpenCode Go、Pi、opencode、Hermes Agent、Antigravity 八类工具的本地日志，统计 Token、成本、订阅配额与 Agent 活动，并提供本机监听端口管理、刘海配额 HUD 与任务提醒/审批，以 macOS 原生状态栏 App（macOS 14+，Swift 6）和 CLI 呈现。Python 实现已移除，`swift/` 是唯一实现。

## 程序现状（v0.6.0）

- **版本与协议常量**（`TokenTrackerCore.swift` / `UsageStore.swift`）：
  - 应用版本：`0.6.0`；数据库：`UsageStore.schemaVersion = 8`（`~/.tokentracker/usage.db`）；活动解析器：`v3`；冻结差分基线：`differentialFormatVersion = 4`；公开统计载荷：`publicStatsFormatVersion = 1`。
- **支持的数据源（8 个，`Scanners/`）**：
  - 按事件明细扫描：`ClaudeScanner`（`~/.claude/projects/**/*.jsonl`）、`CodexScanner`（`~/.codex/sessions/**/*.jsonl` 与 `logs_*.sqlite`，同 turn 优先 JSONL）、`KimiScanner`（`~/.kimi-code/server/events/session_*.jsonl`）、`DshScanner`（`~/.dsh/sessions/**/session.jsonl.zstd`，需系统 `zstd`）、`PiScanner`（`~/.pi/agent/sessions/**/*.jsonl`）、`AntigravityScanner`（`~/.gemini/antigravity*/brain/*/.system_generated/logs/transcript.jsonl`，工作区由 `AntigravityWorkspaceMap` 合并 Antigravity 自带 `conversation_summaries.db`（只读 `conversation_id` / `workspace_uris`）与可选 Hook 映射，Hook 优先）。
  - 按累计快照差量扫描：`OpencodeScanner`（`~/.local/share/opencode/opencode.db`）、`HermesScanner`（`~/.hermes/**/*.db`）。
- **桌面 App 架构与界面（`TokenTrackerApp/`）**：
  - **顶栏导航主窗口（`RootView` / `TopTabBar`）**：无侧栏，适配 macOS 26 统一无分隔线标题栏；顶栏居中 6 个主视图（`概览`、`用量`、`端口`、`活动`、`报告`、`账号`，快捷键 `⌘1`–`⌘6`）与右侧扫描按钮（`⌘R`），外加 `设置`。顶栏下方为固定高度页面栏，`概览 / 用量 / 活动` 共用全局时间范围（今天 / 近 7 天 / 本月 / 全部）与 Agent 筛选胶囊栏（`ScopeToolbar`）。会话详情与活动明细均在主窗口内下钻。
  - **概览（`OverviewView`）**：主指标大数字 + 趋势区（今天活跃小时 ≤ 2 时自动展示 `TodayPulseView` 实时脉冲面板，含较昨日同刻对比、24 小时迷你节奏条与主要会话，可一键切换 24 小时固定槽 `TrendChart`；活跃小时 ≥ 3 时展示柱图）+ 账号配额卡片（位置可在卡片右上角或设置中切换为主图右侧 / 左侧 / 页面顶部 / 底部 / 隐藏，`overview_quota_position`）+ Token 热力图（`UsageHeatmapView`：今天/近 7 天为 24 小时网格，本月为周一至周日自然周月历网格附各周汇总，全部为按年自然周网格；单条 SQL 小时聚合与首屏预热缓存）。
  - **用量（`UsageView` / `UsageChartsView`）**：含 `项目`、`模型`、`会话` 三个子视图，均配齐原生 Swift Charts 可视化。
    - `项目`（`ProjectsView`）：汇总指标下方置顶「项目占比」环形图（Tokens / 费用切换、联动高亮与点击下钻）与「项目 Token 构成」四类堆叠横条图，列表下方为 Agent 分布与模型分布；单项目下钻提供四类堆叠柱图 + 成本折线趋势及手动归属调整。
    - `模型`：4 项顶部指标块（活跃模型 / 主力模型 / 费用合计 / 缓存命中率）、模型占比环形图、Token 构成堆叠图与缓存命中率对比图。
    - `会话`（`SessionsView` / `SessionDetailView` / `SessionMetadataView`）：未选中会话时底部展示可收起的「会话分布」面板（Agent 占比条 + 高消耗会话对比）；选中或下钻展示完整元数据（时间、工作目录、会话 ID、多模型构成、四类 Token 与成本）、「对话」预览（`SessionTranscriptView`：按需读取本机原始记录还原用户/助手/思考/工具调用，支持筛选、搜索与导出/复制 Markdown，解析在 `Transcript/SessionTranscriptReader`、`TranscriptMarkdown`）、执行时间线（`SessionTimelineView`）、源日志文件路径与 Finder 一键定位（`SessionSourceResolver`），并支持在 Terminal / iTerm2 / WezTerm / Ghostty 中恢复会话（`Resume`）。
  - **端口（`PortsView` / `PortsModel`）**：扫描本机 TCP 监听端口，解析绑定地址（区分仅本机与局域网可达）、RSS 内存占用、命令行与常见开发框架（Vite / Next.js / Wrangler / Uvicorn / FastAPI / Rails 等），按进程工作目录或命令行路径归属到项目并识别启动命令；支持搜索、默认过滤系统常驻进程、固定到状态栏、一键浏览器打开、终端内启停/重启项目及确认后关闭端口进程。
  - **活动（`ActivityView` / `ActivityDetailView`）**：活动解析 `v3`（Codex 已收到输出的 `response_item` 晋升为已确认执行，配对 DSH `tool/result`、Pi `toolResult` 与 Antigravity 后继 `GENERIC` 步骤的结果状态与耗时）；默认展示已确认执行事实、4 项核心指标、工具/Skill 榜单与 Agent × 工具矩阵，点击直达明细，底部折叠能力覆盖说明。
  - **报告与洞察（`ReportsView` / `InsightsStore`）**：按规范自然周主键（`week:yyyy-MM-dd`）生成与管理本地周报快照（ISO 周次标牌、生成区间预览、删除周报），提供预算/配额风险提醒、过去 14 天同刻异常检测、数据健康面板与脱敏 CSV/JSON 导出（`ReportsExport`）。
  - **账号与订阅（`AccountsView` / `Subscriptions/`）**：左选账号、右看额度圆环与余额，无账号 ID 且官方余额完全相同的多把 API Key 合并为一行（`SubscriptionCardGroup`，逐把可移除）；支持 PKCE 授权码（Claude、Gemini）、设备码（Codex、Kimi、GitHub Copilot、Grok）、浏览器登录轮询（WorkBuddy、WorkBuddy AI、ZCode）、API Key 手动或一键导入（DeepSeek、OpenCode Go、MiniMax、Kimi）及 Antigravity 本机只读自动识别；另提供本地 Codex 多账号切换（`CodexAccountSwitcher`）。
  - **状态栏、刘海 HUD 与任务提醒**：状态栏左键弹出 `MenuBarPanelView`（今日用量、配额、固定端口、最近会话）；内置刘海屏左侧可选显示配额圆环（`NotchHUDController`）；`TokenTrackerHook` 通过每用户私有临时目录 Unix Socket 与 `TaskHookServer` 通信，支持 Claude Code / Codex（CLI 与桌面本地会话）的 `PermissionRequest` 卡片内「允许一次 / 拒绝一次」审批代答与完成提醒，以及 Antigravity（`~/.gemini/config/hooks.json`）的会话提醒、工作区映射与一键切回原应用。
  - **设置（`SettingsView`）**：收拢为 5 类（`通用`、`外观与状态栏`、`提醒与集成`、`数据与同步`、`关于与更新`），兼容旧 8 分类持久化键；统一管理三类工具的 Hooks 差异预览与安装卸载，支持应用内更新与测试版更新通道（`UpdateChecker` / `UpdateInstaller`）。
  - **滚动与布局性能（`ScrollPerformance.swift`）**：`ScrollActivity` 在滚动期间 O(1) 抑制悬停重绘，以单遍测量 `Adaptive*Layout` 替代嵌套 `ViewThatFits`，长列表采用 `LazyVStack` 按行卡片渲染并复用日期格式化器。

## 仓库地图

- `swift/Sources/TokenTrackerCore/`：无 UI 依赖的核心模块，含 `Scanners/`、`Store/`、`Pricing/`、`Billing/`、`Quotas/`、`Subscriptions/`、`Activity/`、`Insights/`、`Ports/`、`Tasks/`、`Accounts/`、`Resume/`、`Transcript/`、`MenuBar/`、`Public/`、`Settings/`、`Differential/` 及 `ScanScheduler`、`UpdateChecker`、`UpdateInstaller`。业务计算放这里，不放 App。
- `swift/Sources/TokenTrackerApp/`：SwiftUI/AppKit 状态栏、速览面板、刘海 HUD、任务提醒浮层、主窗口各视图、设置与应用内更新。
- `swift/Sources/tt-swift/`：原生 CLI（`detect`、`scan`、`stats`、`sessions`、`transcript`、`activity`、`quotas`、`subscriptions`、`antigravity-hook`、`export-public`、`publish`）；根目录 `./tt` 首次运行时构建它。
- `swift/Sources/TokenTrackerHook/`：随 App 打包的任务提醒与 Antigravity 工作区映射 Hook 入口。
- `swift/Tests/`：`TokenTrackerCoreTests`（含 `Fixtures/`）与 `TokenTrackerAppTests`。
- `web/worker/`：公开统计的 Cloudflare Worker 与载荷校验器；`tests/test_web.js` 是校验器回归。
- `scripts/`：App 打包、开发运行、DMG 发布与图标检查。
- `docs/`：口径、迁移与功能设计说明；`*-plan.md`、`*-release-notes.md`、`*-validation.md` 是历史记录，与当前代码不一致时以代码为准并指出差异。

## 常用命令

```bash
swift build --package-path swift
swift test --package-path swift
swift test --package-path swift --filter DifferentialScanTests
./scripts/run_swift_dev.sh            # 构建并启动 build/TokenTracker Dev.app
./scripts/build_swift_app.sh          # 打包 dist/TokenTracker.app
node tests/test_web.js                # Web 载荷校验器
```

- 扫描 DSH 和差分测试需要系统 `zstd`（`brew install zstd`）。差分测试会把语料复制到 `/tmp/tt_diff_corpus`，基线内嵌该路径。
- 完整检查清单以 `.github/workflows/ci.yml` 为准。
- 开发副本 bundle ID 为 `com.tokentracker.desktop.v2.dev`，生产为 `com.tokentracker.desktop.v2`。日常调试用开发副本，不改动生产 App 的身份与安装。

## 数据边界

- 扫描与 Activity 持久化保持本地、只记元数据，不存 prompt、工具调用参数或文件内容。会话「对话」预览只在用户打开时从原始日志只读解析到内存，不写入用量库或缓存；Markdown 仅在用户主动导出/复制时落到其选择的位置。`exact`、`derived`、`unknown`、`unavailable` 保持区分，缺失数据不显示为零。
- 计价只用 `~/.tokentracker/prices.json` 中供应商、模型、事件时间精确匹配的费率；无匹配则保留 Token、费用未计价，不用默认价或子串匹配；放宽仅限把转发前缀（`relay/model`）、已知来源别名和推理强度后缀去掉后再精确匹配，早于模型首个价格版本的事件按首个版本回溯估算。细节见 `docs/metrics.md`。
- 端口信息（含完整命令行）只在内存中，不写入用量库，也不进入公开统计。结束进程前须确认，不对系统进程或其他用户的进程提供关闭。
- 订阅查询使用 TokenTracker 自己的账号库 `~/.tokentracker/subscription_accounts.json`，不读取其他软件的配置或登录态；唯一例外是 Antigravity 只读自动识别本机钥匙串（`service=gemini, account=antigravity`）与 Antigravity IDE `state.vscdb`，凭据仅留内存、不落盘且不改写原工具登录态（见 `docs/subscriptions.md`）。
- 任务提醒 Hook 通过每用户私有临时目录 Unix Socket（`confstr(_CS_DARWIN_USER_TEMP_DIR)` 下的 `tt-tasks-<uid>-dev|app`，0700/0600，校验 peer UID）通信；审批参数仅在等待期间留存内存，处理或失效后立即清除，不写入 `task-reminders.json` 历史或日志（见 `docs/task-reminders.md`）。
- 公开统计字段以 `swift/Sources/TokenTrackerCore/Public/PublicStatsPayload.swift` 和 `swift/Tests/TokenTrackerCoreTests/Fixtures/public_stats_v1.json` 为准，服务端校验器拒绝未知字段。新增公开字段须说明内容并取得授权，同时更新客户端白名单测试和 `web/worker` 校验器。
- `~/.tokentracker/` 下是用户真实数据（`usage.db`、设置、价格目录、凭据备份）。测试、迁移与账号切换使用临时目录、虚构日志和凭据；不以清空真实用量库或替换真实登录态作为调试手段。

## 修改约定

- 修改前查看相关文件的工作区差异，保留已有改动。
- 扫描口径、去重或成本计算的有意变更，须同步更新 `swift/Tests/TokenTrackerCoreTests/Fixtures/differential/expected.json`，并在提交信息中说明原因。
- 数据库结构或数据修正须提升 `UsageStore.schemaVersion`（当前为 `8`），保留一致性备份与事务升级，补充 `StoreMigrationTests`，并在 `docs/migrations.md` 记录。
- 界面默认语言为中文（`defaultLocalization: zh-Hans`）。新增文案同时写入 `zh-Hans.lproj` 和 `en.lproj` 的 `Localizable.strings`。

## 验证与完成

- 按改动选择受影响的测试：共享数据契约变化加差分验证，Web 载荷变化加校验器测试，纯文档改动无需构建。
- 已授权的本地修复包含相关测试及失败修复，无需逐阶段再次确认。检查通过后，只有新改动或未解决问题才扩大验证。
- UI 改动须在实际运行的 App 中检查受影响界面；构建成功不能代替 UI 验收。
- `TT_LIVE=1`（`LiveQuotaTests`）会访问真实凭据与官方接口，仅在真实配额验证属于授权范围时启用。`TT_DMG`（`LiveInstallTests`）安装到临时 App，不操作 `/Applications`。
- 等待时绑定具体完成事件并设置超时；环境阻塞时继续独立工作，不靠固定睡眠或无变化轮询证明完成。

## 发布

- 发布、制作 DMG 或验证更新安装链路时，按 `.agents/skills/tokentracker-release/SKILL.md` 执行。
- 按已有授权完成发布步骤；未获授权的提交推送、GitHub Release 或真实安装暂停在对应动作前。分别报告构建、UI、提交、推送、Release、CI 和安装状态。

## 工具选择

- 这是原生 macOS App：不因 SwiftUI、窗口或趋势图等关键词触发 Figma、HTML 图表或网页重建流程。
- 原生 App 验收用桌面工具；只有 `web/` 相关页面用浏览器工具。
