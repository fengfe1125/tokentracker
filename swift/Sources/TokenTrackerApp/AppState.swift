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
    case overview, sessions, activity, settings, projects, reports
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
    let activityPage = ActivityPageState()
    @Published var detectInfo: [String: DetectInfo] = [:]
    @Published var todayByTool: [String: Int64] = [:]   // 侧栏今日量（按工具）
    @Published var updateInfo: UpdateInfo?              // 更新检查（缓存 24h）
    @Published var updatedAt: Date?

    // Codex 多账号切换（设置页管理区）
    @Published var codexAccounts: [CodexAccount] = []
    @Published var activeCodexAccountID: String? {
        didSet {
            insights.codexAccountID = activeCodexAccountID ?? "unknown"
            insights.risks.removeAll { $0.id.hasPrefix("quota:codex:") }
            insights.refresh()
        }
    }
    @Published private var accountNotice: L10n.Template?
    var accountOpMessage: String? { accountNotice.map(L10n.text) }            // 操作结果 / 错误提示

    // 公开统计上报（设置页 + 独立记录窗口）
    @Published var publishState = PublishState()
    @Published var publishHistory: [PublishAttempt] = []
    @Published private(set) var publishFailed = false
    @Published var publishBusy = false
    @Published private var publishNotice: L10n.Template?
    var publishMessage: String? { publishNotice.map(L10n.text) }
    @Published var publishTokenConfigured = false

    // 设置（effective = 默认值 + 校验后的已存值）
    @Published var settings: [String: Any] = [:]

    /// 会话列表查询上限（顶栏计数要据此区分「共 N 个」和「最近 N 个」）
    nonisolated static let sessionLimit = 300

    /// 自动扫描/刷新节奏（秒）；设置键 scan_interval，默认 60
    var scanIntervalSeconds: Int {
        (settings["scan_interval"] as? NSNumber)?.intValue ?? 60
    }

    let insights: InsightsModel
    let readStore: UsageStore
    let settingsStore: SettingsStore
    let scanRoots: ScanRoots
    let priceTable: PriceTable
    /// Codex 多账号切换：快照当前登录 + 一键原子替换 auth.json
    let accountSwitcher: CodexAccountSwitcher
    /// 官方配额抓取（注入缝：测试可换成假实现；nil = 仅本地估算）
    var officialQuotaService: OfficialQuotaService?
    private(set) var scheduler: ScanScheduler!

    private var dataGeneration = 0
    private var sessionsGeneration = 0
    private var quotaBusy = false
    private let quotaQueue = DispatchQueue(label: "tokentracker.quotas")
    private let detailQueue = DispatchQueue(label: "tokentracker.details")
    private let queryQueue = DispatchQueue(label: "tokentracker.query")
    /// 上报独占一条队列：网络最长阻塞 12 秒，不能占着查询队列。
    private let publishQueue = DispatchQueue(label: "tokentracker.publish")
    private let isPreview = ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1"
    private let publishTokenStore: KeychainPublishTokenStore
    private let publishHistoryStore: PublishHistoryStore
    private let publisher: PublicStatsPublisher
    private var pollTimer: Timer?
    private var refreshTimer: Timer?
    private var settingsFingerprint: String = ""

    /// 数值刷新闪光（状态栏动画）；由 StatusItemController 消费。
    var onTokensChanged: (() -> Void)?
    /// 会话详情面板（AppDelegate 注入；参数 true = 用户显式打开）
    var onSessionDetail: ((Bool) -> Void)?
    /// Agent Activity 详情窗口（始终独立于主表，避免压缩主视图）
    var onActivityDetail: (() -> Void)?
    var onPublishHistory: (() -> Void)?

    /// 单击选中：面板已开才跟着更新，用户关过就不再自动弹
    func autoShowSessionDetail() { onSessionDetail?(false) }
    /// 双击 / ⌘I / 右键「查看详情」：无条件打开
    func showSessionDetail() { onSessionDetail?(true) }
    func showActivityDetail() { onActivityDetail?() }
    func showPublishHistory() { onPublishHistory?() }

    init(dbPath: String? = nil, officialQuotaService: OfficialQuotaService? = OfficialQuotaService()) {
        let env = ProcessInfo.processInfo.environment
        let path = dbPath ?? env["TOKENTRACKER_DB"]
            ?? NSHomeDirectory() + "/.tokentracker/usage.db"
        readStore = try! UsageStore(path: path)
        insights = InsightsModel(path: path)
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
        let preview = env["TT_UI_PREVIEW"] == "1"
        let previewHome = (path as NSString).deletingLastPathComponent
        let settingsStore = SettingsStore(path: preview ? previewHome + "/settings.json" : nil)
        let tokenStore = KeychainPublishTokenStore()
        let historyStore = PublishHistoryStore(path: preview ? previewHome + "/publish_history.json" : NSHomeDirectory() + "/.tokentracker/publish_history.json")
        self.settingsStore = settingsStore
        publishTokenStore = tokenStore
        publishHistoryStore = historyStore
        publisher = PublicStatsPublisher(settings: settingsStore, tokens: tokenStore,
                                         history: historyStore)
        scanRoots = ScanRoots()
        accountSwitcher = preview ? CodexAccountSwitcher(ctx: BillingContext(home:previewHome,env:["CODEX_HOME":previewHome+"/.codex"])) : CodexAccountSwitcher()
        self.officialQuotaService = preview ? nil : officialQuotaService
        settings = settingsStore.effective()
        settingsFingerprint = Self.fingerprint(settings)
        publishState = PublishState.load(path: isPreview ? (readStore.path as NSString).deletingLastPathComponent + "/publish_state.json" : NSHomeDirectory() + "/.tokentracker/publish_state.json")
        publishHistory = historyStore.load()
        let handle = settings["publish_handle"] as? String ?? ""
        publishTokenConfigured = !preview && tokenStore.read(handle: handle) != nil
        reloadCodexAccounts()
    }

    /// 启动调度：启动扫一次 + 每 60s 增量（写库用独立连接）。
    func start(dbPath: String? = nil) {
        let path = dbPath ?? readStore.path
        let prices = priceTable
        let roots = scanRoots
        let publisher = publisher
        let publishQueue = publishQueue
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
            DispatchQueue.main.async {
                self?.pollScanStatus()
                self?.refreshVisibleData()
                self?.insights.refresh(afterScan: true)
            }
            // 上报另开只读连接：与 scan 另开 writeStore 同一纪律，
            // 绝不从后台线程序列化 readStore。三道闸在 publishIfNeeded 内部，
            // 关闭时会在碰数据库之前就返回。
            publishQueue.async {
                guard let store = try? UsageStore(path: path) else { return }
                publisher.publishIfNeeded(store: store, trigger: .automatic)
            }
        }
        if ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1" {
            insights.refresh(afterScan:true)
        } else { scheduler.startAuto() }

        // 5s 轮询：扫描状态 + 设置热生效（对齐 menubar.py tt_loop）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollScanStatus()
                self?.reloadSettingsIfChanged()
                if self?.selection == .settings { self?.refreshPublishInfo(refreshToken: false) }
            }
        }
        // 60s 数据刷新
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshVisibleData(); self?.refreshQuotas() }
        }
        refreshVisibleData()
        refreshQuotas()

        // 更新检查：启动后延迟 30s 的后台一次性请求（对齐 updatecheck.py 注释），
        // 网络失败静默，绝不阻塞启动
        guard !isPreview else { return }
        let checker = UpdateChecker()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            let info = checker.check()
            DispatchQueue.main.async { self?.updateInfo = info }
        }
    }

    func requestScan(full: Bool = false) {
        if ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1" { insights.refresh(); return }
        scanning = true   // 立即反馈；真实状态以 poll 为准
        scheduler.request(full: full, source: "manual")
    }

    // ------------------------------------------------------------ 轮询 ----

    private func pollScanStatus() {
        let snap = scheduler?.snapshot() ?? ScanSchedulerStatus()
        if scanning != snap.running { scanning = snap.running }
        if lastScan != snap.last { lastScan = snap.last }
    }

    private func reloadSettingsIfChanged() {
        let effective = settingsStore.effective()
        let fp = Self.fingerprint(effective)
        if fp != settingsFingerprint {
            settingsFingerprint = fp
            settings = effective
            scheduler?.setInterval(Double(scanIntervalSeconds))
            let handle = settings["publish_handle"] as? String ?? ""
            publishTokenConfigured = !isPreview && publishTokenStore.read(handle: handle) != nil
        }
    }

    func updateSetting(key: String, value: Any) {
        if settingsStore.set(key: key, value: value) {
            settings = settingsStore.effective()
            settingsFingerprint = Self.fingerprint(settings)
            scheduler?.setInterval(Double(scanIntervalSeconds))
        }
    }

    // ------------------------------------------------------ 公开统计 ----

    var publishConfigurationReady: Bool {
        let endpoint = settings["publish_endpoint"] as? String ?? ""
        let handle = settings["publish_handle"] as? String ?? ""
        return SettingsStore.isValid(key: "publish_endpoint", value: endpoint)
            && !endpoint.isEmpty
            && SettingsStore.isValid(key: "publish_handle", value: handle)
            && !handle.isEmpty
            && publishTokenConfigured
    }

    var publicStatsURL: URL? {
        guard publishConfigurationReady else { return nil }
        let endpoint = (settings["publish_endpoint"] as? String ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let handle = settings["publish_handle"] as? String ?? ""
        return URL(string: endpoint + "/v1/stats/" + handle)
    }

    func savePublishConfiguration(endpoint: String, handle: String, days: Int, token: String) {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let values: [String: Any] = [
            "publish_endpoint": endpoint,
            "publish_handle": handle,
            "publish_days": NSNumber(value: days),
        ]
        guard values.allSatisfy({ SettingsStore.isValid(key: $0.key, value: $0.value) })
        else {
            publishFailed = true
            publishNotice = L10n.message("保存失败：请检查 HTTPS 地址、用户名和公开天数")
            return
        }
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty,
           publishTokenStore.writeReportingLocation(handle: handle, token: cleanToken) == nil {
            publishFailed = true
            publishNotice = L10n.message("保存失败：无法写入发布 Token")
            return
        }
        guard settingsStore.set(values: values) else {
            publishFailed = true
            publishNotice = L10n.message("保存失败：配置校验未通过")
            return
        }
        publishFailed = false
        settings = settingsStore.effective()
        settingsFingerprint = Self.fingerprint(settings)
        publishTokenConfigured = !isPreview && publishTokenStore.read(handle: handle) != nil
        publishNotice = publishTokenConfigured ? L10n.message("公开统计配置已保存") : L10n.message("配置已保存，请填写发布 Token")
    }

    func setPublishEnabled(_ enabled: Bool) {
        if enabled && !publishConfigurationReady {
            publishNotice = L10n.message("请先保存完整的服务地址、用户名和发布 Token")
            return
        }
        publishFailed = false
        updateSetting(key: "publish_enabled", value: enabled)
        publishNotice = enabled ? L10n.message("自动上传已开启") : L10n.message("自动上传已关闭")
    }

    func performPublish(trigger: PublishTrigger) {
        guard trigger != .automatic, publishConfigurationReady, !publishBusy else { return }
        publishFailed = false
        publishBusy = true
        publishNotice = trigger == .forced ? L10n.message("正在强制上传…") : L10n.message("正在按规则检查并上传…")
        let path = readStore.path
        let publisher = publisher
        publishQueue.async { [weak self] in
            guard let store = try? UsageStore(path: path) else {
                DispatchQueue.main.async {
                    self?.publishBusy = false
                    self?.publishFailed = true
                    self?.publishNotice = L10n.message("无法打开本地统计数据库")
                }
                return
            }
            let outcome = publisher.publishIfNeeded(store: store, trigger: trigger)
            DispatchQueue.main.async {
                guard let self else { return }
                self.publishBusy = false
                self.publishFailed = !outcome.error.isEmpty
                self.publishNotice = Self.publishOutcomeText(outcome)
                self.refreshPublishInfo()
            }
        }
    }

    func refreshPublishInfo(refreshToken: Bool = true) {
        publishState = PublishState.load(path: isPreview ? (readStore.path as NSString).deletingLastPathComponent + "/publish_state.json" : NSHomeDirectory() + "/.tokentracker/publish_state.json")
        publishHistory = publishHistoryStore.load()
        if refreshToken {
            let handle = settings["publish_handle"] as? String ?? ""
            publishTokenConfigured = !isPreview && publishTokenStore.read(handle: handle) != nil
        }
    }

    func clearPublishHistory() {
        publishHistoryStore.clear()
        publishHistory = []
    }

    private static func publishOutcomeText(_ outcome: PublishOutcome) -> L10n.Template {
        switch outcome.decision {
        case .publish:
            return outcome.error.isEmpty ? L10n.message("上传成功（\(outcome.bytes) 字节）") : L10n.message("上传失败：\(outcome.error)")
        case .skipDisabled: return L10n.message("自动上传未开启")
        case .skipUnconfigured: return L10n.message("服务地址或用户名未配置")
        case .skipUnchanged: return L10n.message("公开数据没有变化，无需重复上传")
        case .skipThrottled: return L10n.message("距离上次上传不足 15 分钟")
        case .skipBackoff: return L10n.message("服务暂不可用，当前处于失败退避期")
        }
    }

    private static func fingerprint(_ dict: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                     encoding: .utf8)) ?? ""
    }

    // ------------------------------------------------------------ 数据 ----

    func refreshVisibleData() {
        if selection == .overview { insights.query = UsageQuery.period(range); insights.search = "" }
        insights.refresh()
        refreshData()
        if selection == .activity { refreshActivity() }
    }

    func refreshData() {
        dataGeneration += 1
        let generation = dataGeneration
        reloadCodexAccounts()   // 账号列表与 active 跟随轮询热反映
        let path = readStore.path
        let range = range
        let search = sessionSearch
        let toolFilter: String? = {
            if case .tool(let id) = selection { return id }
            return nil
        }()
        queryQueue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try UsageStore(path: path)
                let (rows, total, summary) = try store.stats(rangeKey: range)
                let daily = try store.daily(rangeKey: range)
                let models = try store.models(rangeKey: range)
                let sessions = try store.sessions(rangeKey: range, tool: toolFilter,
                                                  limit: Self.sessionLimit,
                                                  query: search.isEmpty ? nil : search)
                let dayStats = try store.stats(rangeKey: "day")
                let detect = ScanRunner(store: store, prices: self.priceTable,
                                        roots: self.scanRoots).detectAll()
                DispatchQueue.main.async {
                    guard generation == self.dataGeneration else { return }
                    let newTokens = dayStats.total.tokens
                    if let prev = self.today?.tokens, prev != newTokens {
                        self.onTokensChanged?()   // 数值刷新闪光
                    }
                    self.today = MenuBarToday(tokens: newTokens, cost: dayStats.total.cost, unpriced: dayStats.total.events > 0 && dayStats.total.unpriced == dayStats.total.events)

                    self.statRows = rows
                    self.statTotal = total
                    self.statSummary = summary
                    self.dailyRows = daily
                    self.modelRows = models
                    if search == self.sessionSearch { self.sessionRows = sessions }
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

    func refreshQuotas() {
        guard !quotaBusy else { return }
        quotaBusy = true
        let accountID = activeCodexAccountID ?? "unknown"
        let path = readStore.path
        let officialService = officialQuotaService
        quotaQueue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try UsageStore(path: path)
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
                for (provider,result) in officialResults where result.error == nil && result.staleMin == nil {
                    guard let sampled = result.sampledAt else { continue }
                    for (window,value) in result.windows ?? [:] {
                        if let pct=value.pct {
                            let reset=value.resetsAt.flatMap { ISO8601DateFormatter().date(from:$0) }.map { Int64($0.timeIntervalSince1970*1000) } ?? 0
                            let identity=provider+":"+(provider == "codex" ? accountID : "current")+":"+window
                            try store.recordQuota(QuotaSample(identity:identity,at:Int64(sampled*1000),pct:pct,resetsAt:reset))
                        }
                    }
                }
                let quotas = try QuotaEstimator.compute(
                    store: store, config: quotasConfig,
                    nowMs: store.nowMs()) { officialResults[$0] }
                DispatchQueue.main.async {
                    guard accountID == (self.activeCodexAccountID ?? "unknown") else {
                        self.quotaBusy=false;self.refreshQuotas();return
                    }
                    self.quotaEntries = quotas.map(MenuBarQuotaEntry.init(result:))
                    self.quotaBusy = false
                    self.insights.refresh()
                }
            } catch {
                DispatchQueue.main.async { self.quotaBusy = false }
            }
        }
    }

    func refreshSessions() {
        sessionsGeneration += 1
        let generation = sessionsGeneration
        let path = readStore.path, range = range, search = sessionSearch
        let tool: String? = { if case .tool(let id) = selection { return id }; return nil }()
        detailQueue.async { [weak self] in
            do {
                let rows = try UsageStore(path: path).sessions(rangeKey: range, tool: tool,
                    limit: Self.sessionLimit, query: search.isEmpty ? nil : search)
                DispatchQueue.main.async {
                    guard let self, generation == self.sessionsGeneration,
                          search == self.sessionSearch, range == self.range else { return }
                    self.sessionRows = rows
                }
            } catch { }
        }
    }

    /// Activity 统计比普通概览查询更重，只在活动页或筛选变化时加载。
    func refreshActivity() {
        guard let request = activityPage.beginRefresh() else { return }
        performActivityRefresh(request)
    }

    private func performActivityRefresh(_ request: ActivityRefreshRequest) {
        let store = readStore
        let filter = request.filter
        let scan = lastScan
        queryQueue.async { [weak self] in
            guard let self else { return }
            do {
                let exact = try store.activitySummary(
                    rangeKey: filter.range, agent: filter.agent, group: "agent", confidence: "exact")
                let derived = try store.activitySummary(
                    rangeKey: filter.range, agent: filter.agent, group: "agent", confidence: "derived")
                let tools = try store.activitySummary(
                    rangeKey: filter.range, agent: filter.agent, group: "tool",
                    confidence: filter.confidence)
                let skills = try store.activitySummary(
                    rangeKey: filter.range, agent: filter.agent, group: "skill",
                    confidence: filter.confidence)
                let exactSkills = try store.activitySummary(
                    rangeKey: filter.range, agent: filter.agent, group: "skill", confidence: "exact")
                let timeline = try store.activityTimeline(
                    rangeKey: filter.range, agent: filter.agent,
                    confidence: filter.confidence, limit: 80)
                let matrix = try store.activityMatrixSummary(
                    rangeKey: filter.range, confidence: filter.confidence)
                var skillCoverage: [String: ActivityAgentCoverage] = [:]
                for agent in ScannerRegistry.all {
                    let rows = try store.activitySummary(
                        rangeKey: filter.range, agent: agent, group: "skill", confidence: "all")
                    skillCoverage[agent] = ActivityAgentCoverage(
                        capability: activityCapability(agent: agent, category: "skills"),
                        calls: rows.reduce(0) { $0 + $1.calls },
                        exact: rows.reduce(0) { $0 + $1.exact },
                        derived: rows.reduce(0) { $0 + $1.derived })
                }
                let snapshot = ActivityDashboardSnapshot(
                    exactRows: exact, derivedRows: derived, toolRows: tools,
                    skillRows: skills, exactSkillRows: exactSkills,
                    timelineRows: timeline, matrixRows: matrix,
                    skillCoverage: skillCoverage, lastScan: scan)
                DispatchQueue.main.async {
                    if let next = self.activityPage.finish(request, snapshot: snapshot) {
                        self.performActivityRefresh(next)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "[tt] refreshActivity FAILED: \(error)\n".utf8))
                DispatchQueue.main.async {
                    if let next = self.activityPage.finish(request, snapshot: nil) {
                        self.performActivityRefresh(next)
                    }
                }
            }
        }
    }

    /// 详情窗口使用的稳定游标分页查询；只返回规范化活动元数据。
    func activityTimelinePage(range: String, agent: String?, sessionID: String?,
                              confidence: String, status: String?, limit: Int, before: Int64?,
                              beforeID: Int64?, kind: ActivityKind?, query: String?) async
        -> UsageStore.ActivityTimelinePage? {
        let path = readStore.path
        return await withCheckedContinuation { continuation in
            detailQueue.async {
                continuation.resume(returning: try? UsageStore(path:path).activityTimelinePage(
                    rangeKey: range, agent: agent, sessionID: sessionID,
                    confidence: confidence, limit: limit, before: before,
                    beforeID: beforeID, kind: kind, query: query, status: status))
            }
        }
    }

    /// 详情窗口的 Skill 能力覆盖，区分「没有调用」与「日志无法判断」。
    func activitySkillCoverage(range: String, agent: String?) async
        -> [String: ActivityAgentCoverage] {
        let store = readStore
        return await withCheckedContinuation { continuation in
            queryQueue.async {
                var result: [String: ActivityAgentCoverage] = [:]
                let agents = agent.map { [$0] } ?? ScannerRegistry.all
                for name in agents {
                    let rows = (try? store.activitySummary(
                        rangeKey: range, agent: name, group: "skill", confidence: "all")) ?? []
                    result[name] = ActivityAgentCoverage(
                        capability: activityCapability(agent: name, category: "skills"),
                        calls: rows.reduce(0) { $0 + $1.calls },
                        exact: rows.reduce(0) { $0 + $1.exact },
                        derived: rows.reduce(0) { $0 + $1.derived })
                }
                continuation.resume(returning: result)
            }
        }
    }

    func activitySkillSummary(range: String, agent: String?, confidence: String) async
        -> [UsageStore.ActivitySummaryRow] {
        let store = readStore
        return await withCheckedContinuation { continuation in
            queryQueue.async {
                continuation.resume(returning: (try? store.activitySummary(
                    rangeKey: range, agent: agent, group: "skill", confidence: confidence)) ?? [])
            }
        }
    }

    func showInsightSession(tool:String,sessionID:String) {
        let path=readStore.path
        detailQueue.async { [weak self] in
            guard let row=try? UsageStore(path:path).sessions(rangeKey:"all",tool:tool,limit:300,query:sessionID).first(where:{$0.sessionID==sessionID}) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.sessionRows.contains(where:{$0.tool==tool && $0.sessionID==sessionID}) { self.sessionRows.insert(row,at:0) }
                self.selectedSessionID=SessionRowModel(row:row).id
                self.showSessionDetail()
            }
        }
    }

    /// 会话详情走查询队列：选中一行不应该在主线程读库（大库时会顿）。
    func sessionDetail(tool: String, sessionID: String) async -> UsageStore.SessionDetail? {
        let path = readStore.path
        return await withCheckedContinuation { cont in
            detailQueue.async {
                cont.resume(returning: try? UsageStore(path:path).sessionDetail(tool: tool, sessionID: sessionID))
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
            let accounts: [CodexAccount]
            do { accounts = try switcher.store.loadChecked() } catch {
                DispatchQueue.main.async { self?.accountNotice = UIFormat.appError(error) }; return
            }
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
                let message = L10n.message("已保存账号「\(account.name)」")
                DispatchQueue.main.async {
                    self?.codexAccounts = accounts
                    self?.activeCodexAccountID = active
                    self?.accountNotice = message
                }
            } catch {
                let message = L10n.message("保存失败：\(UIFormat.appError(error))")
                DispatchQueue.main.async { self?.accountNotice = message }
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
                    self?.accountNotice = L10n.message("已切换，请重启 Codex 生效")
                    self?.officialQuotaService = OfficialQuotaService()
                    self?.insights.mutate { store in
                        _ = try store.conn.execute("DELETE FROM quota_samples WHERE identity LIKE 'codex:%'")
                        try store.conn.commit()
                    }
                    self?.refreshQuotas()
                }
            } catch {
                let message = (error as? AccountPersistenceError) == .historyAfterSwitch
                    ? L10n.message("切换已完成，但记录保存失败") : L10n.message("切换失败：\(UIFormat.appError(error))")
                let switched = (error as? AccountPersistenceError) == .historyAfterSwitch
                let active = switched ? switcher.activeAccountID() : nil
                DispatchQueue.main.async {
                    self?.accountNotice = message
                    if switched {
                        self?.activeCodexAccountID = active
                        self?.officialQuotaService = OfficialQuotaService()
                        self?.insights.mutate { store in
                            _ = try store.conn.execute("DELETE FROM quota_samples WHERE identity LIKE 'codex:%'")
                            try store.conn.commit()
                        }
                        self?.refreshQuotas()
                    }
                }
            }
        }
    }

    func removeCodexAccount(id: String) {
        let switcher = accountSwitcher
        queryQueue.async { [weak self] in
            let accounts: [CodexAccount]
            do { accounts = try switcher.store.remove(id) } catch {
                DispatchQueue.main.async { self?.accountNotice = UIFormat.appError(error) }; return
            }
            DispatchQueue.main.async { self?.codexAccounts = accounts }
        }
    }

    func renameCodexAccount(id: String, name: String) {
        let switcher = accountSwitcher
        queryQueue.async { [weak self] in
            let accounts: [CodexAccount]
            do { accounts = try switcher.store.rename(id, name: name) } catch {
                DispatchQueue.main.async { self?.accountNotice = UIFormat.appError(error) }; return
            }
            DispatchQueue.main.async { self?.codexAccounts = accounts }
        }
    }
}
