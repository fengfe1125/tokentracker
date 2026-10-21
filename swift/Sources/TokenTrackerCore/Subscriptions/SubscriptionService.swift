import Foundation

public final class SubscriptionService: @unchecked Sendable {
    public let discovery: SubscriptionDiscovery
    public let client: SubscriptionClient
    private let lock = NSLock()
    private var cache: [String:(Date, SubscriptionSnapshot)] = [:]
    private let ttl: TimeInterval = 5 * 60
    private let staleMax: TimeInterval = 24 * 60 * 60
    public init(ctx: BillingContext = BillingContext(), http: @escaping BillingHTTP = SubscriptionHTTP.call) {
        discovery = SubscriptionDiscovery(home: ctx.home, env: ctx.env)
        client = SubscriptionClient(http: http)
    }
    public func refresh(extraDirectories: [String] = []) -> [SubscriptionCard] {
        let accounts = discovery.discover(extraDirectories: extraDirectories)
        let now = Date()
        let out = Array(repeating: SubscriptionCard(account: SubscriptionAccount(provider:"",identity:"",label:"",plan:"",sources:[],active:false,credential:[:]), snapshot: SubscriptionSnapshot(status:.loading)), count: accounts.count)
        var results = out
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: accounts.count) { index in
            let account=accounts[index]
            gate.wait()
            defer { gate.signal() }
            let snapshot: SubscriptionSnapshot
            let key=account.provider+":"+account.fingerprint
            lock.lock(); let cached=cache[key]; lock.unlock()
            if let cached, now.timeIntervalSince(cached.0) < ttl {
                snapshot=cached.1
            } else {
                let fresh=client.fetch(account)
                if fresh.status == .current || fresh.status == .stale {
                    lock.lock(); cache[key]=(now,fresh); lock.unlock(); snapshot=fresh
                } else if let cached, now.timeIntervalSince(cached.0) < staleMax {
                    var stale=cached.1; stale.status = .stale; stale.message = fresh.message.isEmpty ? "官方数据暂时不可用" : fresh.message; snapshot=stale
                } else { snapshot=fresh }
            }
            results[index]=SubscriptionCard(account:account,snapshot:snapshot)
        }
        return results.filter { !$0.account.provider.isEmpty }.sorted { ($0.account.provider,$0.account.identity) < ($1.account.provider,$1.account.identity) }
    }
}
