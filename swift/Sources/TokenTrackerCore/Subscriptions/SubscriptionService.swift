//
//  SubscriptionService.swift
//  TokenTrackerCore
//
//  发现 + 查询调度：成功结果缓存 5 分钟；单请求 15 秒超时；最多 4 个并发；
//  遵守 Retry-After；账号独立缓存，单家失败不阻塞其他卡片。失败时可展示
//  24 小时内的上一份官方结果并标注过期，超过期限只显示状态。登录态变化
//  （凭据指纹改变）立即失效该账号缓存。
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

    private let discovery: SubscriptionDiscovery
    private let transport: SubscriptionTransport
    private let clock: () -> Date
    private let cachePath: String?
    private let lock = NSLock()
    private var accounts: [SubscriptionAccount] = []
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    public convenience init(home: String = NSHomeDirectory(),
                            env: [String: String] = ProcessInfo.processInfo.environment,
                            transport: @escaping SubscriptionTransport = SubscriptionHTTP.live,
                            cachePath: String? = NSHomeDirectory() + "/.tokentracker/subscription_cache.json") {
        self.init(discovery: SubscriptionDiscovery(home: home, env: env), transport: transport,
                  cachePath: cachePath, clock: Date.init)
    }

    init(discovery: SubscriptionDiscovery, transport: @escaping SubscriptionTransport,
         cachePath: String?, clock: @escaping () -> Date) {
        self.discovery = discovery
        self.transport = transport
        self.cachePath = cachePath
        self.clock = clock
        loadPersisted()
    }

    // ------------------------------------------------------------ 发现 ----

    /// 重新发现本机账号；返回账号或登录态是否变化。
    @discardableResult
    public func discover(extraDirectories: [String] = []) -> Bool {
        let found = discovery.discover(extraDirectories: extraDirectories)
        lock.lock(); defer { lock.unlock() }
        guard found != accounts else { return false }
        accounts = found
        // 登录态变化：指纹不同的旧条目（含过期备份）一并丢弃。
        for account in found {
            if let entry = entries[account.id], entry.fingerprint != Self.fingerprint(account) {
                entries[account.id] = nil
            }
        }
        return true
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
                let snapshot = SubscriptionAdapters.fetch(account, SubscriptionFetchContext(
                    transport: transport, now: started, env: discovery.env))
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

    static func nextAttempt(after snapshot: SubscriptionSnapshot, at time: Date) -> Date {
        var next = time.addingTimeInterval(ttl)
        if snapshot.problem == .network || snapshot.problem == .timeout {
            next = time.addingTimeInterval(retryAfterNetworkError)
        }
        if let retry = snapshot.retryAt, retry > next { next = retry }
        return next
    }

    static func fingerprint(_ account: SubscriptionAccount) -> String {
        account.credential?.fingerprint ?? "none:" + (account.discoveryProblem?.rawValue ?? "")
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
