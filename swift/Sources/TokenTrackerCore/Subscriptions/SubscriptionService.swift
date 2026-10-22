//
//  SubscriptionService.swift
//  TokenTrackerCore
//
//  查询调度：账号只来自 TokenTracker 自己的账号库（自有登录与用户添加/导入的
//  API Key），不读取其他软件的配置。会话临近过期时由 TokenTracker 自行续期。
//  成功结果缓存 5 分钟；单请求 15 秒超时；最多 4 个并发；遵守 Retry-After；
//  账号独立缓存，单家失败不阻塞其他卡片。失败时可展示 24 小时内的上一份官方
//  结果并标注过期。重新登录（新的账号记录）即为新缓存。
//

import Foundation

public final class SubscriptionService: @unchecked Sendable {
    public static let ttl: TimeInterval = 5 * 60
    public static let retryAfterNetworkError: TimeInterval = 60
    public static let staleLimit: TimeInterval = 24 * 60 * 60
    public static let maxConcurrentRequests = 4

    struct Entry {
        var fingerprint: String
        var latest: SubscriptionSnapshot
        var lastGood: SubscriptionSnapshot?
        var nextAttempt: Date
    }

    private let store: SubscriptionAccountStore
    private let transport: SubscriptionTransport
    private let clock: () -> Date
    private let cachePath: String?
    private let lock = NSLock()
    private var accounts: [SubscriptionAccount] = []
    private var stored: [String: StoredSubscriptionAccount] = [:]
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    public convenience init(store: SubscriptionAccountStore = SubscriptionAccountStore(),
                            transport: @escaping SubscriptionTransport = SubscriptionHTTP.live,
                            cachePath: String? = NSHomeDirectory() + "/.tokentracker/subscription_cache.json") {
        self.init(store: store, transport: transport, cachePath: cachePath, clock: Date.init)
    }

    init(store: SubscriptionAccountStore, transport: @escaping SubscriptionTransport,
         cachePath: String?, clock: @escaping () -> Date) {
        self.store = store
        self.transport = transport
        self.cachePath = cachePath
        self.clock = clock
        loadPersisted()
    }

    public var accountStore: SubscriptionAccountStore { store }

    // ------------------------------------------------------------ 账号 ----

    /// 重新读取账号库；返回账号是否变化。
    @discardableResult
    public func discover() -> Bool {
        let records = store.load()
        let found = Self.accounts(records)
        lock.lock(); defer { lock.unlock() }
        stored = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard found != accounts else { return false }
        accounts = found
        let ids = Set(found.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        return true
    }

    static func accountID(_ record: StoredSubscriptionAccount) -> String {
        record.provider.rawValue + ":" + record.id
    }

    /// 账号库记录 → 展示账号。菜单栏账号：用户指定的那个；未指定且该供应商只有一个账号时就是它。
    static func accounts(_ records: [StoredSubscriptionAccount]) -> [SubscriptionAccount] {
        records.map { record in
            let siblings = records.filter { $0.provider == record.provider }
            let chosen = siblings.contains { $0.menuBar }
            let location: String
            switch record.origin {
            case .login: location = "自有登录"
            case .manual: location = "手动添加"
            case .imported: location = "导入自 " + (record.importedFrom ?? "本机配置")
            }
            var account = SubscriptionAccount(
                provider: record.provider, label: record.label,
                source: SubscriptionSource(tool: "TokenTracker", location: location),
                isActive: chosen ? record.menuBar : siblings.count == 1,
                credential: record.credential, providerAccountID: record.accountID,
                discoveryProblem: record.provider == .zenFree ? .freeModel : nil)
            account.id = accountID(record)
            return account
        }.sorted { SubscriptionCard.ordered(SubscriptionCard(account: $0, snapshot: .init(status: .loading)),
                                            SubscriptionCard(account: $1, snapshot: .init(status: .loading))) }
    }

    // ------------------------------------------------------------ 查询 ----

    /// 查询到期账号。阻塞直到本轮完成，每个账号完成后回调一次最新卡片（后台线程）。
    public func refresh(force: Bool = false, onUpdate: (@Sendable ([SubscriptionCard]) -> Void)? = nil) {
        let now = clock()
        lock.lock()
        let due = accounts.filter { account in
            guard !inFlight.contains(account.id) else { return false }
            guard let entry = entries[account.id], entry.fingerprint == Self.fingerprint(account) else { return true }
            // 强制刷新也不越过 Retry-After。
            if let retry = entry.latest.retryAt, retry > now { return false }
            return force || entry.nextAttempt <= now
        }
        due.forEach { inFlight.insert($0.id) }
        lock.unlock()
        guard !due.isEmpty else { return }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = Self.maxConcurrentRequests
        queue.qualityOfService = .utility
        for account in due {
            queue.addOperation { [self] in
                let started = clock()
                let snapshot = fetch(account, at: started)
                lock.lock()
                inFlight.remove(account.id)
                var entry = entries[account.id].flatMap { $0.fingerprint == Self.fingerprint(account) ? $0 : nil }
                    ?? Entry(fingerprint: Self.fingerprint(account), latest: snapshot, lastGood: nil, nextAttempt: started)
                entry.latest = snapshot
                if snapshot.status == .current { entry.lastGood = snapshot }
                entry.nextAttempt = Self.nextAttempt(after: snapshot, at: started)
                // 发现结果已变（账号被移除或登录态变化）时丢弃这次结果。
                if accounts.contains(where: { $0.id == account.id && Self.fingerprint($0) == entry.fingerprint }) {
                    entries[account.id] = entry
                }
                lock.unlock()
                if snapshot.status == .current { persist() }
                onUpdate?(cards())
            }
        }
        queue.waitUntilAllOperationsAreFinished()
    }

    /// 续期（需要时）→ 查询；401 时用刷新令牌再试一次。刷新结果写回账号库。
    private func fetch(_ account: SubscriptionAccount, at now: Date) -> SubscriptionSnapshot {
        lock.lock(); var record = stored[String(account.id.split(separator: ":", maxSplits: 1).last ?? "")]; lock.unlock()
        var current = account
        func renew() -> SubscriptionAuth.RefreshResult {
            guard var updated = record else { return .notNeeded }
            let result = SubscriptionAuth.refresh(&updated, now: now, transport: transport)
            if result == .refreshed {
                try? store.updateTokens(updated)
                record = updated
                current.credential = updated.credential
                lock.lock(); stored[updated.id] = updated; lock.unlock()
            }
            return result
        }
        var renewed = false
        if let r = record, SubscriptionAuth.needsRefresh(r, now: now) {
            switch renew() {
            case .refreshed: renewed = true
            case .rejected: return .failure(.expired, .unauthorized)
            case .failed, .notNeeded: break
            }
        }
        let context = SubscriptionFetchContext(transport: transport, now: now)
        var snapshot = SubscriptionAdapters.fetch(current, context)
        if snapshot.problem == .unauthorized, !renewed, record?.refreshToken != nil, renew() == .refreshed {
            snapshot = SubscriptionAdapters.fetch(current, context)
        }
        return snapshot
    }

    static func nextAttempt(after snapshot: SubscriptionSnapshot, at time: Date) -> Date {
        var next = time.addingTimeInterval(ttl)
        if snapshot.problem == .network || snapshot.problem == .timeout {
            next = time.addingTimeInterval(retryAfterNetworkError)
        }
        if let retry = snapshot.retryAt, retry > next { next = retry }
        return next
    }

    /// 账号记录 id 稳定（自行续期不改变）；重新登录生成新记录。
    static func fingerprint(_ account: SubscriptionAccount) -> String {
        account.id + ":" + (account.discoveryProblem?.rawValue ?? "")
    }

    // ------------------------------------------------------------ 展示 ----

    public func cards() -> [SubscriptionCard] {
        let now = clock()
        lock.lock()
        let cards = accounts.map { account -> SubscriptionCard in
            guard let entry = entries[account.id], entry.fingerprint == Self.fingerprint(account) else {
                return SubscriptionCard(account: account, snapshot: SubscriptionSnapshot(status: .loading))
            }
            return SubscriptionCard(account: account, snapshot: Self.display(entry, now: now))
        }
        lock.unlock()
        return Self.mergeByAccount(cards)
    }

    /// 最新官方 → 24 小时内的上一份官方结果（标注过期并保留失败原因）→ 状态本身。
    static func display(_ entry: Entry, now: Date) -> SubscriptionSnapshot {
        if entry.latest.status == .current || entry.latest.status == .loading { return entry.latest }
        guard let good = entry.lastGood, let sampled = good.sampledAt,
              now.timeIntervalSince(sampled) < staleLimit,
              [.failed, .expired, .forbidden].contains(entry.latest.status) else { return entry.latest }
        var stale = good
        stale.status = .stale
        stale.problem = entry.latest.problem
        stale.httpStatus = entry.latest.httpStatus
        stale.retryAt = entry.latest.retryAt
        return stale
    }

    /// 查询后得到同一供应商账号 ID 的多张卡合并为一张；缺少可靠 ID 的不合并。
    static func mergeByAccount(_ cards: [SubscriptionCard]) -> [SubscriptionCard] {
        func rank(_ s: SubscriptionStatus) -> Int {
            switch s {
            case .current: return 4
            case .stale: return 3
            case .loading: return 2
            default: return 1
            }
        }
        var result: [SubscriptionCard] = []
        var byKey: [String: Int] = [:]
        for card in cards.sorted(by: SubscriptionCard.ordered) {
            guard let key = card.snapshot.accountKey ?? card.account.accountKey else {
                result.append(card)
                continue
            }
            let groupKey = card.account.provider.rawValue + "|" + key
            guard let index = byKey[groupKey] else {
                byKey[groupKey] = result.count
                result.append(card)
                continue
            }
            var kept = result[index]
            kept.account.sources = Array(Set(kept.account.sources + card.account.sources)).sorted()
            kept.account.isActive = kept.account.isActive || card.account.isActive
            if kept.account.label.isEmpty { kept.account.label = card.account.label }
            if kept.account.planHint.isEmpty { kept.account.planHint = card.account.planHint }
            if rank(card.snapshot.status) > rank(kept.snapshot.status) { kept.snapshot = card.snapshot }
            result[index] = kept
        }
        return result.sorted(by: SubscriptionCard.ordered)
    }

    /// 菜单栏圆环：只绑定该供应商当前登录的唯一账号；无法确定时返回 nil（显示不可用）。
    public static func menuBarCard(_ cards: [SubscriptionCard], provider: SubscriptionProvider) -> SubscriptionCard? {
        let active = cards.filter { $0.account.provider == provider && $0.account.isActive }
        return active.count == 1 ? active[0] : nil
    }

    // ------------------------------------------------------------ 持久 ----

    /// 只持久化可安全落盘的快照（无令牌、邮箱、原始账号 ID 或路径），供失败时展示过期结果。
    private struct Persisted: Codable {
        var fingerprint: String
        var snapshot: SubscriptionSnapshot
    }

    private func loadPersisted() {
        guard let cachePath, let data = FileManager.default.contents(atPath: cachePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode([String: Persisted].self, from: data) else { return }
        let now = clock()
        for (id, item) in stored {
            guard let sampled = item.snapshot.sampledAt, now.timeIntervalSince(sampled) < Self.staleLimit else { continue }
            // 启动后立即到期：先显示过期结果，再查询。
            var latest = item.snapshot
            latest.status = .failed
            latest.problem = nil
            entries[id] = Entry(fingerprint: item.fingerprint, latest: latest, lastGood: item.snapshot,
                                nextAttempt: .distantPast)
        }
    }

    private func persist() {
        guard let cachePath else { return }
        lock.lock()
        var stored: [String: Persisted] = [:]
        for (id, entry) in entries {
            if let good = entry.lastGood { stored[id] = Persisted(fingerprint: entry.fingerprint, snapshot: good) }
        }
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        let directory = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = cachePath + ".tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary, cachePath) != 0 { try? FileManager.default.removeItem(atPath: temporary) }
    }
}
