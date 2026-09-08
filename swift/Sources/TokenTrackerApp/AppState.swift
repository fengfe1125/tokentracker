//
//  AppState.swift
//  TokenTrackerApp
//
//  应用状态：持有只读 store（UI 查询）与写 store（ScanScheduler），
//  驱动 5s 轮询（扫描状态 + 设置热生效）与 60s 数据刷新。
//  对齐 Python 版数据流：menubar 轮询 /api/scan/status、60s 拉统计与配额。
//

import Combine
import Foundation
import TokenTrackerCore

/// 侧边栏导航
enum NavSelection: Hashable {
    case overview, sessions, activity, settings
    case tool(String)
}

@MainActor
final class AppState: ObservableObject {
    // 状态栏数据
    @Published var today: MenuBarToday?
    @Published var quotaEntries: [MenuBarQuotaEntry] = []
    @Published var scanning = false
    @Published var lastScan: ScanSchedulerStatus.Last?

    // 主面板数据
    @Published var selection: NavSelection = .overview
    @Published var range = "week"            // day/week/month/all（对齐网页端默认 week）
    @Published var statRows: [UsageStore.ToolStats] = []
    @Published var statTotal = UsageStore.ToolStats()
    @Published var statSummary = UsageStore.TimeSummary(unallocatedTokens: 0, unallocatedCost: 0,
                                                        unallocatedEvents: 0, estimatedTokens: 0)
    @Published var dailyRows: [UsageStore.DailyRow] = []
    @Published var modelRows: [UsageStore.ModelRow] = []
    @Published var sessionRows: [UsageStore.SessionRow] = []
    @Published var sessionSearch = ""
    /// 表格选中行；详情面板跟着它走，所以放在 AppState 而不是视图 @State
    @Published var selectedSessionID: String?
    @Published var activityRange = "week"
    @Published var activityAgent: String?
    @Published var activityConfidence = "exact"
    @Published var activityExactRows: [UsageStore.ActivitySummaryRow] = []
    @Published var activityDerivedRows: [UsageStore.ActivitySummaryRow] = []
    @Published var activityToolRows: [UsageStore.ActivitySummaryRow] = []
    @Published var activitySkillRows: [UsageStore.ActivitySummaryRow] = []
    @Published var activityExactSkillRows: [UsageStore.ActivitySummaryRow] = []
    @Published var activityTimelineRows: [ActivityEvent] = []
    @Published var activityMatrixRows: [String: [UsageStore.ActivitySummaryRow]] = [:]
    @Published var detectInfo: [String: DetectInfo] = [:]
    @Published var todayByTool: [String: Int64] = [:]   // 侧栏今日量（按工具）
    @Published var updateInfo: UpdateInfo?              // 更新检查（缓存 24h）
    @Published var updatedAt: Date?

    // Codex 多账号切换（设置页管理区）
    @Published var codexAccounts: [CodexAccount] = []
    @Published var activeCodexAccountID: String?
    @Published var accountOpMessage: String?            // 操作结果 / 错误提示

    // 设置（effective = 默认值 + 校验后的已存值）
    @Published var settings: [String: Any] = [:]

    /// 会话列表查询上限（顶栏计数要据此区分「共 N 个」和「最近 N 个」）
    nonisolated static let sessionLimit = 300

    /// 自动扫描/刷新节奏（秒）；设置键 scan_interval，默认 60
    var scanIntervalSeconds: Int {
        (settings["scan_interval"] as? NSNumber)?.intValue ?? 60
    }

    let readStore: UsageStore
    let settingsStore: SettingsStore
    let scanRoots: ScanRoots
    let priceTable: PriceTable
    /// Codex 多账号切换：快照当前登录 + 一键原子替换 auth.json
    let accountSwitcher: CodexAccountSwitcher
    /// 官方配额抓取（注入缝：测试可换成假实现；nil = 仅本地估算）
    var officialQuotaService: OfficialQuotaService?
    private(set) var scheduler: ScanScheduler!

    private let queryQueue = DispatchQueue(label: "tokentracker.query")
    private var pollTimer: Timer?
    private var refreshTimer: Timer?
    private var settingsFingerprint: String = ""

    /// 数值刷新闪光（状态栏动画）；由 StatusItemController 消费。
    var onTokensChanged: (() -> Void)?
    /// 会话详情面板（AppDelegate 注入；参数 true = 用户显式打开）
    var onSessionDetail: ((Bool) -> Void)?

    /// 单击选中：面板已开才跟着更新，用户关过就不再自动弹
    func autoShowSessionDetail() { onSessionDetail?(false) }
    /// 双击 / ⌘I / 右键「查看详情」：无条件打开
    func showSessionDetail() { onSessionDetail?(true) }

    init(dbPath: String? = nil, officialQuotaService: OfficialQuotaService? = OfficialQuotaService()) {
        let env = ProcessInfo.processInfo.environment
        let path = dbPath ?? env["TOKENTRACKER_DB"]
            ?? NSHomeDirectory() + "/.tokentracker/usage.db"
        readStore = try! UsageStore(path: path)
        if let pricesPath = env["TOKENTRACKER_PRICES"] {
            priceTable = PriceTable.load(from: pricesPath)
        } else {
            // 仓库根的 prices.json；打包后回退内置默认表
            let repoPrices = Bundle.main.bundleURL
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("prices.json").path
            priceTable = FileManager.default.fileExists(atPath: repoPrices)
                ? PriceTable.load(from: repoPrices) : .default
        }
        settingsStore = SettingsStore()
        scanRoots = ScanRoots()
        accountSwitcher = CodexAccountSwitcher()
        self.officialQuotaService = officialQuotaService
        settings = settingsStore.effective()
        settingsFingerprint = Self.fingerprint(settings)
        reloadCodexAccounts()
    }

    /// 启动调度：启动扫一次 + 每 60s 增量（写库用独立连接）。
    func start(dbPath: String? = nil) {
        let path = dbPath ?? readStore.path
        let prices = priceTable
        let roots = scanRoots
        scheduler = ScanScheduler(
            scan: { tools, full in
                let writeStore = try UsageStore(path: path)
                writeStore.priceTableForMigration = prices
                let runner = ScanRunner(store: writeStore, prices: prices, roots: roots)
                let results = runner.runAll(tools: tools, full: full)
                let repriced = try writeStore.reprice(prices)
                return (results, repriced)
            },
            interval: Double(scanIntervalSeconds))
        scheduler.onFinish = { [weak self] in
            DispatchQueue.main.async { self?.refreshVisibleData() }
        }
        scheduler.startAuto()

        // 5s 轮询：扫描状态 + 设置热生效（对齐 menubar.py tt_loop）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollScanStatus()
                self?.reloadSettingsIfChanged()
            }
        }
        // 60s 数据刷新
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshVisibleData() }
        }
        refreshVisibleData()

        // 更新检查：启动后延迟 30s 的后台一次性请求（对齐 updatecheck.py 注释），
        // 网络失败静默，绝不阻塞启动
        let checker = UpdateChecker()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            let info = checker.check()
            DispatchQueue.main.async { self?.updateInfo = info }
        }
    }

    func requestScan(full: Bool = false) {
        scanning = true   // 立即反馈；真实状态以 poll 为准
        scheduler.request(full: full, source: "manual")
    }

    // ------------------------------------------------------------ 轮询 ----

    private func pollScanStatus() {
        let snap = scheduler?.snapshot() ?? ScanSchedulerStatus()
        let wasScanning = scanning
        scanning = snap.running
        lastScan = snap.last
        if wasScanning && !scanning { refreshVisibleData() }  // 扫描刚结束立即刷新
    }

    private func reloadSettingsIfChanged() {
        let effective = settingsStore.effective()
        let fp = Self.fingerprint(effective)
        if fp != settingsFingerprint {
            settingsFingerprint = fp
            settings = effective
            scheduler?.setInterval(Double(scanIntervalSeconds))
        }
    }

    func updateSetting(key: String, value: Any) {
        if settingsStore.set(key: key, value: value) {
            settings = settingsStore.effective()
            settingsFingerprint = Self.fingerprint(settings)
            scheduler?.setInterval(Double(scanIntervalSeconds))
        }
    }

    private static func fingerprint(_ dict: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                     encoding: .utf8)) ?? ""
    }

    // ------------------------------------------------------------ 数据 ----

    func refreshVisibleData() {
        refreshData()
        if selection == .activity { refreshActivity() }
    }

    func refreshData() {
        reloadCodexAccounts()   // 账号列表与 active 跟随轮询热反映
        let store = readStore
        let range = range
        let search = sessionSearch
        let toolFilter: String? = {
            if case .tool(let id) = selection { return id }
            return nil
        }()
        let officialService = officialQuotaService
        queryQueue.async { [weak self] in
            guard let self else { return }
            do {
                let (rows, total, summary) = try store.stats(rangeKey: range)
                let daily = try store.daily(rangeKey: range)
                let models = try store.models(rangeKey: range)
                let sessions = try store.sessions(rangeKey: range, tool: toolFilter,
                                                  limit: Self.sessionLimit,
                                                  query: search.isEmpty ? nil : search)
                let dayStats = try store.stats(rangeKey: "day")
                let quotasConfig = QuotasConfig.load(
                    from: ProcessInfo.processInfo.environment["TOKENTRACKER_QUOTAS"] ?? "")
                // 官方抓取并行（对齐 quotas.py ThreadPoolExecutor；任一失败不阻塞整体）
                final class ResultsBox: @unchecked Sendable {
                    var dict: [String: OfficialResult] = [:]
                    let lock = NSLock()
                }
                let resultsBox = ResultsBox()
                if let officialService {
                    let names = Array(Set(quotasConfig.entries.compactMap(\.official)))
                    DispatchQueue.concurrentPerform(iterations: names.count) { index in
                        if let result = officialService.providerResult(names[index]) {
                            resultsBox.lock.lock()
                            resultsBox.dict[names[index]] = result
                            resultsBox.lock.unlock()
                        }
                    }
                }
                let officialResults = resultsBox.dict
                let quotas = try QuotaEstimator.compute(
                    store: store, config: quotasConfig,
                    nowMs: store.nowMs()) { officialResults[$0] }
                let detect = ScanRunner(store: store, prices: self.priceTable,
                                        roots: self.scanRoots).detectAll()
                DispatchQueue.main.async {
                    let newTokens = dayStats.total.tokens
                    if let prev = self.today?.tokens, prev != newTokens {
                        self.onTokensChanged?()   // 数值刷新闪光
                    }
                    self.today = MenuBarToday(tokens: newTokens, cost: dayStats.total.cost)
                    self.quotaEntries = quotas.map(MenuBarQuotaEntry.init(result:))
                    self.statRows = rows
                    self.statTotal = total
                    self.statSummary = summary
                    self.dailyRows = daily
                    self.modelRows = models
                    self.sessionRows = sessions
                    self.detectInfo = detect
                    self.todayByTool = Dictionary(uniqueKeysWithValues:
                        dayStats.rows.map { ($0.tool, $0.tokens) })
                    self.updatedAt = Date()
                    if ProcessInfo.processInfo.environment["TT_DEBUG_TITLE"] == "1" {
                        FileHandle.standardError.write(Data(
                            "[tt] refreshData OK: today=\(newTokens) sessions=\(sessions.count)\n".utf8))
                    }
                }
            } catch {
                // 读库失败（如迁移中短暂锁定）：写到 stderr 便于诊断，下一轮再试
                FileHandle.standardError.write(Data(
                    "[tt] refreshData FAILED: \(error)\n".utf8))
            }
        }
    }

    /// Activity 统计比普通概览查询更重，只在活动页或筛选变化时加载。
    func refreshActivity() {
        let store = readStore
        let range = activityRange
        let agent = activityAgent
        let confidence = activityConfidence
        queryQueue.async { [weak self] in
            guard let self else { return }
            do {
                let exact = try store.activitySummary(
                    rangeKey: range, agent: agent, group: "agent", confidence: "exact")
                let derived = try store.activitySummary(
                    rangeKey: range, agent: agent, group: "agent", confidence: "derived")
                let tools = try store.activitySummary(
                    rangeKey: range, agent: agent, group: "tool", confidence: confidence)
                let skills = try store.activitySummary(
                    rangeKey: range, agent: agent, group: "skill", confidence: confidence)
                let exactSkills = try store.activitySummary(
                    rangeKey: range, agent: agent, group: "skill", confidence: "exact")
                let timeline = try store.activityTimeline(
                    rangeKey: range, agent: agent, confidence: confidence, limit: 80)
                var matrix: [String: [UsageStore.ActivitySummaryRow]] = [:]
                for matrixAgent in ScannerRegistry.all {
                    matrix[matrixAgent] = try store.activitySummary(
                        rangeKey: range, agent: matrixAgent,
                        group: "tool", confidence: confidence)
                }
                DispatchQueue.main.async {
                    self.activityExactRows = exact
                    self.activityDerivedRows = derived
                    self.activityToolRows = tools
                    self.activitySkillRows = skills
                    self.activityExactSkillRows = exactSkills
                    self.activityTimelineRows = timeline
                    self.activityMatrixRows = matrix
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "[tt] refreshActivity FAILED: \(error)\n".utf8))
            }
        }
    }

    /// 会话详情走查询队列：选中一行不应该在主线程读库（大库时会顿）。
    func sessionDetail(tool: String, sessionID: String) async -> UsageStore.SessionDetail? {
        let store = readStore
        return await withCheckedContinuation { cont in
            queryQueue.async {
                cont.resume(returning: try? store.sessionDetail(tool: tool, sessionID: sessionID))
            }
        }
    }

    // ------------------------------------------------------ Codex 账号 ----
    //  切换涉及文件读写（回采 + 原子替换 auth.json），一律走 queryQueue，
    //  回主线程发布结果。日志/提示只带 account_id 与结果，绝不打印 token。

    /// 读账号库 + 当前 active（走查询队列，不占主线程）。
    func reloadCodexAccounts() {
        let switcher = accountSwitcher
        queryQueue.async { [weak self] in
            let accounts = switcher.store.load()
            let active = switcher.activeAccountID()
            DispatchQueue.main.async {
                self?.codexAccounts = accounts
                self?.activeCodexAccountID = active
            }
        }
    }

    /// 保存当前 Codex 登录为一份账号快照（name 留空则用 email/id 兜底）。
    func captureCurrentCodexAccount(name: String) {
        let switcher = accountSwitcher
        queryQueue.async { [weak self] in
            do {
                let account = try switcher.captureCurrent(name: name)
                let accounts = switcher.store.load()
                let active = switcher.activeAccountID()
                let message = "已保存账号「\(account.name)」"
                DispatchQueue.main.async {
                    self?.codexAccounts = accounts
                    self?.activeCodexAccountID = active
                    self?.accountOpMessage = message
                }
            } catch {
                let message = "保存失败：\(error)"
                DispatchQueue.main.async { self?.accountOpMessage = message }
            }
        }
    }

    /// 切换账号：后台执行「回采当前 → 原子写目标」，回主线程发布结果。
    func switchCodexAccount(id: String) {
        let switcher = accountSwitcher
        queryQueue.async { [weak self] in
            do {
                try switcher.switchTo(id)
                let accounts = switcher.store.load()
                let active = switcher.activeAccountID()
                DispatchQueue.main.async {
                    self?.codexAccounts = accounts
                    self?.activeCodexAccountID = active
                    self?.accountOpMessage = "已切换，请重启 Codex 生效"
                }
            } catch {
                let message = "切换失败：\(error)"
                DispatchQueue.main.async { self?.accountOpMessage = message }
            }
        }
    }

    func removeCodexAccount(id: String) {
        let switcher = accountSwitcher
        queryQueue.async { [weak self] in
            let accounts = switcher.store.remove(id)
            DispatchQueue.main.async { self?.codexAccounts = accounts }
        }
    }

    func renameCodexAccount(id: String, name: String) {
        let switcher = accountSwitcher
        queryQueue.async { [weak self] in
            let accounts = switcher.store.rename(id, name: name)
            DispatchQueue.main.async { self?.codexAccounts = accounts }
        }
    }
}
