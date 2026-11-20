# TokenTracker

本机 AI 编程工具用量追踪器：扫描 Claude Code、Codex、Kimi、OpenCode 等工具的本地日志，统计 Token、成本、配额与活动，以 macOS 状态栏 App 和 CLI 呈现。Python 实现已移除，`swift/` 是唯一实现。

## 仓库地图

- `swift/Sources/TokenTrackerCore/`：无 UI 依赖的扫描、存储、计价、配额、端口、订阅与公开统计逻辑。业务计算放这里，不放 App。
- `swift/Sources/TokenTrackerApp/`：SwiftUI/AppKit 状态栏、速览面板、主窗口、设置与应用内更新。
- `swift/Sources/tt-swift/`：原生 CLI；根目录 `./tt` 首次运行时构建它。`TokenTrackerHook` 是任务提醒 Hook 入口。
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

- 扫描与 Activity 持久化保持本地、只记元数据，不存 prompt 或文件内容。`exact`、`derived`、`unknown`、`unavailable` 保持区分，缺失数据不显示为零。
- 计价只用 `~/.tokentracker/prices.json` 中供应商、模型、事件时间精确匹配的费率；无匹配则保留 Token、费用未计价，不用默认价或子串匹配。细节见 `docs/metrics.md`。
- 端口信息只在内存中，不写入用量库，也不进入公开统计。结束进程前须确认，不对系统进程或其他用户的进程提供关闭。
- 订阅查询只用 TokenTracker 自己的账号库 `~/.tokentracker/subscription_accounts.json`，不读取其他软件的配置或登录态（见 `docs/subscriptions.md`）。
- 公开统计字段以 `swift/Sources/TokenTrackerCore/Public/PublicStatsPayload.swift` 和 `swift/Tests/TokenTrackerCoreTests/Fixtures/public_stats_v1.json` 为准，服务端校验器拒绝未知字段。新增公开字段须说明内容并取得授权，同时更新客户端白名单测试和 `web/worker` 校验器。
- `~/.tokentracker/` 下是用户真实数据（`usage.db`、设置、价格目录、凭据备份）。测试、迁移与账号切换使用临时目录、虚构日志和凭据；不以清空真实用量库或替换真实登录态作为调试手段。

## 修改约定

- 修改前查看相关文件的工作区差异，保留已有改动。
- 扫描口径、去重或成本计算的有意变更，须同步更新 `swift/Tests/TokenTrackerCoreTests/Fixtures/differential/expected.json`，并在提交信息中说明原因。
- 数据库结构或数据修正须提升 `UsageStore.schemaVersion`，保留一致性备份与事务升级，补充 `StoreMigrationTests`，并在 `docs/migrations.md` 记录。
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
