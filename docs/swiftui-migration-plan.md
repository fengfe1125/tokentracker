# TokenTracker SwiftUI 重构计划

> 目标：将现有 Python（pywebview + PyObjC + PyInstaller）实现整体迁移为原生
> SwiftUI macOS 应用，保留全部功能、数据格式与用户数据，分批交付、可随时回退。

## 1. 现状盘点

| 层 | 现状 | 规模 |
|---|---|---|
| 扫描器 | `tokentracker/scanners/`（claude / codex / opencode / dsh / hermes / kimi / pi 七个适配器，JSONL / SQLite / zstd 事件流，增量快照 + 身份去重） | ~900 行 |
| 存储 | `db.py`：SQLite 汇总库 `~/.tokentracker/usage.db`，SCHEMA_VERSION=2，事务式迁移，时间质量标注 | ~425 行 |
| 成本 | `pricing.py` + `prices.json`（精确→子串→default 回退） | ~70 行 |
| 官方配额 | `billing.py`：Claude 三级回退链（桌面采样文件→oauth/usage→CLI 委托刷新+凭据快照复活）、Kimi 自刷新（refresh_token 轮换 + flock + 原子写回）、Codex wham/usage + app-server RPC 兜底、OpenCode Go；缓存/退避/429 Retry-After | ~1126 行（最难啃） |
| 本地配额估算 | `quotas.py` + `quotas.json`（固定 5h/7d/月度窗口） | ~173 行 |
| 调度 | `server.py` 的 ScanService：单飞扫描锁 + 60s 定时增量扫描 | ~350 行 |
| 状态栏 | `app/menubar.py` + `menubar_fmt.py`：NSStatusItem 分段着色富文本标题、AppKit 矢量配额圆、动画降级、Tahoe 自愈（重排+重建） | ~870 行 |
| 主面板 | pywebview WKWebView + `app/web/`（HTML/CSS/JS + Chart.js），概览/会话/设置三视图 | ~1850 行 |
| 会话恢复 | `resume.py`：五个终端 App、目录回退、剪贴板降级 | ~180 行 |
| 其他 | `loginitem.py`（LaunchAgent）、`updatecheck.py`、`prefs.py`、`clifind.py` | ~250 行 |
| CLI | `tt scan/stats/detect/serve` | ~150 行 |
| 测试 | 13 个测试文件（unittest + node） | ~3300 行 |

**关键结论**：后端与 UI 已通过 HTTP API / JS 桥解耦，业务逻辑（扫描、存储、配额）是纯
数据进纯数据出，非常适合整体移植后在两套实现间做差分对比测试。

## 2. 目标架构

```
TokenTracker.xcodeproj
├── TokenTracker (SwiftUI App, macOS 14+)
│   ├── App 入口（MenuBarExtra 风格常驻 + Window 主面板 + Settings 场景）
│   ├── MenuBar/        NSStatusItem 封装（富文本标题 + 配额圆 + 自愈）
│   ├── Views/          Overview / Sessions / Settings / 详情抽屉
│   └── ViewModels/     @Observable 视图模型
└── TokenTrackerCore (Swift Package，无 UI 依赖，可单测)
    ├── Scanners/       七个适配器（协议 ScannerAdapter）
    ├── Store/          SQLite（GRDB 或裸 SQLite3，同 schema v2）
    ├── Pricing/        prices.json 匹配
    ├── Quotas/         本地窗口估算
    ├── Billing/        官方配额抓取（Keychain + URLSession）
    ├── Resume/         终端恢复
    └── ScanScheduler/  单飞锁 + 定时器
```

核心原则：**Core 包与 UI 完全分离**——Core 可被 App、CLI 目标、XCTest 三方复用，
也是与 Python 版做差分测试的对照单元。

## 3. 关键技术决策

| 决策点 | 结论 | 理由 |
|---|---|---|
| 部署目标 | macOS 14（Sonoma）+ | `@Observable`、Swift Charts、`MenuBarExtra` 均成熟；现状 README 已兼容 macOS 26 |
| 状态栏 | **保留 AppKit NSStatusItem**，菜单与面板内容用 SwiftUI（NSHostingView） | 现有实现依赖 attributedTitle 分段着色、NSBezierPath 矢量配额圆、动画降级、Tahoe 自愈重建；MenuBarExtra 的自定义 label 无法等价覆盖，硬迁会丢功能 |
| 图表 | Swift Charts 替代 Chart.js | 原生、离线、支持线性/对数 Y 轴切换 |
| SQLite | **GRDB.swift**（唯一第三方依赖，SwiftPM 引入）；备选裸 SQLite3 C API 零依赖 | schema、迁移、WAL 并发读取都已定型，GRDB 的 Record/迁移工具能省大量胶水 |
| 数据兼容 | **完全复用** `~/.tokentracker/`（usage.db / settings.json / prices.json / quotas.json / 凭据快照） | 两版可并存、随时回退；Swift 版首次启动执行与 Python 相同的迁移判断 |
| zstd（DSH） | 沿用 `Process` 调系统 `zstd`；后续可换 Compression 框架（macOS 15+ 含 zstd） | 与现状一致，不引入新依赖 |
| Keychain | Security 框架 SecItem* 直读「Claude Code-credentials」 | 对应 `_kc_read/_kc_write` |
| HTTP | URLSession（async/await）+ 结构化并发替代线程+缓存锁 | billing.py 的缓存/退避/429 语义用 actor 收口 |
| 定时扫描 | Core 内 `ScanScheduler` actor（单飞 + 60s Timer） | 对齐 ScanService 语义：定时与手动共用锁、运行中跳过 |
| 开机启动 | SMAppService.mainApp 替代手写 LaunchAgent | 同样仅限打包 .app，系统设置里可见可管 |
| 浏览器模式 `tt serve` | **砍掉**（原生面板全覆盖）；CLI 见 §6 | 减少一个要维护的前端 |
| 更新检查 | 保留现有 GitHub 版本检查逻辑（纯 HTTP，易移植）；Sparkle 留给后续 | 不阻塞首发 |
| 打包 | Xcode 归档 + 开发者签名/公证；复用 assets 里现有 ICNS/PNG | 替代 PyInstaller，体积从 ~40MB 降到几 MB |

## 4. 分阶段计划

### Phase 0 — 脚手架与差分基建 ✅ 已完成

已交付：

- `swift/` SwiftPM 包（macOS 14+）：`TokenTrackerCore` 库 + `TokenTrackerApp`
  SwiftUI 空壳（启动不弹窗、无 Dock 图标、NSStatusItem 常驻「⚡ --」、
  菜单可唤出主面板占位窗口、关闭只隐藏不退出）；`PriceTable` 已完整移植
  并对齐 `pricing.py`（精确 → 最长子串 → default → 不计费，half-even 舍入）。
- `tests/differential/` 差分基建：`make_corpus.py`（7 工具虚构语料，
  确定性可重复生成）+ `prices.json`（稳定价格表）+ `export_python.py`
  （冻结墙钟、规范化导出）+ 已提交基线 `expected_python.json`（16 事件 /
  7 会话标题 / 4 聚合快照）；`tests/test_differential.py` 挂入 unittest，
  断言两次导出逐字节一致且与基线一致。
- `scripts/build_swift_app.sh`：release 构建 → `dist/TokenTrackerSwift.app`
  （LSUIElement、复用 assets/icon.icns、ad-hoc 签名）。
- 验收已过：空壳进程常驻存活；`swift test` 7/7；Python 185 个测试全绿。

- 建 Xcode 工程 + SwiftPM Core 包 + SwiftUI App 空壳（图标、签名、最低版本）。
- **差分测试基建**：从 `tests/` 提取各工具日志样本为 fixture 语料库（脱敏），
  加一个 Python 小工具：对 fixture 跑 Python 扫描器 → 导出规范化 JSON
  （tool/session/ts/model/tokens/cost 排序后 dump）。
- 验收：空壳 App 能常驻状态栏；差分导出脚本对现有 fixture 可跑。

### Phase 1 — Core 移植：扫描 + 存储 + 成本 + 本地配额 ✅ 已完成（最大一块）

已交付（全部在 `swift/Sources/TokenTrackerCore/`）：

1. **Store**（`Store/SQLite.swift` + `Store/UsageStore.swift`）：决定**不引入
   GRDB**——用系统 libsqlite3 写了一个 ~200 行薄封装（参数绑定/行字典/事务/
   changes 计数/备份 API），零第三方依赖、离线可构建，与 Python sqlite3 语义
   逐点对齐。schema v2 + 迁移（flock 串行化、备份、migration_history、codex
   旧行重定价）+ putEvent + 游标 + **putSnapshot 聚合快照引擎**（含成本账本
   对账、native_adjustment、计数器重置基线）+ 全部查询（stats/daily/models/
   sessions/sessionDetail/window*/quotaUsage/reprice）。时钟可注入。
2. **Scanners**：七个适配器全部移植（`Scanners/*.swift`），含 codex 双源补缺
   状态机、字节游标增量读（自写 ByteLineReader，规避 Data 下标索引陷阱）、
   zstd 进程解压、user_text 标题提取；Python `or` 链 / dict 推导后写胜出 /
   严格 int 校验等语义均有对应实现。
3. **Quotas**（`Quotas/QuotaEstimator.swift`）：本地窗口估算 + 官方覆盖合并，
   官方源留 `officialProvider` 注入缝（Phase 3 填充 billing）。
4. **差分对拍通过**：`DifferentialScanTests` 用 Swift 扫描器跑同一语料，
   与 `expected_python.json` 逐字段一致（16 事件 / 7 标题 / 4 快照 /
   7 scan_results）。基线已改为机器无关路径（`/tmp/tt_diff_corpus`）。
5. **单测移植**：test_scanners.py 的 20 个 Codex 用例 + claude/dsh/kimi/pi +
   字节游标 + 标题提取；test_aggregate_scanners.py 全量 13 个（快照语义、
   归属仲裁、并发串行化简化版）；test_db_migrations.py 全量 3 个。
   共 62 个 XCTest 全绿；Python 185 个测试无回归。

踩坑记录（已修）：Any? 嵌套 Optional 绑定（SQLite 封装显式解包）；
realpath 用 Darwin.realpath（/tmp→/private/tmp）；Swift 字典赋 nil 等于删键
（hermes 归属仲裁用 .some(nil)）；局部变量 name 遮蔽协议属性（claude 循环）。

（移植顺序与验收标准见上方已完成记录。）

### Phase 2 — App 壳：状态栏 + 主面板 + 设置 ✅ 已完成

已交付：

- **Core**：`MenuBar/MenuBarFormatter.swift`（menubar_fmt.py 全量纯逻辑：分段
  标题/配额圆参数/紧急度/亿单位/动画曲线）、`Settings/SettingsStore.swift`
  （prefs.py + server.py 白名单校验，原子写入）、`ScanScheduler.swift`
  （ScanService 语义：单飞锁、60s 自动、可注入时钟/等待/线程）。
- **App**：`StatusItemController.swift`（menubar.py 移植：分段富文本标题、
  NSBezierPath 配额圆、旋转/闪光/脉冲动画 + 减少动态效果降级、Tahoe 自愈
  （不可见检测→重排→重建 + 30s 退避 + 60s 轻推）、app.log）；
  `MainWindowController.swift`（关闭只隐藏、无 Dock 图标、面板打开临时出现）；
  SwiftUI 视图：`RootView`（侧栏 = 视图 + 7 工具数据源状态与今日量）、
  `OverviewView`（4 统计卡 / Swift Charts 堆叠趋势图（线性/对数，极值比>30
  自动对数，手动切换记 @AppStorage）/ 配额环卡 / 模型榜）、`SessionsView`
  （可排序表 + 搜索 + 详情检查器：模型分解/观察区间/Finder 打开）、
  `SettingsView`（与 settings.json 双向同步 + SMAppService 登录项）。
  快捷键：⌘1/⌘2/⌘R（隐藏 Button）+ ⌘W（自建文件菜单）+ ⌘,（Settings 场景）。
- **验收**：88 个 XCTest 全绿（新增 menubar_fmt 纯逻辑 26 个、ScanService
  调度 4 个、设置校验 4 个）；真实数据冒烟：Swift 版扫真实日志入临时库，
  dsh/pi/kimi/opencode 与 Python 库**逐字节一致**；claude/codex 计数差异
  来自历史保留（旧文件已删除），hermes 差异来自快照差量积累——均为
  预期语义；二次启动幂等（+12 条均为扫描间隙的真实新增）；app.log 正常。
- 注意：官方配额（billing.py）在 Phase 3，当前状态栏/面板显示本地估算（≈）。

### Phase 3 — 官方配额抓取 billing.py 移植 ✅ 已完成（风险最高）

已交付（`swift/Sources/TokenTrackerCore/Billing/`，全部凭据路径经
`BillingContext` 注入，测试零真实凭据）：

1. **Claude**（`ClaudeBilling.swift`）：桌面采样文件（<30min）→ 钥匙串 /
   `~/.claude/.credentials.json` / 本地快照三源遍历（跳过空壳、按 expiresAt
   排序）→ 手写刷新（claude-cli UA）→ CLI 委托刷新（隔离 CLAUDE_CONFIG_DIR）→
   凭据有效自动快照复活；钥匙串读写走 `security` CLI（保留 mcpOAuth 等键）。
2. **Kimi**（`KimiBilling.swift`）：region 文件 / 环境变量双 host 族、过期才
   刷新、flock 串行化（非常驻锁文件）、refresh_token 轮换原子写回（rename
   保留 0600）、invalid_grant 重读磁盘兑并发赢家、401 自愈重试一次。
3. **Codex**（`CodexBilling.swift`）：wham/usage 主路（Bearer + Account-Id 头，
   401 自刷新原子写回 auth.json + last_refresh）+ `codex app-server`
   JSON-RPC over stdio 兑底（图形化 PATH 补齐、失败诊断落盘）。
4. **OpenCode Go**（`GoBilling.swift`）：Key 自动发现（环境变量 → auth.json）、
   浏览器 UA（Cloudflare 1010）、3 次重试、401/403 语义。
5. **缓存层**（`OfficialCache.swift`）：成功 120s / 失败退避 120s、429 遵守
   Retry-After（force 不绕过）、成功与失败尝试分离、磁盘兑底 24h 过期标记、
   flock + 原子替换跨进程共享（与 Python 版共用同一 official_cache.json）、
   kimi 凭据版本跟踪。
6. **接入**：`OfficialQuotaService` → `QuotaEstimator.officialProvider`，
   AppState 并行抓取四家（对齐 ThreadPoolExecutor）。

验收：
- 25 个新 XCTest 全绿（缓存 8 + 429 保留 4 + Kimi 10 + Claude 5——含刷新
  写回 0600、轮换兑底、锁超时、region/env host、桌面采样兑底保 429）；
- **真机对比 `TT_LIVE=1`（默认跳过）与 `./tt quotas` 四家官方数值一致**
  （Claude 23%/35% oauth · Kimi 74%/25% · Codex 1%/55% wham · Go 97% 月度）。

（移植清单与验收方式见上方已完成记录。）

### Phase 4 — 会话恢复 + 开机启动 + 更新检查 ✅ 已完成

已交付：

- `Resume/Resume.swift`：resume.py 全量（命令矩阵、kimi session_ 前缀、
  shlex.quote/AppleScript 转义、claude jsonl cwd 解析 + slug 启发式、五终端
  打开 + 失败复制剪贴板）；测试缝：cliResolver/runner/appInstalled。
  21 个新 XCTest（对齐 test_resume.py + updatecheck 缓存语义）。
- 会话详情检查器：「▶ 在终端继续」+ 目录已移动时「改选目录…」（NSOpenPanel）；
  打开失败自动复制命令。
- `UpdateChecker.swift`：GitHub Releases 检查，缓存 24h、失败静默；
  App 启动后延迟 30s 后台检查；设置页「关于」显示版本与新版本链接。
- SMAppService 登录项在 Phase 2 已接入设置页（本阶段随打包验证）。

- `Resume`：五终端 AppleScript/`open -a` 逻辑、目录已移动时改选、失败复制到
  剪贴板（对齐 `test_resume.py`）。
- SMAppService 登录项；`updatecheck` 移植。
- 验收：`docs/session-resume-plan.md` 验收项全过。

### Phase 5 — 打包、并存期与切换 ✅ 已完成（切换观察期交给使用者）

已交付：

- `scripts/release_swift.sh`：release 构建 + codesign（默认 ad-hoc，
  `CODESIGN_IDENTITY` 环境变量切 Developer ID）+ DMG（hdiutil UDZO）；
  公证命令在脚本输出里（需凭据，不自动执行）。Info.plist 版本 0.2.0
  与 Python `__version__` 对齐。
- README：双实现并存说明 +「不要同时常驻」警示 + Swift 版构建入口。
- 数据目录共用与回退：Swift 版读写同一 `~/.tokentracker/`（usage.db
  schema v2、settings.json、official_cache.json、claude_cred_backup.json），
  随时可切回 Python 版，无迁移成本。
- 验收实测：冷启动 234ms（<1s ✓）；物理内存 phys_footprint <1MB（<60MB ✓）；
  App 2.4MB / DMG 1.2MB（<15MB ✓，PyInstaller 版 ~40MB）；Swift 135 个
  XCTest 全绿 + Python 185 个测试无回归。
- 切换观察期（人工）：日常使用 Swift 版一至两周，确认状态栏数字与 Python
  版一致后，将 Python 桌面壳标记 deprecated（保留 CLI）。

**2026-09-07 切换已执行**：用户决定跳过观察期直接切换。Swift 版以同名同
bundle id（`com.tokentracker.desktop`）覆盖安装到 `/Applications/TokenTracker.app`
（Tahoe 状态栏授权与登录项随 bundle id 继承）；Python 桌面版退出主力，
CLI `./tt` 保留。注意：打包名从 TokenTrackerSwift 改回 TokenTracker（两脚本
已同步）。排障备忘：曾出现测试脚本 kill 子壳导致 App 进程被孤立残留，
旧实例占位导致新版本无法启动——`pkill -f TokenTracker` 后重开即可；
诊断开关 `TT_DEBUG_TITLE=1`（标题渲染落盘 /tmp/tt_swift_debug.log）。

（原定的打包/并存期/验收清单已并入上方已完成记录。注：最终用了 SwiftPM +
脚本打包而非 Xcode 归档——零项目文件、CI 友好；公证需凭据时按
`scripts/release_swift.sh` 输出执行。）

## 5. 模块映射速查

| Python | Swift |
|---|---|
| `scanners/*.py` | `TokenTrackerCore/Scanners/*.swift`（协议 + 注册表 + ScanRunner） |
| `db.py` | `Store/UsageStore.swift` + `Store/SQLite.swift`（裸 libsqlite3 薄封装，同 schema v2） |
| `pricing.py` | `Pricing/PriceTable.swift` |
| `quotas.py` | `Quotas/QuotaEstimator.swift` |
| `billing.py` | `Billing/`（ClaudeBilling / KimiBilling / CodexBilling / GoBilling + OfficialCache + OfficialQuotaService + BillingContext） |
| `server.py` ScanService | `ScanScheduler.swift` |
| `app/menubar_fmt.py` | `MenuBar/MenuBarFormatter.swift`（纯函数，直接对拍） |
| `app/menubar.py` | `TokenTrackerApp/StatusItemController.swift` |
| `app/desktop.py` | `TokenTrackerApp.swift` + `AppDelegate` + `MainWindowController` |
| `app/web/*` | `TokenTrackerApp/Views/`（Swift Charts 替 Chart.js） |
| `resume.py` / `clifind.py` | `Resume/Resume.swift` + `Billing/CliFind.swift` |
| `prefs.py` + server 设置白名单 | `Settings/SettingsStore.swift`（同 JSON 文件） |
| `loginitem.py` | SMAppService（SettingsView 接入） |
| `updatecheck.py` | `UpdateChecker.swift` |
| `tests/*.py` | `TokenTrackerCoreTests/`（135 个 XCTest，含差分对拍） |

## 6. CLI 的取舍 ✅ 已完成

`tt-swift` 可执行目标已实现（`swift/Sources/tt-swift/main.swift`，手写参数
解析零依赖，复用 Core）：`detect / scan [--full] / stats [--range] / quotas`，
与 Python `./tt` 输出对齐（实测同库数字一致）。`tt serve` 浏览器模式随
Web 前端退役。过渡期 Python CLI 保留不动。

## 7. 主要风险与对策

| 风险 | 对策 |
|---|---|
| **billing.py 行为回归**（凭据刷新写错会把用户的官方 CLI 登出） | 最后移植、真机逐家验收；先实现只读路径，自刷新路径加 feature flag，灰度开启；flock/原子写回逐行对齐 |
| **增量扫描语义漂移**（inode/mtime/快照/去重） | Phase 1 差分测试是硬门槛：同一语料两版结果必须逐字节一致；计数器重置、跨窗口区间等边界用例从 unittest 逐条移植 |
| **Tahoe 状态栏门控/缺陷** | StatusKit 门控与框架无关；自愈逻辑（重排/重建/退避）原样移植，并在 Tahoe 真机回归 |
| **Codex SQLite+JSONL 双源补缺** | 最复杂适配器，排在 claude 之后第二个移植，配最多 fixture |
| **Swift Charts 大数据量性能**（会话表几千行） | 表用懒加载 `Table`；趋势图按范围聚合后喂数据 |
| **双写冲突**（并存期两版同时扫同一库） | 沿用现有 flock/WAL 即可；文档注明不要两版同时常驻 |

## 8. 阶段依赖

P0 → P1 → P2 → P3 → P4 → P5 按依赖顺序执行；P3（billing）与 P2/P4 可并行。

收益：甩掉 Python 运行时 + PyInstaller（安装包 40MB→几 MB、冷启动显著加快）、
甩掉 pywebview/WKWebView 桥接层、UI 全部原生可测；代价是双栈并存期与
billing/扫描两处的回归风险（用差分测试与灰度开关兜住）。
