# TokenTracker SwiftUI 迁移记录

## 结论

Python 桌面版和浏览器仪表盘已经由原生 SwiftUI/AppKit App 完整替代并退役。
Swift 实现复用既有用户数据格式和 bundle ID；Python 暂时只保留 CLI 与差分 oracle。

## 当前架构

```text
TokenTrackerCore
  Scanners      七个工具适配器与增量扫描
  Store         SQLite schema v2、迁移、聚合和查询
  Pricing       价格表与成本计算
  Quotas        本地窗口和官方配额合并
  Billing       Claude、Kimi、Codex、OpenCode Go
  Resume        会话恢复与终端启动
  Settings      设置持久化
  ScanScheduler 单飞扫描与定时调度

TokenTrackerApp
  NSStatusItem、SwiftUI 主面板、会话详情、设置和应用内更新

tt-swift
  detect、scan、stats、quotas
```

## 已完成阶段

1. 建立 SwiftPM Core、App、CLI 和 Python 差分基线。
2. 移植七个扫描器、SQLite 存储、计价、本地配额和数据库迁移。
3. 完成状态栏、主面板、设置、Swift Charts 和定时扫描。
4. 移植四家官方配额、缓存退避和凭据刷新语义。
5. 完成会话恢复、登录项、更新检查、应用内安装和 DMG 发布。
6. 使用同名 `TokenTracker.app` 与 `com.tokentracker.desktop` 完成主力切换。
7. 退役 Python 桌面、HTTP 服务、Web 前端和 PyInstaller 构建链。

## 兼容边界

- 数据库继续使用 `~/.tokentracker/usage.db`，schema 版本保持 2。
- 设置、官方缓存和凭据快照路径保持不变。
- Swift 与冻结的 Python 语料基线逐字段比较，避免扫描和聚合语义漂移。
- 根目录 `./tt` 暂时仍是 Python CLI；原生 CLI 尚未覆盖 `--tool`、`--reset` 和按工具统计。
- 浏览器仪表盘不再提供，也不计划迁移。

## 验收门槛

- Python CLI 与扫描核心测试通过；
- Swift XCTest 与差分测试通过；
- App 冷启动、状态栏、主窗口、会话详情和更新流程可用；
- 构建产物签名、bundle ID、版本号、图标和 `LSUIElement` 正确；
- 不修改真实用户数据库来完成测试。
