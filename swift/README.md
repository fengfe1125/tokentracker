# TokenTracker SwiftUI

`swift/` 是 TokenTracker 唯一的桌面 App 实现，包含无 UI 依赖的 Core、
SwiftUI/AppKit macOS App、原生 CLI 和 XCTest。迁移 Phase 0–5 已完成，
Python 实现已移除。

## 结构

```text
Sources/
  TokenTrackerCore/
    Billing/       Claude、Kimi、Codex、OpenCode Go 官方配额
    Activity/      工具与 Skill 活动模型、归一化和证据等级
    MenuBar/       状态栏格式化纯逻辑
    Pricing/       价格表与成本计算
    Quotas/        本地窗口和官方配额合并
    Resume/        会话恢复与终端启动
    Scanners/      七个工具的数据源适配器
    Settings/      settings.json 读写
    Store/         SQLite schema、迁移、聚合和查询
    Subscriptions/ 自有登录与 API Key 账号库、订阅配额与余额只读查询
  TokenTrackerApp/ 状态栏、主窗口、详情窗口、设置和应用内更新
  tt-swift/        detect、scan、stats、activity、quotas、subscriptions
Tests/
  TokenTrackerCoreTests/
```

## 构建和测试

```bash
swift build --package-path swift
swift test --package-path swift
./scripts/build_swift_app.sh
./scripts/run_swift_dev.sh
```

默认打包结果 `dist/TokenTracker.app` 使用生产 bundle ID
`com.tokentracker.desktop.v2`。本地运行入口会在独立目录构建并启动
`build/TokenTracker Dev.app`，其 bundle ID 为
`com.tokentracker.desktop.v2.dev`，避免开发副本改变生产菜单栏身份。
两者最低支持 macOS 14。
发布 DMG 使用 `./scripts/release_swift.sh`。

## 差分验证

`DifferentialScanTests` 把 `Tests/TokenTrackerCoreTests/Fixtures/differential/corpus`
复制到 `/tmp/tt_diff_corpus`（基线内嵌该绝对路径），扫描后与同目录的
`expected.json` 逐字段比较。基线由已移除的 Python 实现导出并冻结；扫描器有意
变更行为时，按新的正确结果手动更新基线并在提交信息里说明。扫描 DSH 需要系统 `zstd`。

App 与 CLI 共用以下本机数据：

- `~/.tokentracker/usage.db`（schema v6；用量事件保留供应商和费率版本）
- `~/.tokentracker/settings.json`
- `~/.tokentracker/prices.json`（供应商官方公开费率目录，按事件时间版本化）
- `~/.tokentracker/official_cache.json`
- `~/.tokentracker/claude_cred_backup.json`

迁移设计、模块映射和验收记录见 `docs/swiftui-migration-plan.md`。
