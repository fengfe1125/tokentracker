# TokenTracker SwiftUI

`swift/` 是 TokenTracker 唯一的桌面 App 实现，包含无 UI 依赖的 Core、
SwiftUI/AppKit macOS App、原生 CLI 和 XCTest。迁移 Phase 0–5 已完成；
Python 只暂留 CLI 与差分 oracle，不再提供桌面或浏览器界面。

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
  TokenTrackerApp/ 状态栏、主窗口、详情窗口、设置和应用内更新
  tt-swift/        detect、scan、stats、activity、quotas
Tests/
  TokenTrackerCoreTests/
```

## 构建和测试

```bash
swift build --package-path swift
swift test --package-path swift
./scripts/build_swift_app.sh
open dist/TokenTracker.app
```

打包结果使用 bundle ID `com.tokentracker.desktop.v2`，最低支持 macOS 14。
发布 DMG 使用 `./scripts/release_swift.sh`。

## 差分验证

`DifferentialScanTests` 使用 `/tmp/tt_diff_corpus` 中的虚构语料，
与 `tests/differential/expected_python.json` 逐字段比较。语料不存在时会调用
`tests/differential/make_corpus.py` 生成，需要 `python3` 和系统 `zstd`。

Python CLI 与 Swift 共用以下兼容数据：

- `~/.tokentracker/usage.db`（schema v6；用量事件保留供应商和费率版本）
- `~/.tokentracker/settings.json`
- `~/.tokentracker/prices.json`（供应商官方公开费率目录，按事件时间版本化）
- `~/.tokentracker/official_cache.json`
- `~/.tokentracker/claude_cred_backup.json`

迁移设计、模块映射和验收记录见 `docs/swiftui-migration-plan.md`。
