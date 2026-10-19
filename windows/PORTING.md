# Swift → C# 移植对照

Windows 版是第三套实现。修改扫描器 / 存储 / 计价 / 配额逻辑时，三套实现要一起改，并由同一份差分基线
（`tests/differential/expected_python.json`）把关。与 Python 行为冲突时以 Python 为准（基线由它生成）。

最后同步的 Swift 提交：`09f38fd`（v0.3.4）。

| Swift（`swift/Sources/`） | C#（`windows/src/`） |
|---|---|
| `TokenTrackerCore/Store/SQLite.swift` | `TokenTracker.Core/Store/SqliteDb.cs` |
| `TokenTrackerCore/Store/PythonJSON.swift` | `TokenTracker.Core/Store/PythonJson.cs`、`Json/PyJson.cs` |
| `TokenTrackerCore/Store/UsageStore.swift` | `TokenTracker.Core/Store/UsageStore*.cs` |
| `TokenTrackerCore/Insights/InsightsStore.swift`（schema、recordProjectPath、recordHealth） | `TokenTracker.Core/Store/UsageStore.Insights.cs` |
| `TokenTrackerCore/Insights/InsightRules.swift`（recordQuota） | `TokenTracker.Core/Store/UsageStore.Insights.cs` |
| `TokenTrackerCore/Activity/ActivityEvent.swift` | `TokenTracker.Core/Activity/ActivityEvent.cs` |
| `TokenTrackerCore/Pricing/PriceTable.swift` | `TokenTracker.Core/Pricing/PriceTable.cs` |
| `TokenTrackerCore/Scanners/ScannerSupport.swift`、`ScanDiagnostics.swift` | `TokenTracker.Core/Scanners/ScannerSupport.cs` |
| `TokenTrackerCore/Scanners/ScannerAdapter.swift` | `TokenTracker.Core/Scanners/ScanRunner.cs` |
| `TokenTrackerCore/Scanners/{Claude,Codex,Kimi,Dsh,Pi,Opencode,Hermes}Scanner.swift` | `TokenTracker.Core/Scanners/*Scanner.cs` |
| `TokenTrackerCore/Quotas/QuotaEstimator.swift` | `TokenTracker.Core/Quotas/QuotaEstimator.cs` |
| `TokenTrackerCore/Billing/*.swift` | `TokenTracker.Core/Billing/*.cs`（只读版，见 README） |
| `TokenTrackerCore/Billing/CliFind.swift` | `TokenTracker.Core/Platform/CliFind.cs` |
| `TokenTrackerCore/Settings/SettingsStore.swift` | `TokenTracker.Core/Settings/SettingsStore.cs` |
| `TokenTrackerCore/ScanScheduler.swift` | `TokenTracker.Core/Scheduling/ScanScheduler.cs` |
| `TokenTrackerCore/MenuBar/MenuBarFormatter.swift` | `TokenTracker.Core/Presentation/TrayFormatter.cs` |
| `TokenTrackerCore/UpdateChecker.swift` | `TokenTracker.Core/Updates/UpdateChecker.cs` |
| `TokenTrackerCore/Differential/ExpectedExport.swift` | `windows/tests/TokenTracker.Core.Tests/Differential/DifferentialScanTests.cs` |
| `tt-swift/main.swift`（detect/scan/stats/quotas） | `TokenTracker.Cli/Program.cs` |
| `TokenTrackerApp/Localization.swift` | `TokenTracker.Core/Localization/L10n.cs`、`TokenTracker.Windows/Localization/Tr.cs` |
| `TokenTrackerApp/Formatting.swift` | `TokenTracker.Windows/ViewModels/UiFormat.cs` |
| `TokenTrackerApp/AppState.swift`（MVP 子集） | `TokenTracker.Windows/ViewModels/AppViewModel*.cs` |
| `TokenTrackerApp/AppDelegate.swift`、`AppLaunchPolicy.swift` | `TokenTracker.Windows/App.xaml.cs`、`Lifecycle/Lifecycle.cs` |
| `TokenTrackerApp/StatusItemController.swift` | `TokenTracker.Windows/Tray/*.cs` |
| `TokenTrackerApp/Views/RootView.swift` | `TokenTracker.Windows/Shell/MainWindow.xaml` |
| `TokenTrackerApp/Views/OverviewView.swift` | `TokenTracker.Windows/Views/OverviewPage.xaml` |
| `TokenTrackerApp/Views/HandDrawnTrendChart.swift` | `TokenTracker.Windows/Controls/TrendChart.cs` |
| `TokenTrackerApp/Views/SessionsView.swift`、`SessionDetailView.swift`（信息 / 摘要 / 按模型） | `TokenTracker.Windows/Views/SessionsPage.xaml` |
| `TokenTrackerApp/Views/SettingsView.swift`（MVP 部分） | `TokenTracker.Windows/Views/SettingsPage.xaml` |

## 有意的差异

- Hermes：有两处数据目录（`~\.hermes`、`%LOCALAPPDATA%\hermes`），`HERMES_HOME` 设置时只看它；
  跳过 `state-snapshots`；缺 `session_model_usage` 表的库只读活动并警告，不让整个工具失败。
- DSH：相对路径同时按 `\` 与 `/` 切分；兜底身份统一为 `/` 分隔。
- 项目路径：`hasPrefix("/")` 换成 `WinPaths.IsAbsoluteProjectPath`（Windows 全限定路径或 POSIX 路径）。
- 文件指纹：`GetFileInformationByHandle`（卷序列号 + 文件索引 + 最后写入时间 + 大小）。
- 官方配额只读；不读钥匙串、不刷新令牌、不写 `claude_cred_backup.json`。
- `Pi` 工具调用兜底键、`Kimi` seq 等按 Python `str()` 语义格式化（Swift 用 `String(describing:)`）。
