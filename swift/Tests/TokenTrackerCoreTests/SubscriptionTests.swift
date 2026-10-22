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
}
