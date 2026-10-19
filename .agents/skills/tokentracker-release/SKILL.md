---
name: tokentracker-release
description: 准备 TokenTracker 发布、制作发行包或验证更新安装链路时使用；普通开发和单元测试不触发。
---

# TokenTracker 发布

从仓库根目录执行命令。范围以用户要求为准：本地打包、外部发布和替换已安装 App 是不同动作；沿用已有授权，仅在新增动作需要授权时暂停。

## 产物与版本

- 先检查工作区差异及待发布内容，保留无关改动；不把未审阅的 WIP 顺带提交或发布。
- 版本来源是 `swift/Sources/TokenTrackerCore/TokenTrackerCore.swift` 的 `version`，打包脚本将其写入 Info.plist。只在任务包含版本升级时改版本。
- 升版本时同步 `tokentracker/__init__.py` 的 `__version__`；`tests/test_smoke.py` 会校验两端一致。
- App 打包入口为 `scripts/build_swift_app.sh`；DMG 入口为 `scripts/release_swift.sh`，后者已包含 App 构建，无需重复运行前者。
- 脚本重建 `dist/TokenTracker.app` 和同版本 DMG。需要保留旧产物时先另存副本。
- 默认签名是 ad-hoc；Developer ID 与公证按当前脚本说明及可用凭据执行，不把 ad-hoc 产物报告为已公证。

## 发布验证

- 按发布变更选择 `.github/workflows/ci.yml` 中相关检查；复用针对同一份未再改动代码已通过的结果。
- 核对最终 App 的版本、bundle ID、可执行文件和签名，保持 `com.tokentracker.desktop.v2` 及状态栏 App 配置。
- 用桌面工具打开最终 `dist/TokenTracker.app`，确认正在检查本次产物，查看状态栏、主窗口及本次变更涉及的交互。不要把旧运行实例当作本次验收。
- 需要隔离验收数据时，检查实际数据源、数据库、设置和凭据路径注入；仅重定向数据库不能视为完全隔离。真实账号切换或公开上传只在授权范围内操作。
- 验证安装链路时，可运行 `TT_DMG="<本次 DMG 的绝对路径>" swift test --package-path swift --filter LiveInstallTests`。它安装到临时假 App，验证替换和失败保护，不操作 `/Applications`。
- `TT_LIVE=1` 是访问真实凭据与官方配额接口的独立检查，不是发布必跑项。
- 缺少桌面工具或环境导致无法验收时，报告具体缺口；不得以编译、截图文件存在或单元测试通过代替实际 UI 验收。

## 已授权的外部发布

- 从仓库 remote 和现有发布约定确认目的地；只提交属于本次发布的变更。
- 核对提交、tag、Release 和上传资产对应本次版本；GitHub 发布不会由本地打包脚本自动完成。
- 用实际远端结果核验推送和资产状态；单独的认证状态输出不能替代操作结果。
- 等待 CI 或上传时使用有截止条件的完成状态检查；失败先定位原因，无状态变化时退避，不无限轮询。
- 汇报实际完成的步骤、产物路径、签名类型及尚未完成的验收。只有明确包含安装时才替换用户已安装 App。
