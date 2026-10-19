# TokenTracker for Windows

Windows 版是 C#/.NET 8 + WPF 的原生实现，与 macOS 版（`swift/`）、Python CLI（`tokentracker/`）共用：

- 数据库 `%USERPROFILE%\.tokentracker\usage.db`（同一 schema v5、同一游标键）
- 设置 `%USERPROFILE%\.tokentracker\settings.json`（同一白名单键）
- 价格表（构建时嵌入仓库根 `prices.json`）、界面文案（嵌入 macOS 的 `Localizable.strings`）
- 差分测试基线 `tests/differential/expected_python.json`

## 第一期（MVP）功能

托盘常驻（配额环图标 + 悬停提示 + 右键菜单）、自动扫描、概览（汇总 / Token 分解 / 缓存命中率 /
手绘趋势 / 订阅配额 / 模型榜）、会话记录（搜索、排序、详情抽屉）、设置（托盘显示、语言、开机自启、
数据目录、更新检查）。

与 macOS 版的差异：

- **官方配额只读**：不刷新登录令牌、不回写任何 CLI 的凭据文件。令牌过期时显示 24h 内的官方缓存（`~`）
  或本地估算（`≈`），运行一次对应 CLI 后自动恢复。Codex 失败时委托官方 `codex app-server` 取数。
- 托盘没有文字标题：圆环 = 所选配额的最紧窗口，今日用量在悬停提示里。
- 二期：Agent Activity、项目洞察 / 预算 / 周报、公开统计、应用内更新、终端续跑会话、Codex 多账号。

## 开发

需要 .NET 8 SDK（`winget install Microsoft.DotNet.SDK.8`）；差分测试需要 Python 3 与 `zstd` 在 PATH 上。

```powershell
dotnet build windows/TokenTracker.Windows.sln
dotnet test windows/TokenTracker.Windows.sln        # 含与 Python 基线逐字段比对的差分测试
dotnet run --project windows/src/TokenTracker.Windows
```

开发检查用 CLI（不进发布包）：

```powershell
dotnet run --project windows/src/TokenTracker.Cli -- detect
dotnet run --project windows/src/TokenTracker.Cli -- scan
dotnet run --project windows/src/TokenTracker.Cli -- stats --range week
dotnet run --project windows/src/TokenTracker.Cli -- quotas
```

`TOKENTRACKER_DB` 可把扫描写到临时库，避免动真实数据。界面自检：设置 `TT_SNAPSHOT_DIR=<目录>`
（可加 `TT_SNAPSHOT_QUIT=1`）启动应用，会把三个页面渲染成 PNG。

## 发布

```powershell
pwsh windows/scripts/publish.ps1     # → dist/TokenTracker-<版本>-win-x64.zip
```

自包含（用户无需安装 .NET），版本号取自 `swift/Sources/TokenTrackerCore/TokenTrackerCore.swift`。
**zip 必须和 macOS 的 DMG 挂在同一个 GitHub Release 上**：macOS 更新器只认 `releases/latest` 的 `.dmg`，
单独发一个只有 Windows 包的 release 会让 Mac 用户看到「没有 .dmg」。

当前未签名，首次运行会出现 SmartScreen 提示（「更多信息 → 仍要运行」）。

图标由 `windows/scripts/make_ico.ps1` 从 `assets/icon_1024.png` 生成。

## 相关文档

- [PORTING.md](PORTING.md)：Swift → C# 文件对照
- [../docs/windows-port.md](../docs/windows-port.md)：Windows 路径与键的规范（写进 usage.db，改动需迁移）
