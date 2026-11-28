import XCTest
@testable import TokenTrackerCore

/// 订阅发现与查询：全部使用临时目录、虚构凭据和虚构 HTTP 响应。
final class SubscriptionTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tt-sub-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relative: String, _ object: Any) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func writeText(_ relative: String, _ text: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func discovery(env: [String: String] = [:], keychain: [String: Any]? = nil) -> SubscriptionDiscovery {
        SubscriptionDiscovery(home: home.path, env: env, keychainRead: { keychain })
    }

    /// 虚构 JWT（不验签，只放声明）。
    private func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0." + payload + ".sig"
    }

    private final class FakeTransport: @unchecked Sendable {
        let lock = NSLock()
        var requests: [SubscriptionRequest] = []
        var active = 0
        var maxActive = 0
        var delay: TimeInterval = 0
        var handler: (SubscriptionRequest) -> SubscriptionResponse

        init(_ handler: @escaping (SubscriptionRequest) -> SubscriptionResponse) { self.handler = handler }

        var transport: SubscriptionTransport {
            { [self] request in
                lock.lock(); requests.append(request); active += 1; maxActive = max(maxActive, active); lock.unlock()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                let response = handler(request)
                lock.lock(); active -= 1; lock.unlock()
                return response
            }
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    // ---------------------------------------------------------- 发现 ----

    func testDiscoversKnownSourcesWithoutExecutingOrGuessing() throws {
        let future = 1_800_000_000_000.0 + 3_600_000
        try write(".codex/auth.json", ["tokens": ["access_token": jwt(["exp": 1_900_000_000,
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1", "chatgpt_user_id": "user-1"]]),
            "account_id": "acct-1"]])
        try write(".local/share/opencode/auth.json", [
            "opencode-go": ["type": "api", "key": "go-key-1"],
            // refresh 是 GitHub token；expires 只属于短期 Copilot token，不得判为过期。
            "github-copilot": ["type": "oauth", "refresh": "gho_fixture", "access": "tid=short", "expires": 1],
            "kimi-for-coding": ["type": "api", "key": "sk-kimi-fixture"],
        ])
        try write(".pi/agent/auth.json", ["minimax-cn": ["type": "api_key", "key": "mm-key"],
                                         "anthropic": ["type": "oauth", "access": "pi-claude", "expires": future]])
        try write(".config/magpie/plugin-auth.json", [
            "grok": ["type": "oauth", "access": jwt(["sub": "grok-user"]), "accountId": "grok@example.com", "expires": future],
            "workbuddy": ["type": "oauth", "access": "wb-token", "uid": "uid-1", "domain": "example.domain", "accountId": "WB"],
            "zcode": ["type": "oauth", "access": "z", "accountId": "z@example.com",
                      "refresh": #"{"site":"zai","device":"dev","key":"zai-key","base":"https://api.z.ai/api/anthropic"}"#],
            "opencode-zen-free": ["type": "api", "key": "public"],
        ])
        try writeText(".dsh/.credentials.yaml", """
            version: 1
            refs:
              DEEPSEEK_API_KEY: sk-deepseek-fixture
              OPENCODE_GO_API_KEY: go-key-1
              MINIMAX_CN_API_KEY: ${NOT_RESOLVED}
            records:
              deepseek-account-platform/default:
                kind: grant
            """)
        try writeText(".hermes/.env", "DEEPSEEK_API_KEY=sk-relay\nDEEPSEEK_BASE_URL=https://relay.example.net/v1\n")

        let accounts = discovery().discover()
        func of(_ p: SubscriptionProvider) -> [SubscriptionAccount] { accounts.filter { $0.provider == p } }

        XCTAssertEqual(of(.codex).count, 1)
        XCTAssertTrue(of(.codex)[0].isActive)
        XCTAssertEqual(of(.codex)[0].credential?.extra["account"], "acct-1")
        // 同一把 Go Key 在 OpenCode 与 DSH 中：合并为一个账号、两个来源。
        XCTAssertEqual(of(.go).count, 1)
        XCTAssertEqual(of(.go)[0].sources.map(\.tool).sorted(), ["DSH", "OpenCode"])
        XCTAssertTrue(of(.go)[0].isActive)
        XCTAssertEqual(of(.copilot).first?.credential?.token, "gho_fixture")
        XCTAssertNil(of(.copilot).first?.credential?.expiresAt)
        XCTAssertEqual(of(.kimi).first?.credential?.kind, .apiKey)
        XCTAssertEqual(of(.minimax).first?.credential?.extra["host"], "api.minimaxi.com", "未解析的插值不得成为凭据")
        XCTAssertEqual(of(.minimax).count, 1)
        XCTAssertEqual(of(.claude).first?.isActive, false, "Pi 的 Claude 登录不是 Claude Code 当前登录")
        XCTAssertEqual(of(.grok).first?.providerAccountID, "grok-user")
        XCTAssertEqual(of(.workbuddy).first?.credential?.extra["uid"], "uid-1")
        XCTAssertEqual(of(.zcode).first?.credential?.extra["root"], "https://api.z.ai")
        XCTAssertEqual(of(.zenFree).first?.discoveryProblem, .freeModel)
        // DeepSeek：DSH 官方 Key 可查；Hermes 配给中转的 Key 只列出原因，不发往官方。
        let deepseek = of(.deepseek)
        XCTAssertEqual(deepseek.count, 2)
        XCTAssertEqual(deepseek.compactMap { $0.credential?.token }, ["sk-deepseek-fixture"])
        XCTAssertEqual(deepseek.compactMap(\.discoveryProblem), [.relayEndpoint])
        // DSH 账号平台授权不算 DeepSeek 余额来源。
        XCTAssertFalse(accounts.contains { $0.credential?.token == "grant" })
    }

    func testCustomDirectoryAndEnvironmentOverrides() throws {
        try write("elsewhere/codex/auth.json", ["tokens": ["access_token": "tok-env", "account_id": "acct-env"]])
        try write("custom/.credentials.json", ["claudeAiOauth": ["accessToken": "claude-custom", "subscriptionType": "max"]])
        let accounts = discovery(env: ["CODEX_HOME": home.path + "/elsewhere/codex", "DEEPSEEK_API_KEY": "sk-env"])
            .discover(extraDirectories: [home.path + "/custom"])
        XCTAssertEqual(accounts.first { $0.provider == .codex }?.credential?.token, "tok-env")
        let claude = try XCTUnwrap(accounts.first { $0.provider == .claude })
        XCTAssertEqual(claude.planHint, "Max")
        XCTAssertFalse(claude.isActive, "自定义目录不是当前登录")
        XCTAssertEqual(accounts.first { $0.provider == .deepseek }?.sources.first?.location, "DEEPSEEK_API_KEY")
    }

    func testDedupeUsesAccountIDOrIdenticalCredentialNeverEmail() throws {
        // 同邮箱、不同凭据、没有账号 ID：保持两个账号。
        try write(".config/magpie/logins.json", [
            ["agent": "claude", "user": "same@example.com", "auth": ["claudeAiOauth": ["accessToken": "a"]]],
            ["agent": "claude", "user": "same@example.com", "auth": ["claudeAiOauth": ["accessToken": "b"]]],
            // 同一账号 ID：合并。
            ["agent": "claude", "user": "x@example.com", "auth": ["claudeAiOauth": ["accessToken": "c"]],
             "profile": ["accountUuid": "uuid-1"]],
            ["agent": "claude", "user": "", "auth": ["claudeAiOauth": ["accessToken": "d"]],
             "profile": ["accountUuid": "uuid-1"]],
        ])
        try write(".local/share/opencode/auth.json", ["deepseek": ["type": "api", "key": "sk-1"]])
        try write(".pi/agent/auth.json", ["deepseek": ["type": "api_key", "key": "sk-2"]])
        let accounts = discovery().discover()
        XCTAssertEqual(accounts.filter { $0.provider == .claude }.count, 3)
        XCTAssertEqual(accounts.filter { $0.provider == .claude && $0.providerAccountID == "uuid-1" }.first?.label, "x@example.com")
        XCTAssertEqual(accounts.filter { $0.provider == .deepseek }.count, 2, "多把 Key 分别展示，不叠加")
    }

    func testRelayBaseURLFromOpenCodeConfigIsNotSentToOfficialHost() throws {
        try write(".local/share/opencode/auth.json", ["deepseek": ["type": "api", "key": "sk-relay"]])
        try writeText(".config/opencode/opencode.jsonc", """
            {
              // comment
              "provider": { "deepseek": { "options": { "baseURL": "https://relay.example.net/v1" } } }
            }
            """)
        let account = try XCTUnwrap(discovery().discover().first { $0.provider == .deepseek })
        XCTAssertNil(account.credential)
        XCTAssertEqual(account.discoveryProblem, .relayEndpoint)
    }

    // ------------------------------------------------------- 适配器 ----

    private func ctx(_ fake: FakeTransport, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SubscriptionFetchContext {
        SubscriptionFetchContext(transport: fake.transport, now: now)
    }

    private func account(_ provider: SubscriptionProvider, _ token: String = "tok", kind: SubscriptionCredential.Kind = .apiKey,
                         expires: Date? = nil, extra: [String: String] = [:], id: String? = nil,
                         active: Bool = false) -> SubscriptionAccount {
        SubscriptionAccount(provider: provider, source: SubscriptionSource(tool: "Test", location: "fixture"), isActive: active,
                            credential: SubscriptionCredential(kind: kind, token: token, expiresAt: expires, extra: extra),
                            providerAccountID: id)
    }

    func testDeepSeekBalanceKeepsDecimalPrecisionZeroAndMissing() {
        let fake = FakeTransport { request in
            XCTAssertEqual(request.url.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.headers["Authorization"], "Bearer sk-x")
            return SubscriptionResponse(status: 200, json: ["is_available": false, "balance_infos": [
                ["currency": "CNY", "total_balance": "12345678.91", "granted_balance": "0.00", "topped_up_balance": "unknown"],
                ["currency": "USD", "total_balance": 0.1],
            ]])
        }
        let snapshot = SubscriptionAdapters.fetch(account(.deepseek, "sk-x"), ctx(fake))
        XCTAssertEqual(snapshot.status, .current)
        XCTAssertEqual(snapshot.balances[0].total, Decimal(string: "12345678.91"))
        XCTAssertEqual(snapshot.balances[0].granted, Decimal(0), "真实零值保留为 0")
        XCTAssertNil(snapshot.balances[0].toppedUp, "非数字不当作 0")
        XCTAssertEqual(snapshot.balances[1].total, Decimal(string: "0.1"))
        XCTAssertEqual(snapshot.problem, .balanceUnavailable)
        XCTAssertTrue(snapshot.windows.isEmpty, "余额没有总上限，不生成百分比窗口")
    }

    func testHTTPFailuresMapToStatuses() {
        let cases: [(SubscriptionResponse, SubscriptionStatus, SubscriptionProblem)] = [
            (SubscriptionResponse(status: 401), .expired, .unauthorized),
            (SubscriptionResponse(status: 403), .forbidden, .forbidden),
            (SubscriptionResponse(status: 429, retryAfter: 120), .failed, .rateLimited),
            (SubscriptionResponse(status: 0, failure: .timeout), .failed, .timeout),
            (SubscriptionResponse(status: 503), .failed, .httpStatus),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (response, status, problem) in cases {
            let snapshot = SubscriptionAdapters.fetch(account(.go), ctx(FakeTransport { _ in response }, now: now))
            XCTAssertEqual(snapshot.status, status)
            XCTAssertEqual(snapshot.problem, problem)
            XCTAssertTrue(snapshot.windows.isEmpty)
            if problem == .rateLimited { XCTAssertEqual(snapshot.retryAt, now.addingTimeInterval(120)) }
        }
    }

    func testExplicitNoSubscriptionIsNotReportedAsMalformed() {
        let minimax = SubscriptionAdapters.fetch(account(.minimax, extra: ["host": "api.minimaxi.com"]), ctx(FakeTransport { _ in
            SubscriptionResponse(status: 200, json: ["base_resp": ["status_code": 2062, "status_msg": "no active token plan subscription"]])
        }))
        XCTAssertEqual(minimax.problem, .noSubscription)
        let zcode = SubscriptionAdapters.fetch(account(.zcode, kind: .oauth, extra: ["key": "k", "root": "https://api.z.ai"]),
                                               ctx(FakeTransport { _ in
            SubscriptionResponse(status: 200, json: ["code": 500, "msg": "当前用户不存在coding plan", "success": false])
        }))
        XCTAssertEqual(zcode.problem, .noSubscription)
        XCTAssertEqual(zcode.status, .forbidden)
    }

    func testExpiredCredentialIsNotSent() {
        let fake = FakeTransport { _ in SubscriptionResponse(status: 200) }
        let snapshot = SubscriptionAdapters.fetch(account(.claude, kind: .oauth, expires: Date(timeIntervalSince1970: 1)), ctx(fake))
        XCTAssertEqual(snapshot.status, .expired)
        XCTAssertEqual(fake.count, 0)
    }

    func testCredentialsOnlyGoToRegisteredHosts() {
        XCTAssertFalse(SubscriptionHTTP.permits(URL(string: "http://api.deepseek.com/user/balance")!, hosts: ["api.deepseek.com"]))
        XCTAssertFalse(SubscriptionHTTP.permits(URL(string: "https://api.deepseek.com:8443/x")!, hosts: ["api.deepseek.com"]))
        XCTAssertFalse(SubscriptionHTTP.permits(URL(string: "https://u:p@api.deepseek.com/x")!, hosts: ["api.deepseek.com"]))
        XCTAssertFalse(SubscriptionHTTP.permits(URL(string: "https://api.deepseek.com.evil.net/x")!, hosts: ["api.deepseek.com"]))
        // Kimi 的 host 来自配置：非登记域名被拦截，请求不发出。
        let fake = FakeTransport { _ in SubscriptionResponse(status: 200) }
        let snapshot = SubscriptionAdapters.fetch(account(.kimi, extra: ["host": "evil.example.com"]), ctx(fake))
        XCTAssertEqual(snapshot.problem, .untrustedEndpoint)
        XCTAssertEqual(fake.count, 0)
        // DeepSeek 的 Key 不会被发往其他供应商域名。
        XCTAssertEqual(SubscriptionAdapters.send(.deepseek, SubscriptionRequest(url: URL(string: "https://api.kimi.com/x")!),
                                                 ctx(fake)).failure, .blocked)
    }

    func testRetryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SubscriptionHTTP.retryAfter("30", now: now), 30)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(SubscriptionHTTP.retryAfter(f.string(from: now.addingTimeInterval(45)), now: now) ?? -1, 45, accuracy: 1)
        XCTAssertNil(SubscriptionHTTP.retryAfter("soon", now: now))
    }

    func testWindowsKeepMissingDistinctFromZero() {
        let claude = SubscriptionAdapters.claudeWindows([
            "five_hour": ["utilization": 0, "resets_at": "2027-01-15T08:00:00Z"],
            "seven_day": ["utilization": NSNull()],
            "seven_day_opus": ["utilization": 12.5],
        ])
        XCTAssertEqual(claude.map(\.id), ["five_hour", "seven_day_opus"])
        XCTAssertEqual(claude[0].usedPercent, 0)
        XCTAssertNotNil(claude[0].resetsAt)
        XCTAssertEqual(claude[1].name, "Opus")
        // Copilot：不限量的配额不画百分比；有总额与剩余时按官方数字计算。
        let fake = FakeTransport { _ in SubscriptionResponse(status: 200, json: [
            "copilot_plan": "individual", "quota_reset_date": "2027-02-01", "login": "octo",
            "quota_snapshots": ["chat": ["unlimited": true],
                                "premium_interactions": ["entitlement": 300, "remaining": 210, "unlimited": false]]])
        }
        let copilot = SubscriptionAdapters.fetch(account(.copilot, "gho_x", kind: .oauth), ctx(fake))
        XCTAssertEqual(copilot.windows.map(\.id), ["premium_interactions"])
        XCTAssertEqual(copilot.windows[0].usedPercent ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(fake.requests.first?.headers["Authorization"], "token gho_x")
        XCTAssertTrue(copilot.privateAPI)
    }

    func testOfficialWindowsAreShownAsReturnedWithoutMonthlyPadding() {
        let fake = FakeTransport { _ in SubscriptionResponse(status: 200, json: [
            "plan_type": "plus", "rate_limit": ["primary_window": ["used_percent": 7, "limit_window_seconds": 18_000,
                                                                   "reset_at": 1_800_010_000]]])
        }
        let snapshot = SubscriptionAdapters.fetch(account(.codex, kind: .oauth, extra: ["account": "acct"]), ctx(fake))
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.plan, "Plus")
        XCTAssertEqual(fake.requests.first?.headers["ChatGPT-Account-Id"], "acct")
    }

    // ---------------------------------------------------------- 服务 ----

    private var storePath: String { home.appendingPathComponent(".tokentracker/subscription_accounts.json").path }
    private var store: SubscriptionAccountStore { SubscriptionAccountStore(path: storePath) }

    private func service(_ fake: FakeTransport, clock: Clock, cachePath: String? = nil) -> SubscriptionService {
        SubscriptionService(store: store, transport: fake.transport, cachePath: cachePath, clock: { clock.now })
    }

    private let goOK = SubscriptionResponse(status: 200, json: ["usage": ["rolling": ["percent": 25]]])

    func testCachesFiveMinutesAndNewSignInStartsFresh() throws {
        let clock = Clock()
        let goOK = self.goOK
        let fake = FakeTransport { _ in goOK }
        let first = try store.addAPIKey(provider: .go, key: "go-1")
        let s = service(fake, clock: clock)
        s.discover()
        XCTAssertEqual(s.cards().first?.snapshot.status, .loading)
        s.refresh()
        XCTAssertEqual(fake.count, 1)
        clock.now += 60
        s.refresh()
        XCTAssertEqual(fake.count, 1, "5 分钟内使用缓存")
        try store.remove(id: first.id)
        try store.addAPIKey(provider: .go, key: "go-2")
        XCTAssertTrue(s.discover())
        XCTAssertEqual(s.cards().count, 1)
        XCTAssertEqual(s.cards().first?.snapshot.status, .loading, "新账号记录不沿用旧缓存")
        s.refresh()
        XCTAssertEqual(fake.count, 2)
        XCTAssertEqual(fake.requests.last?.headers["Authorization"], "Bearer go-2")
        clock.now += 301
        s.refresh()
        XCTAssertEqual(fake.count, 3)
    }

    func testOnlyStoredAccountsAreQueriedNeverOtherAppsConfigs() throws {
        try write(".local/share/opencode/auth.json", ["opencode-go": ["type": "api", "key": "foreign-key"]])
        try write(".codex/auth.json", ["tokens": ["access_token": "foreign-codex", "account_id": "x"]])
        let fake = FakeTransport { _ in SubscriptionResponse(status: 200) }
        let s = service(fake, clock: Clock())
        s.discover()
        s.refresh()
        XCTAssertTrue(s.cards().isEmpty)
        XCTAssertEqual(fake.count, 0)
    }

    func testStaleWithin24HoursThenStatusOnly() throws {
        let clock = Clock()
        var fail = false
        let goOK = self.goOK
        let fake = FakeTransport { _ in fail ? SubscriptionResponse(status: 0, failure: .network) : goOK }
        try store.addAPIKey(provider: .go, key: "go-1")
        let cache = home.appendingPathComponent("cache.json").path
        let s = service(fake, clock: clock, cachePath: cache)
        s.discover()
        s.refresh()
        fail = true
        clock.now += 301
        s.refresh()
        var card = try XCTUnwrap(s.cards().first)
        XCTAssertEqual(card.snapshot.status, .stale)
        XCTAssertEqual(card.snapshot.problem, .network)
        XCTAssertEqual(card.snapshot.windows.first?.usedPercent, 25)
        let text = try String(contentsOfFile: cache, encoding: .utf8)
        XCTAssertFalse(text.contains("go-1"), "缓存不含凭据")
        let restarted = service(fake, clock: clock, cachePath: cache)
        restarted.discover()
        XCTAssertEqual(restarted.cards().first?.snapshot.status, .stale)
        clock.now += 24 * 3600
        s.refresh(force: true)
        card = try XCTUnwrap(s.cards().first)
        XCTAssertEqual(card.snapshot.status, .failed)
        XCTAssertTrue(card.snapshot.windows.isEmpty)
    }

    func testForceRefreshStillHonorsRetryAfter() throws {
        let clock = Clock()
        let fake = FakeTransport { _ in SubscriptionResponse(status: 429, retryAfter: 900) }
        try store.addAPIKey(provider: .go, key: "go-1")
        let s = service(fake, clock: clock)
        s.discover()
        s.refresh()
        clock.now += 600
        s.refresh(force: true)
        XCTAssertEqual(fake.count, 1)
        clock.now += 301
        s.refresh(force: true)
        XCTAssertEqual(fake.count, 2)
    }

    func testAtMostFourConcurrentRequestsAndFailuresAreIsolated() throws {
        for i in 0..<9 { try store.addAPIKey(provider: .deepseek, key: "sk-\(i)") }
        let fake = FakeTransport { request in
            request.headers["Authorization"] == "Bearer sk-3"
                ? SubscriptionResponse(status: 500)
                : SubscriptionResponse(status: 200, json: ["balance_infos": [["currency": "CNY", "total_balance": "1.00"]]])
        }
        fake.delay = 0.05
        let s = service(fake, clock: Clock())
        s.discover()
        s.refresh()
        XCTAssertEqual(fake.count, 9)
        XCTAssertLessThanOrEqual(fake.maxActive, SubscriptionService.maxConcurrentRequests)
        let cards = s.cards()
        XCTAssertEqual(cards.count, 9, "多把 Key 分别展示，不叠加")
        XCTAssertEqual(cards.filter { $0.snapshot.status == .current }.count, 8)
        XCTAssertEqual(cards.filter { $0.snapshot.status == .failed }.count, 1)
    }

    // ------------------------------------------------------ 自有续期 ----

    private func claudeRecord(expires: Date, refresh: String? = "rt-1") -> StoredSubscriptionAccount {
        StoredSubscriptionAccount(provider: .claude, label: "me@example.com", kind: .oauth, origin: .login,
                                  token: "at-1", refreshToken: refresh, expiresAt: expires, accountID: "uuid-1")
    }

    private func claudeServer(refreshStatus: Int = 200, rejectFirstUsage: Bool = false) -> FakeTransport {
        var usageCalls = 0
        return FakeTransport { request in
            if request.url.path == "/v1/oauth/token" {
                return refreshStatus == 200
                    ? SubscriptionResponse(status: 200, json: ["access_token": "at-2", "refresh_token": "rt-2", "expires_in": 28_800])
                    : SubscriptionResponse(status: refreshStatus, json: ["error": "invalid_grant"])
            }
            usageCalls += 1
            if rejectFirstUsage && usageCalls == 1 { return SubscriptionResponse(status: 401) }
            return SubscriptionResponse(status: 200, json: ["five_hour": ["utilization": 12]])
        }
    }

    func testRenewsOwnSessionBeforeExpiryAndPersistsTokens() throws {
        let clock = Clock()
        try store.upsert(claudeRecord(expires: clock.now.addingTimeInterval(60)))
        let fake = claudeServer()
        let s = service(fake, clock: clock)
        s.discover()
        s.refresh()
        XCTAssertEqual(fake.requests.first?.url.host, "platform.claude.com")
        XCTAssertEqual(fake.requests.last?.headers["Authorization"], "Bearer at-2")
        XCTAssertEqual(s.cards().first?.snapshot.status, .current)
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.token, "at-2")
        XCTAssertEqual(saved.refreshToken, "rt-2")
        XCTAssertEqual(saved.expiresAt, clock.now.addingTimeInterval(28_800))
    }

    func testUnauthorizedTriggersOneRenewalAndRetry() throws {
        let clock = Clock()
        try store.upsert(claudeRecord(expires: clock.now.addingTimeInterval(3600)))
        let fake = claudeServer(rejectFirstUsage: true)
        let s = service(fake, clock: clock)
        s.discover()
        s.refresh()
        XCTAssertEqual(fake.count, 3)
        XCTAssertEqual(s.cards().first?.snapshot.status, .current)
    }

    func testRejectedRenewalAsksToSignInAgainWithoutQuerying() throws {
        let clock = Clock()
        try store.upsert(claudeRecord(expires: clock.now.addingTimeInterval(-60)))
        let fake = claudeServer(refreshStatus: 400)
        let s = service(fake, clock: clock)
        s.discover()
        s.refresh()
        XCTAssertEqual(fake.count, 1)
        XCTAssertEqual(s.cards().first?.snapshot.status, .expired)
        XCTAssertEqual(s.cards().first?.snapshot.problem, .unauthorized)
    }

    // ------------------------------------------------------ 账号库 ----

    func testStoreIsOwnerOnlyAndUpsertKeepsOneRecordPerAccount() throws {
        let first = try store.upsert(claudeRecord(expires: Date()))
        try store.setMenuBar(id: first.id)
        var again = claudeRecord(expires: Date().addingTimeInterval(100), refresh: "rt-new")
        again.label = ""
        let saved = try store.upsert(again)
        XCTAssertEqual(saved.id, first.id)
        XCTAssertTrue(saved.menuBar)
        XCTAssertEqual(saved.label, "me@example.com")
        XCTAssertEqual(store.load().count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: storePath)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testImportCopiesOnlyQueryableAPIKeysOnce() throws {
        try write(".local/share/opencode/auth.json", [
            "opencode-go": ["type": "api", "key": "go-key"],
            "anthropic": ["type": "oauth", "access": "foreign-oauth", "expires": 1],
        ])
        try writeText(".dsh/.credentials.yaml", "refs:\n  DEEPSEEK_API_KEY: sk-deepseek\n")
        try writeText(".hermes/.env", "DEEPSEEK_API_KEY=sk-relay\nDEEPSEEK_BASE_URL=https://relay.example.net\n")
        let source = discovery()
        XCTAssertEqual(try store.importAPIKeys(from: source), 2)
        XCTAssertEqual(try store.importAPIKeys(from: source), 0, "重复导入不新增")
        let records = store.load()
        XCTAssertEqual(Set(records.map(\.provider)), [.go, .deepseek])
        XCTAssertTrue(records.allSatisfy { $0.kind == .apiKey && $0.origin == .imported })
        XCTAssertFalse(records.contains { $0.token == "foreign-oauth" || $0.token == "sk-relay" })
        XCTAssertEqual(records.first { $0.provider == .deepseek }?.importedFrom, "DSH")
    }

    func testMenuBarAccountIsChosenOrTheOnlyOne() throws {
        let a = try store.upsert(claudeRecord(expires: Date()))
        var other = claudeRecord(expires: Date())
        other.accountID = "uuid-2"
        other.token = "at-other"
        let b = try store.upsert(other)
        var accounts = SubscriptionService.accounts(store.load())
        XCTAssertEqual(accounts.filter(\.isActive).count, 0, "两个账号且未指定：不确定")
        try store.setMenuBar(id: b.id)
        accounts = SubscriptionService.accounts(store.load())
        XCTAssertEqual(accounts.filter(\.isActive).map(\.id), [SubscriptionService.accountID(b)])
        try store.remove(id: b.id)
        accounts = SubscriptionService.accounts(store.load())
        XCTAssertEqual(accounts.filter(\.isActive).map(\.id), [SubscriptionService.accountID(a)])
    }

    // ---------------------------------------------------------- 登录 ----

    func testDeviceCodeLoginPollsUntilAuthorized() throws {
        var polls = 0
        let fake = FakeTransport { request in
            switch request.url.absoluteString {
            case "https://github.com/login/device/code":
                return SubscriptionResponse(status: 200, json: ["device_code": "dc", "user_code": "ABCD-1234",
                                                                "verification_uri": "https://github.com/login/device", "interval": 1])
            case "https://github.com/login/oauth/access_token":
                polls += 1
                return polls < 3 ? SubscriptionResponse(status: 200, json: ["error": "authorization_pending"])
                    : SubscriptionResponse(status: 200, json: ["access_token": "gho_new"])
            default:
                XCTAssertEqual(request.url.absoluteString, "https://api.github.com/user")
                return SubscriptionResponse(status: 200, json: ["login": "octo", "id": 42])
            }
        }
        let flow = try SubscriptionAuth.start(.copilot, transport: fake.transport, sleep: { _ in })
        XCTAssertEqual(flow.prompt, .deviceCode(userCode: "ABCD-1234", url: URL(string: "https://github.com/login/device")!))
        let account = try flow.complete()
        XCTAssertEqual(account.token, "gho_new")
        XCTAssertEqual(account.label, "octo")
        XCTAssertEqual(account.accountID, "42")
        XCTAssertEqual(account.origin, .login)
        XCTAssertEqual(polls, 3)
    }

    func testLoginCanBeCancelledAndDeclined() throws {
        let pending = FakeTransport { request in
            request.url.path == "/oauth2/device/code"
                ? SubscriptionResponse(status: 200, json: ["device_code": "d", "user_code": "U",
                                                           "verification_uri_complete": "https://accounts.x.ai/device?code=U"])
                : SubscriptionResponse(status: 400, json: ["error": "authorization_pending"])
        }
        let flow = try SubscriptionAuth.start(.grok, transport: pending.transport, sleep: { _ in })
        var checks = 0
        XCTAssertThrowsError(try flow.complete { checks += 1; return checks > 3 }) {
            XCTAssertEqual($0 as? SubscriptionAuthError, .cancelled)
        }
        let denied = FakeTransport { request in
            request.url.path == "/oauth2/device/code"
                ? SubscriptionResponse(status: 200, json: ["device_code": "d", "user_code": "U",
                                                           "verification_uri": "https://accounts.x.ai/device"])
                : SubscriptionResponse(status: 400, json: ["error": "access_denied"])
        }
        XCTAssertThrowsError(try SubscriptionAuth.start(.grok, transport: denied.transport, sleep: { _ in }).complete()) {
            XCTAssertEqual($0 as? SubscriptionAuthError, .declined)
        }
    }

    func testPastedCodeLoginChecksStateAndUsesPKCE() throws {
        let fake = FakeTransport { request in
            XCTAssertEqual(request.url.absoluteString, "https://platform.claude.com/v1/oauth/token")
            let body = try! JSONSerialization.jsonObject(with: request.body ?? Data()) as! [String: Any]
            XCTAssertEqual(body["grant_type"] as? String, "authorization_code")
            XCTAssertEqual(body["code"] as? String, "the-code")
            XCTAssertNotNil(body["code_verifier"])
            return SubscriptionResponse(status: 200, json: ["access_token": "at", "refresh_token": "rt", "expires_in": 3600,
                                                            "account": ["uuid": "uuid-7", "email_address": "me@example.com"]])
        }
        let flow = try SubscriptionAuth.start(.claude, transport: fake.transport)
        guard case .pasteCode(let link) = flow.prompt else { return XCTFail("expected paste flow") }
        let query = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = try XCTUnwrap(query.first { $0.name == "state" }?.value)
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertThrowsError(try flow.complete(pastedCode: "the-code#wrong-state")) {
            XCTAssertEqual($0 as? SubscriptionAuthError, .invalidCode)
        }
        XCTAssertEqual(fake.count, 0, "state 不符时不提交授权码")
        let account = try flow.complete(pastedCode: "the-code#" + state)
        XCTAssertEqual(account.accountID, "uuid-7")
        XCTAssertEqual(account.label, "me@example.com")
        XCTAssertEqual(account.refreshToken, "rt")
    }

    func testBrowserLoginPollsWorkBuddyUntilReady() throws {
        var tokenPolls = 0
        let fake = FakeTransport { request in
            switch request.url.path {
            case "/v2/plugin/auth/state":
                return SubscriptionResponse(status: 200, json: ["code": 0, "data": ["state": "st", "authUrl": "https://copilot.tencent.com/login"]])
            case "/v2/plugin/auth/token":
                tokenPolls += 1
                return tokenPolls == 1 ? SubscriptionResponse(status: 200, json: ["code": 11217, "msg": "pending"])
                    : SubscriptionResponse(status: 200, json: ["code": 0, "data": ["accessToken": "wb-at", "refreshToken": "wb-rt", "expiresIn": 3600]])
            default:
                XCTAssertEqual(request.headers["Authorization"], "Bearer wb-at")
                return SubscriptionResponse(status: 200, json: ["code": 0, "data": ["uid": "uid-9", "nickname": "WB 用户"]])
            }
        }
        let flow = try SubscriptionAuth.start(.workbuddy, transport: fake.transport, sleep: { _ in })
        guard case .browser(let link) = flow.prompt else { return XCTFail("expected browser flow") }
        XCTAssertEqual(link.host, "copilot.tencent.com")
        let account = try flow.complete()
        XCTAssertEqual(account.token, "wb-at")
        XCTAssertEqual(account.extra["uid"], "uid-9")
        XCTAssertEqual(account.label, "WB 用户")
    }

    func testMenuBarBindsOnlyUnambiguousActiveAccount() {
        let one = SubscriptionCard(account: account(.claude, "a", kind: .oauth, active: true), snapshot: .init(status: .current))
        let two = SubscriptionCard(account: account(.claude, "b", kind: .oauth, active: true), snapshot: .init(status: .current))
        let other = SubscriptionCard(account: account(.claude, "c", kind: .oauth), snapshot: .init(status: .current))
        XCTAssertEqual(SubscriptionService.menuBarCard([one, other], provider: .claude)?.id, one.id)
        XCTAssertNil(SubscriptionService.menuBarCard([one, two], provider: .claude))
        XCTAssertNil(SubscriptionService.menuBarCard([other], provider: .claude), "不取其他账号替代")
    }

    func testSavedLoginExposesExpiryAndRenewalWithoutTokens() {
        let expiry = Date(timeIntervalSince1970: 1_797_828_739)
        let login = StoredSubscriptionAccount(provider: .workbuddy, label: "WB", kind: .oauth, origin: .login,
                                              token: "wb-access", refreshToken: "wb-refresh", expiresAt: expiry)
        let noRefresh = StoredSubscriptionAccount(provider: .zcode, kind: .oauth, origin: .login, token: "jwt")
        let key = StoredSubscriptionAccount(provider: .deepseek, kind: .apiKey, origin: .manual, token: "sk-xxxxxxxxxxxx")
        let accounts = SubscriptionService.accounts([login, noRefresh, key])
        let byProvider = Dictionary(uniqueKeysWithValues: accounts.map { ($0.provider, $0) })
        XCTAssertEqual(byProvider[.workbuddy]?.savedLogin, SubscriptionSavedLogin(expiresAt: expiry, autoRenews: true))
        XCTAssertEqual(byProvider[.zcode]?.savedLogin, SubscriptionSavedLogin(expiresAt: nil, autoRenews: false))
        XCTAssertNil(byProvider[.deepseek]?.savedLogin, "API Key 不是登录凭证")
    }

    func testDisplayGroupsMergeKeysOfSameBalanceAccountOnly() {
        func balance(_ total: Decimal, granted: Decimal = 0, currency: String = "CNY") -> SubscriptionSnapshot {
            SubscriptionSnapshot(status: .current, balances: [
                SubscriptionBalance(currency: currency, total: total, granted: granted, toppedUp: total - granted)])
        }
        let a = SubscriptionCard(account: account(.deepseek, "key-aaaaaaaaaaaa"), snapshot: balance(15.33))
        let rich = SubscriptionCard(account: account(.deepseek, "key-bbbbbbbbbbbb"), snapshot: balance(168.10))
        let b = SubscriptionCard(account: account(.deepseek, "key-cccccccccccc"), snapshot: balance(15.33))
        var staleC = balance(15.33); staleC.status = .stale
        let c = SubscriptionCard(account: account(.deepseek, "key-dddddddddddd"), snapshot: staleC)
        let zero1 = SubscriptionCard(account: account(.deepseek, "key-zero-111111"), snapshot: balance(0))
        let zero2 = SubscriptionCard(account: account(.deepseek, "key-zero-222222"), snapshot: balance(0))
        let failed = SubscriptionCard(account: account(.deepseek, "key-failed-1111"), snapshot: .init(status: .failed))
        let otherProvider = SubscriptionCard(account: account(.minimax, "key-eeeeeeeeeeee"), snapshot: balance(15.33))
        let differentGrant = SubscriptionCard(account: account(.deepseek, "key-ffffffffffff"),
                                              snapshot: balance(15.33, granted: 1))
        let oauth = SubscriptionCard(account: account(.kimi, "oauth-1", kind: .oauth), snapshot: balance(15.33))
        let oauth2 = SubscriptionCard(account: account(.kimi, "oauth-2", kind: .oauth), snapshot: balance(15.33))

        let groups = SubscriptionCardGroup.group([a, rich, b, c, zero1, zero2, failed, otherProvider,
                                                  differentGrant, oauth, oauth2])
        XCTAssertEqual(groups.map { $0.cards.map(\.id) }, [
            [a.id, b.id, c.id], [rich.id], [zero1.id], [zero2.id], [failed.id], [otherProvider.id],
            [differentGrant.id], [oauth.id], [oauth2.id],
        ])
        XCTAssertTrue(groups[0].isMerged)
        XCTAssertTrue(groups[0].contains(c.id))
        XCTAssertEqual(groups[0].id, a.id)
    }

    func testCardOrderIsStable() {
        let cards = [
            SubscriptionCard(account: account(.deepseek, "x"), snapshot: .init(status: .current)),
            SubscriptionCard(account: account(.claude, "y", kind: .oauth), snapshot: .init(status: .failed)),
            SubscriptionCard(account: account(.claude, "z", kind: .oauth, active: true), snapshot: .init(status: .loading)),
        ]
        let ordered = SubscriptionService.mergeByAccount(cards)
        XCTAssertEqual(ordered.map(\.account.provider), [.claude, .claude, .deepseek])
        XCTAssertTrue(ordered[0].account.isActive)
    }

    // ---------------------------------------------------- Antigravity ----

    func testAntigravityLocalKeychainGoKeyringAndAppStorageFallback() throws {
        let appSupport = home.appendingPathComponent("Library/Application Support/Antigravity")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "jetski.onboarding.lastLoginUsername": "fallback@example.com",
        ]).write(to: appSupport.appendingPathComponent("app_storage.json"))

        let payload: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer-abc-123",
            "id_token_email": "ag.user@example.com",
            "token": [
                "access_token": "ya29.fixture-access-token-value",
                "refresh_token": "1//fixture-refresh-token",
                "expiry": "2026-11-22T00:59:44.902906+07:00",
                "token_type": "Bearer",
            ],
        ]
        let b64 = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
        let reader = AntigravityLocalCredentials(home: home.path, keychainRead: { "go-keyring-base64:" + b64 })
        let accounts = reader.discover()
        XCTAssertEqual(accounts.count, 1)
        let ag = try XCTUnwrap(accounts.first)
        XCTAssertEqual(ag.provider, .antigravity)
        XCTAssertEqual(ag.label, "ag.user@example.com")
        XCTAssertEqual(ag.credential?.token, "ya29.fixture-access-token-value")
        XCTAssertNotNil(ag.credential?.expiresAt, "带微秒与时区偏移的 ISO8601 过期时间应正确解析")
        XCTAssertTrue(ag.isActive)
        XCTAssertTrue(ag.isAutoDiscovered)
        XCTAssertEqual(ag.sources.first, SubscriptionSource(tool: "Antigravity", location: "钥匙串"))

        // 缺少 id_token_email 时回退读取 app_storage.json 的用户名。
        var noEmail = payload
        noEmail.removeValue(forKey: "id_token_email")
        let b64NoEmail = try JSONSerialization.data(withJSONObject: noEmail).base64EncodedString()
        let fallbackReader = AntigravityLocalCredentials(home: home.path, keychainRead: { "go-keyring-base64:" + b64NoEmail })
        XCTAssertEqual(fallbackReader.discover().first?.label, "fallback@example.com")
    }

    func testAntigravityLocalStateVSCDBProtobufAndAuthStatus() throws {
        func protoVarint(_ value: UInt64) -> [UInt8] {
            var v = value
            var out: [UInt8] = []
            while true {
                var byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { byte |= 0x80 }
                out.append(byte)
                if v == 0 { break }
            }
            return out
        }
        func protoBytes(field: UInt64, _ data: [UInt8]) -> [UInt8] {
            protoVarint((field << 3) | 2) + protoVarint(UInt64(data.count)) + data
        }
        func protoString(field: UInt64, _ text: String) -> [UInt8] {
            protoBytes(field: field, Array(text.utf8))
        }

        // 构造嵌套 base64 protobuf（模拟 antigravityUnifiedStateSync.oauthToken 结构）。
        let innerProto = protoString(field: 1, "ya29.vscdb-fixture-token-1234567890")
            + protoString(field: 2, "1//vscdb-refresh-fixture")
            + protoVarint((3 << 3) | 0) + protoVarint(1_900_000_000)
        let innerB64 = Data(innerProto).base64EncodedString()
        let outerProto = protoString(field: 1, "oauthTokenInfoSentinelKey") + protoString(field: 2, innerB64)
        let outerB64 = Data(outerProto).base64EncodedString()

        let vscdbDir = home.appendingPathComponent("Library/Application Support/Antigravity IDE/User/globalStorage")
        try FileManager.default.createDirectory(at: vscdbDir, withIntermediateDirectories: true)
        let dbPath = vscdbDir.appendingPathComponent("state.vscdb").path
        let conn = try SQLiteConnection(path: dbPath)
        try conn.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        try conn.execute("INSERT INTO ItemTable VALUES (?, ?)", [
            "antigravityAuthStatus",
            #"{"email":"ide.user@example.com"}"#,
        ])
        try conn.execute("INSERT INTO ItemTable VALUES (?, ?)", [
            "antigravityUnifiedStateSync.oauthToken",
            outerB64,
        ])

        let reader = AntigravityLocalCredentials(home: home.path, keychainRead: { nil })
        let accounts = reader.discover()
        XCTAssertEqual(accounts.count, 1)
        let ag = try XCTUnwrap(accounts.first)
        XCTAssertEqual(ag.provider, .antigravity)
        XCTAssertEqual(ag.label, "ide.user@example.com")
        XCTAssertEqual(ag.credential?.token, "ya29.vscdb-fixture-token-1234567890")
        XCTAssertEqual(ag.credential?.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertTrue(ag.isAutoDiscovered)
        XCTAssertEqual(ag.sources.first?.tool, "Antigravity IDE")
    }

    func testAntigravityQuotaPoolingFallbackAndHostGuard() {
        let fake = FakeTransport { request in
            XCTAssertEqual(request.url.host, "daily-cloudcode-pa.googleapis.com")
            XCTAssertTrue(request.headers["User-Agent"]?.hasPrefix("antigravity/hub/") == true)
            switch request.url.path {
            case "/v1internal:loadCodeAssist":
                return SubscriptionResponse(status: 200, json: [
                    "cloudaicompanionProject": "managed-proj-fixture",
                    "paidTier": ["name": "Google AI Pro"],
                    "currentTier": ["name": "Antigravity"],
                ])
            case "/v1internal:retrieveUserQuota":
                return SubscriptionResponse(status: 200, json: [
                    "buckets": [
                        ["modelId": "claude-opus-5-5-high", "remainingFraction": 0, "resetTime": "2026-11-21T18:58:26Z"],
                        ["modelId": "claude-sonnet-5-5-low", "remainingFraction": 0, "resetTime": "2026-11-21T18:58:26Z"],
                        ["modelId": "gpt-oss-120b-medium", "remainingFraction": 0, "resetTime": "2026-11-21T18:58:26Z"],
                        ["modelId": "gemini-3.8-flash-high", "remainingFraction": 0.04, "resetTime": "2026-11-21T19:30:20Z"],
                        ["modelId": "gemini-4-neon-xhigh", "remainingFraction": 0.04, "resetTime": "2026-11-21T19:30:20Z"],
                        ["modelId": "gemini-4-argon-high", "remainingFraction": 1, "resetTime": "2026-11-28T17:23:15Z"],
                        ["modelId": "gemini-4-argon-low", "remainingFraction": 1, "resetTime": "2026-11-28T17:23:15Z"],
                        ["modelId": "tab_flash_lite_preview", "remainingFraction": 1],
                    ],
                ])
            default:
                return SubscriptionResponse(status: 404)
            }
        }
        let snapshot = SubscriptionAdapters.fetch(account(.antigravity, "ya29.tok", kind: .oauth, active: true), ctx(fake))
        XCTAssertEqual(snapshot.status, .current)
        XCTAssertEqual(snapshot.plan, "Google AI Pro")
        XCTAssertTrue(snapshot.privateAPI)
        XCTAssertEqual(snapshot.windows.map(\.name), ["Gemini", "Gemini 4 Argon", "Claude / GPT"])
        XCTAssertEqual(snapshot.windows[0].usedPercent ?? -1, 96, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[1].usedPercent ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[2].usedPercent ?? -1, 100, accuracy: 0.01)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertNil(snapshot.windows[0].duration)

        // 回退路径：retrieveUserQuota 返回 404 时改用 fetchAvailableModels，缺失 remainingFraction 视为已用尽。
        let fallbackFake = FakeTransport { request in
            switch request.url.path {
            case "/v1internal:loadCodeAssist":
                return SubscriptionResponse(status: 200, json: ["cloudaicompanionProject": "proj", "paidTier": ["name": "Pro"]])
            case "/v1internal:retrieveUserQuota":
                return SubscriptionResponse(status: 404)
            case "/v1internal:fetchAvailableModels":
                return SubscriptionResponse(status: 200, json: [
                    "models": [
                        "gemini-3-flash": ["quotaInfo": ["remainingFraction": 0.25, "resetTime": "2026-11-21T20:00:00Z"]],
                        "claude-opus-5-5-high": ["quotaInfo": ["resetTime": "2026-11-21T19:00:00Z"]],
                    ],
                ])
            default:
                return SubscriptionResponse(status: 500)
            }
        }
        let fallback = SubscriptionAdapters.fetch(account(.antigravity, "ya29.tok", kind: .oauth), ctx(fallbackFake))
        XCTAssertEqual(fallback.status, .current)
        XCTAssertEqual(fallback.windows.map(\.name), ["Gemini", "Claude"])
        XCTAssertEqual(fallback.windows[0].usedPercent ?? -1, 75, accuracy: 0.01)
        XCTAssertEqual(fallback.windows[1].usedPercent ?? -1, 100, accuracy: 0.01)

        // 非登记域名（含 cloudcode-pa.googleapis.com）不得携带 Antigravity 凭据。
        XCTAssertEqual(
            SubscriptionAdapters.send(.antigravity,
                                      SubscriptionRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!),
                                      ctx(fake)).failure,
            .blocked)
    }

    func testAntigravityQuotaSummaryFourWindowsAndEdgeCases() {
        let fake = FakeTransport { request in
            XCTAssertEqual(request.url.host, "daily-cloudcode-pa.googleapis.com")
            switch request.url.path {
            case "/v1internal:loadCodeAssist":
                return SubscriptionResponse(status: 200, json: [
                    "cloudaicompanionProject": "managed-proj-fixture",
                    "paidTier": ["name": "Google AI Pro"],
                ])
            case "/v1internal:retrieveUserQuotaSummary":
                return SubscriptionResponse(status: 200, json: [
                    "groups": [
                        [
                            "displayName": "Gemini Models",
                            "buckets": [
                                [
                                    "bucketId": "gemini-weekly",
                                    "displayName": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "resetTime": "2026-12-05T10:56:46Z",
                                    "remainingFraction": 0.85,
                                ],
                                [
                                    "bucketId": "gemini-5h",
                                    "displayName": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "resetTime": "2026-11-28T15:56:46Z",
                                    "remainingFraction": 0.46,
                                ],
                            ],
                        ],
                        [
                            "displayName": "Claude and GPT models",
                            "buckets": [
                                [
                                    "bucketId": "3p-weekly",
                                    "displayName": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "remainingFraction": 1,
                                ],
                                [
                                    "bucketId": "3p-5h",
                                    "displayName": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "remainingFraction": 1,
                                ],
                            ],
                        ],
                    ],
                ])
            default:
                XCTFail("retrieveUserQuotaSummary 成功后不应继续请求回退接口: \(request.url.path)")
                return SubscriptionResponse(status: 404)
            }
        }

        let snapshot = SubscriptionAdapters.fetch(account(.antigravity, "ya29.tok", kind: .oauth, active: true), ctx(fake))
        XCTAssertEqual(snapshot.status, .current)
        XCTAssertEqual(snapshot.plan, "Google AI Pro")
        XCTAssertTrue(snapshot.privateAPI)
        XCTAssertEqual(fake.count, 2)
        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(snapshot.windows.map(\.name), ["Gemini", "Gemini", "Claude / GPT", "Claude / GPT"])
        XCTAssertEqual(snapshot.windows.map(\.duration), [18_000, 604_800, 18_000, 604_800])
        XCTAssertEqual(snapshot.windows[0].usedPercent ?? -1, 54, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[1].usedPercent ?? -1, 15, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[2].usedPercent ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[3].usedPercent ?? -1, 0, accuracy: 0.01)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertNotNil(snapshot.windows[1].resetsAt)
        XCTAssertNil(snapshot.windows[2].resetsAt)
        XCTAssertNil(snapshot.windows[3].resetsAt)

        // 边界：跳过 disabled 桶、耗尽省略 remainingFraction 时按 100% 已用计、支持顶层 buckets 与未知分组名。
        let edgeWindows = SubscriptionAdapters.antigravityQuotaSummaryWindows([
            "groups": [
                [
                    "displayName": "Image Models",
                    "buckets": [
                        ["bucketId": "img-daily", "window": "daily", "resetTime": "2026-12-01T00:00:00Z"],
                        ["bucketId": "img-off", "window": "weekly", "remainingFraction": 0.5, "disabled": true],
                        ["bucketId": "img-missing", "window": "5h"],
                    ],
                ],
            ],
        ])
        XCTAssertEqual(edgeWindows.map(\.id), ["img-daily"])
        XCTAssertEqual(edgeWindows[0].name, "Image Models")
        XCTAssertEqual(edgeWindows[0].duration, 86_400)
        XCTAssertEqual(edgeWindows[0].usedPercent ?? -1, 100, accuracy: 0.01)

        let flatWindows = SubscriptionAdapters.antigravityQuotaSummaryWindows([
            "buckets": [
                ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.8],
                ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.4],
                ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.9],
            ],
        ])
        XCTAssertEqual(flatWindows.map(\.id), ["gemini-5h", "gemini-weekly", "3p-5h"])
        XCTAssertEqual(flatWindows.map(\.name), ["Gemini", "Gemini", "Claude / GPT"])

        // 429 / 401 短路返回，不再继续触发回退接口。
        let rateLimited = FakeTransport { request in
            if request.url.path == "/v1internal:loadCodeAssist" {
                return SubscriptionResponse(status: 200, json: ["cloudaicompanionProject": "p"])
            }
            if request.url.path == "/v1internal:retrieveUserQuotaSummary" {
                return SubscriptionResponse(status: 429, retryAfter: 60)
            }
            XCTFail("限流后不应回退请求: \(request.url.path)")
            return SubscriptionResponse(status: 200)
        }
        let limited = SubscriptionAdapters.fetch(account(.antigravity, "ya29.tok", kind: .oauth), ctx(rateLimited))
        XCTAssertEqual(limited.status, .failed)
        XCTAssertEqual(limited.problem, .rateLimited)
        XCTAssertEqual(rateLimited.count, 2)
    }

    func testAutoDiscoveredAntigravityRecoversWhenLocalTokenRefreshes() throws {
        let clock = Clock()
        final class TokenBox: @unchecked Sendable {
            let lock = NSLock()
            var token = "ya29.expired-token"
            var expiresAt = Date(timeIntervalSince1970: 1_799_999_000)
        }
        let box = TokenBox()
        let fake = FakeTransport { request in
            switch request.url.path {
            case "/v1internal:loadCodeAssist":
                return SubscriptionResponse(status: 200, json: ["cloudaicompanionProject": "proj", "paidTier": ["name": "Pro"]])
            case "/v1internal:retrieveUserQuota":
                return SubscriptionResponse(status: 200, json: [
                    "buckets": [["modelId": "gemini-3-flash", "remainingFraction": 0.6, "resetTime": "2026-11-21T20:00:00Z"]],
                ])
            default:
                return SubscriptionResponse(status: 404)
            }
        }
        let s = SubscriptionService(store: store, transport: fake.transport, cachePath: nil, clock: { clock.now }) {
            box.lock.lock(); let tok = box.token; let exp = box.expiresAt; box.lock.unlock()
            var acc = SubscriptionAccount(
                provider: .antigravity, label: "me@example.com",
                source: SubscriptionSource(tool: "Antigravity", location: "钥匙串"),
                isActive: true, isAutoDiscovered: true,
                credential: SubscriptionCredential(kind: .oauth, token: tok, expiresAt: exp),
                providerAccountID: "writer-1")
            acc.id = "antigravity:local-fixture"
            return [acc]
        }
        s.discover()
        s.refresh()
        XCTAssertEqual(s.cards().first?.snapshot.status, .expired)
        XCTAssertEqual(fake.count, 0, "过期令牌不发请求")

        // Antigravity 在本地续期新令牌后，下一次 60s 发现与刷新应立即恢复，不等 5 分钟 TTL。
        box.lock.lock()
        box.token = "ya29.fresh-token"
        box.expiresAt = clock.now.addingTimeInterval(3600)
        box.lock.unlock()
        clock.now += 30
        XCTAssertTrue(s.discover())
        s.refresh()
        XCTAssertEqual(s.cards().first?.snapshot.status, .current)
        XCTAssertEqual(s.cards().first?.snapshot.windows.first?.usedPercent ?? -1, 40, accuracy: 0.01)
    }

    func testAutoDiscoveredAntigravityRefreshesInMemoryWithRefreshToken() throws {
        let clock = Clock()
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var oauthCalls = 0
            var quotaCalls = 0
            var rejectOAuth = false
        }
        let counter = Counter()
        let fake = FakeTransport { request in
            if request.url.host == "oauth2.googleapis.com" {
                counter.lock.lock()
                counter.oauthCalls += 1
                let reject = counter.rejectOAuth
                counter.lock.unlock()
                let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("refresh_token=1%2F%2Ffixture-refresh-token"))
                if reject {
                    return SubscriptionResponse(status: 400, json: ["error": "invalid_grant"])
                }
                return SubscriptionResponse(status: 200, json: [
                    "access_token": "ya29.ephemeral-refreshed",
                    "expires_in": 3600,
                    "token_type": "Bearer",
                ])
            }
            XCTAssertEqual(request.url.host, "daily-cloudcode-pa.googleapis.com")
            XCTAssertEqual(request.headers["Authorization"], "Bearer ya29.ephemeral-refreshed")
            switch request.url.path {
            case "/v1internal:loadCodeAssist":
                return SubscriptionResponse(status: 200, json: ["cloudaicompanionProject": "proj", "paidTier": ["name": "Google AI Pro"]])
            case "/v1internal:retrieveUserQuota":
                counter.lock.lock(); counter.quotaCalls += 1; counter.lock.unlock()
                return SubscriptionResponse(status: 200, json: [
                    "buckets": [["modelId": "gemini-3-flash", "remainingFraction": 0.7, "resetTime": "2026-11-21T20:00:00Z"]],
                ])
            default:
                return SubscriptionResponse(status: 404)
            }
        }

        let s = SubscriptionService(store: store, transport: fake.transport, cachePath: nil, clock: { clock.now }) {
            var acc = SubscriptionAccount(
                provider: .antigravity, label: "me@example.com",
                source: SubscriptionSource(tool: "Antigravity", location: "钥匙串"),
                isActive: true, isAutoDiscovered: true,
                credential: SubscriptionCredential(
                    kind: .oauth,
                    token: "ya29.expired-keychain-token",
                    expiresAt: Date(timeIntervalSince1970: 1_799_999_000),
                    refreshToken: "1//fixture-refresh-token"),
                providerAccountID: "writer-1")
            acc.id = "antigravity:local-fixture"
            return [acc]
        }

        // 1. 钥匙串 access_token 已过期，但存在 refresh_token：自动在内存中换取访问令牌并查询成功，且不写入账号库。
        s.discover()
        s.refresh()
        XCTAssertEqual(s.cards().first?.snapshot.status, .current)
        XCTAssertEqual(s.cards().first?.snapshot.plan, "Google AI Pro")
        XCTAssertEqual(s.cards().first?.snapshot.windows.first?.usedPercent ?? -1, 30, accuracy: 0.01)
        XCTAssertEqual(counter.oauthCalls, 1)
        XCTAssertEqual(counter.quotaCalls, 1)
        XCTAssertTrue(store.load().isEmpty, "只读本机凭据换取的短期令牌不得写入账号库")

        // 2. 5 分钟后再次刷新：直接复用内存中尚在有效期内的短期访问令牌，不重复请求 oauth2.googleapis.com。
        clock.now += 6 * 60
        s.refresh()
        XCTAssertEqual(s.cards().first?.snapshot.status, .current)
        XCTAssertEqual(counter.oauthCalls, 1)
        XCTAssertEqual(counter.quotaCalls, 2)

        // 3. 1 小时后短期令牌过期且远端吊销 refresh_token：上报 unauthorized（stale 保留上次快照并标注失效）。
        counter.lock.lock(); counter.rejectOAuth = true; counter.lock.unlock()
        clock.now += 60 * 60
        s.refresh()
        XCTAssertEqual(counter.oauthCalls, 2)
        XCTAssertEqual(s.cards().first?.snapshot.status, .stale)
        XCTAssertEqual(s.cards().first?.snapshot.problem, .unauthorized)
    }
}
