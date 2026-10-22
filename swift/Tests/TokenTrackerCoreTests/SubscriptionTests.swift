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

    private func service(_ fake: FakeTransport, clock: Clock, env: [String: String] = [:],
                         cachePath: String? = nil) -> SubscriptionService {
        SubscriptionService(discovery: discovery(env: env), transport: fake.transport, cachePath: cachePath,
                            clock: { clock.now })
    }

    private let goOK = SubscriptionResponse(status: 200, json: ["usage": ["rolling": ["percent": 25]]])

    func testCachesFiveMinutesAndInvalidatesOnLoginChange() throws {
        let clock = Clock()
        let fake = FakeTransport { [goOK] _ in goOK }
        try write(".local/share/opencode/auth.json", ["opencode-go": ["type": "api", "key": "go-1"]])
        let s = service(fake, clock: clock)
        s.discover()
        XCTAssertEqual(s.cards().first?.snapshot.status, .loading)
        s.refresh()
        XCTAssertEqual(fake.count, 1)
        clock.now += 60
        s.refresh()
        XCTAssertEqual(fake.count, 1, "5 分钟内使用缓存")
        // 登录态变化：立即失效并重新查询。
        try write(".local/share/opencode/auth.json", ["opencode-go": ["type": "api", "key": "go-2"]])
        XCTAssertTrue(s.discover())
        XCTAssertEqual(s.cards().first?.snapshot.status, .loading)
        s.refresh()
        XCTAssertEqual(fake.count, 2)
        XCTAssertEqual(fake.requests.last?.headers["Authorization"], "Bearer go-2")
        clock.now += 301
        s.refresh()
        XCTAssertEqual(fake.count, 3)
    }

    func testStaleWithin24HoursThenStatusOnly() throws {
        let clock = Clock()
        var fail = false
        let goOK = self.goOK
        let fake = FakeTransport { _ in fail ? SubscriptionResponse(status: 0, failure: .network) : goOK }
        try write(".local/share/opencode/auth.json", ["opencode-go": ["type": "api", "key": "go-1"]])
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
        // 重启后仍可展示过期结果；缓存不含凭据。
        let text = try String(contentsOfFile: cache, encoding: .utf8)
        XCTAssertFalse(text.contains("go-1"))
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
        try write(".local/share/opencode/auth.json", ["opencode-go": ["type": "api", "key": "go-1"]])
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
        let clock = Clock()
        // 9 把不同的 DeepSeek Key（Magpie providers.json）。
        try write(".config/magpie/providers.json", ["providers": (0..<9).map { ["id": "deepseek", "key": "sk-\($0)"] }])
        let fake = FakeTransport { request in
            request.headers["Authorization"] == "Bearer sk-3"
                ? SubscriptionResponse(status: 500)
                : SubscriptionResponse(status: 200, json: ["balance_infos": [["currency": "CNY", "total_balance": "1.00"]]])
        }
        fake.delay = 0.05
        let s = service(fake, clock: clock)
        s.discover()
        s.refresh()
        XCTAssertEqual(fake.count, 9)
        XCTAssertLessThanOrEqual(fake.maxActive, SubscriptionService.maxConcurrentRequests)
        let cards = s.cards()
        XCTAssertEqual(cards.count, 9)
        XCTAssertEqual(cards.filter { $0.snapshot.status == .current }.count, 8)
        XCTAssertEqual(cards.filter { $0.snapshot.status == .failed }.count, 1)
    }

    func testQueriedAccountIDMergesCardsAcrossSources() throws {
        let clock = Clock()
        try write(".config/magpie/logins.json", [["agent": "claude", "user": "me@example.com",
            "auth": ["claudeAiOauth": ["accessToken": "magpie-token"]], "profile": ["accountUuid": "uuid-9"]]])
        let fake = FakeTransport { request in
            if request.url.path.hasSuffix("/profile") {
                return SubscriptionResponse(status: 200, json: ["account": ["uuid": "uuid-9"]])
            }
            return SubscriptionResponse(status: 200, json: ["five_hour": ["utilization": 10]])
        }
        let s = SubscriptionService(discovery: discovery(keychain: ["claudeAiOauth": ["accessToken": "keychain-token"]]),
                                    transport: fake.transport, cachePath: nil, clock: { clock.now })
        s.discover()
        XCTAssertEqual(s.cards().count, 2, "查询前没有可靠 ID，不合并")
        s.refresh()
        let cards = s.cards()
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].account.isActive)
        XCTAssertEqual(cards[0].account.label, "me@example.com")
        XCTAssertEqual(Set(cards[0].account.sources.map(\.tool)), ["Claude Code", "Magpie"])
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
