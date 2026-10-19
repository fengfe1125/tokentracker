# TokenTracker

## 实现与兼容性

- macOS 桌面实现位于 `swift/`：Core 承担扫描、存储和业务计算，App 承担 SwiftUI/AppKit 展示与交互。
- Python CLI 仍用于兼容和差分验证。修改共享 schema、扫描口径、去重或成本计算时，检查两端对应实现；纯 App 改动无需扩展到 Python。
- 修改前查看相关文件的工作区差异，保留已有改动。

## 数据边界

- 扫描与 Activity 持久化保持本地、元数据限定。`exact`、`derived`、`unknown`、`unavailable` 保持区分，缺失数据不显示为零。
- 公开统计字段以 `swift/Sources/TokenTrackerCore/Public/PublicStatsPayload.swift` 和 `swift/Tests/TokenTrackerCoreTests/Fixtures/public_stats_v1.json` 为准。新增公开字段须明确说明内容并取得授权。
- 迁移与账号切换测试使用临时数据库、虚构日志和凭据。不以清空真实用量库或替换真实登录态作为调试手段。

## 按需读取

- 桌面结构与开发入口：`swift/README.md`。
- 指标、时间范围、成本与去重：`docs/metrics.md` 及对应实现。
- 数据库兼容与恢复：`docs/migrations.md` 及两端 Store 实现。
- 检查命令：`.github/workflows/ci.yml`。历史计划按需查阅；与当前代码不一致时明确指出差异。
- 发布、制作发行包或验证更新安装链路：`.agents/skills/tokentracker-release/SKILL.md`。

## 验证与完成

- 按改动选择受影响的测试；共享数据契约变化增加两端及差分验证，Web 载荷变化增加验证器测试。纯文档改动无需构建 App。
- 已授权的本地修复包含相关测试及失败修复，无需逐阶段再次确认。检查通过后，只有新改动或未解决问题才扩大验证。
- UI 改动检查实际受影响界面；发布前检查最终打包 App。构建成功不能代替 UI 验收。
- `TT_LIVE=1` 会访问真实凭据与官方接口，仅在真实配额验证属于已授权范围时启用。`TT_DMG` 安装测试使用临时 App，无需安装到系统。
- 按已有授权完成发布步骤；未获授权的外部发布或真实安装暂停在对应动作前。分别报告已执行步骤的构建、UI、提交、推送、Release、CI 和安装状态。
- 等待绑定具体完成事件并设置超时；环境阻塞时继续独立工作，不靠固定睡眠或无变化轮询证明完成。

## Skills 选择

- 原生界面开发不因 SwiftUI、窗口或趋势图等关键词触发 Figma、HTML 图表或网页重建流程。按实际交付形式选 Skill。
- 只有 Figma 与 SwiftUI 转换才使用 `figma-swiftui`；原生 App 验收使用桌面工具，Web 页面验收使用浏览器工具。
