# TokenTracker SwiftUI 重构（swift/）

整体计划见 `docs/swiftui-migration-plan.md`。当前进度：**Phase 0–3 完成**
（脚手架 + 差分基建 + Core 移植 + App 壳 + 官方配额抓取），
下一步 Phase 4（会话恢复 + 开机启动 + 更新检查）。

当前 Swift 版能力：状态栏常驻（分段着色标题 + 彩色配额圆 + 动画降级 +
Tahoe 自愈）、主面板（概览统计卡 / Swift Charts 趋势图 / 配额卡 / 模型榜 /
会话记录与详情）、设置（settings.json 双向同步 + SMAppService 登录项）、
60s 自动扫描、**四家官方配额（Claude 三级回退 / Kimi 自刷新 / Codex wham+RPC
兑底 / OpenCode Go）**，含缓存退避与跨进程磁盘共享（与 Python 版共用
official_cache.json）。

## 结构

```
swift/
├── Package.swift                  # SwiftPM 包（macOS 14+，零第三方依赖）
├── Sources/
│   ├── TokenTrackerCore/          # 无 UI 依赖的核心包（Phase 1 完成）
│   │   ├── Store/
│   │   │   ├── SQLite.swift           # 系统 libsqlite3 薄封装（事务/备份/行字典）
│   │   │   ├── UsageStore.swift       # db.py 全量：schema v2 迁移/putEvent/聚合快照/查询
│   │   │   └── PythonJSON.swift       # json.dumps 转义 + sha256 + half-even 舍入
│   │   ├── Scanners/
│   │   │   ├── ScannerSupport.swift   # _util.py：指纹/字节游标/JSONL/zstd/标题提取
│   │   │   ├── ScannerAdapter.swift   # 协议 + 注册表 + ScanRunner（run_all 语义）
│   │   │   ├── ClaudeScanner.swift    # 以下七个对齐 scanners/*.py
│   │   │   ├── CodexScanner.swift     # JSONL+SQLite 双源补缺（最复杂）
│   │   │   ├── OpencodeScanner.swift  # 累计快照
│   │   │   ├── DshScanner.swift       # zstd 事件流
│   │   │   ├── HermesScanner.swift    # 多 profile 快照 + 归属仲裁
│   │   │   ├── KimiScanner.swift      # 事件日志逐步增量
│   │   │   └── PiScanner.swift        # 官方 cost 优先
│   │   ├── Pricing/PriceTable.swift   # pricing.py（精确→最长子串→default）
│   │   ├── Quotas/QuotaEstimator.swift # quotas.py 本地估算 + 官方合并
│   │   ├── Differential/ExpectedExport.swift # 差分基线解码模型
│   │   ├── Billing/                 # billing.py 全量：Claude/Kimi/Codex/Go 官方配额
│   │   └── TokenTrackerCore.swift     # 公共常量（schema v2 等）
│   ├── TokenTrackerApp/           # SwiftUI 桌面壳（状态栏 + 主面板）
│       ├── TokenTrackerApp.swift  # @main；Settings 场景（⌘,）
│       ├── AppDelegate.swift      # 组装：状态栏 + 主面板 + 5s 轮询
│       ├── AppState.swift         # 数据中枢（读写 store 分离 + ScanScheduler）
│       ├── StatusItemController.swift  # menubar.py 移植（富文本标题/配额圆/自愈）
│       ├── MainWindowController.swift  # 关闭只隐藏不退出
│       └── Views/             # RootView / OverviewView / SessionsView / SettingsView
│   └── tt-swift/                  # 原生 CLI：detect/scan/stats/quotas（替代 Python tt）
└── Tests/TokenTrackerCoreTests/   # 135 个 XCTest（1 个真机验收默认跳过）
```

## 构建 / 测试 / 运行

```bash
swift build --package-path swift           # 或 cd swift && swift build
swift test  --package-path swift           # Core 单测 + 差分对拍（硬门槛）
./scripts/build_swift_app.sh               # 打包 dist/TokenTracker.app（同名同 bundle id 覆盖旧版）
open dist/TokenTracker.app                 # 状态栏常驻；安装：cp -R dist/TokenTracker.app /Applications/
```

## 差分对拍（Phase 1 验收机制）

`DifferentialScanTests` 跑 Swift 扫描器扫 `/tmp/tt_diff_corpus`，与 Python 基线
`tests/differential/expected_python.json` 逐字段比对（16 事件 / 7 标题 /
4 快照 / 7 scan_results）。语料不存在时测试会自动调用
`tests/differential/make_corpus.py` 生成（需 python3 + zstd）。
详见 `tests/differential/README.md`。

## 约定

- 数据目录与 Python 版共用 `~/.tokentracker/`（usage.db schema v2、
  settings.json、prices.json、quotas.json），两版可并存；
- **零第三方依赖**：存储层用系统 libsqlite3 薄封装而非 GRDB（离线可构建、
  与 Python sqlite3 语义逐点对齐）；
- 时钟全部可注入（`UsageStore.nowMs`），测试冻结对齐 Python 的
  `db.time.time` 冻结；
- 每个 Python 模块移植时，同步把对应 unittest 用例搬进
  `Tests/TokenTrackerCoreTests/`，并先过差分对拍。
