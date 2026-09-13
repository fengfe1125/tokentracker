//
//  CodexAccountSwitcherTests.swift
//  TokenTrackerCoreTests
//
//  切换核心：captureCurrent 存快照、switchTo 的「回采 before 覆盖」正确性
//  （Codex CLI 运行中轮换 refresh_token，切走前不回采＝用旧令牌盖新令牌→登出）、
//  authPath 走 CODEX_HOME、写回 0600、异常路径。全程临时目录，不触网。
//

import XCTest
@testable import TokenTrackerCore

final class CodexAccountSwitcherTests: XCTestCase {
    private var tmp: TempDir!
    private var ctx: BillingContext!
    private var switcher: CodexAccountSwitcher!
    private var authPath: String!

    override func setUp() async throws {
        tmp = try TempDir()
        // CODEX_HOME 指向 tmp/.codex；账号库默认落 tmp/.tokentracker（由 ctx.home 派生）
        let http: BillingHTTP = { _, _, _, _ in (0, [:]) }   // 切换不触网
        ctx = BillingContext(home: tmp.url.path,
                             env: ["CODEX_HOME": tmp.path(".codex")],
                             http: http)
        switcher = CodexAccountSwitcher(ctx: ctx)
        authPath = tmp.path(".codex", "auth.json")
    }

    override func tearDown() async throws {
        tmp = nil; ctx = nil; switcher = nil; authPath = nil
    }

    // ------------------------------------------------------------ fixtures ----

    /// 造一份 auth.json bundle（OAuth 模式，OPENAI_API_KEY 为 null）。
    private func bundle(accountID: String, refreshToken: String,
                        accessToken: String = "acc", idToken: String? = nil) -> [String: Any] {
        var tokens: [String: Any] = ["account_id": accountID,
                                     "access_token": accessToken,
                                     "refresh_token": refreshToken]
        if let idToken { tokens["id_token"] = idToken }
        return ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
                "tokens": tokens, "last_refresh": "2026-01-01T00:00:00Z"]
    }

    private func writeLiveAuth(_ bundle: [String: Any]) {
        atomicWriteJSON(authPath, bundle)
    }

    private func liveRefreshToken() -> String? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any] else { return nil }
        return tokens["refresh_token"] as? String
    }

    private func storedRefreshToken(_ id: String) -> String? {
        guard let acc = switcher.store.get(id),
              let tokens = acc.bundle["tokens"] as? [String: Any] else { return nil }
        return tokens["refresh_token"] as? String
    }

    private static func b64url(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func fakeJWT(email: String) -> String {
        let header = b64url("{\"alg\":\"RS256\",\"typ\":\"JWT\"}")
        let payload = b64url("{\"email\":\"\(email)\",\"sub\":\"user-1\"}")
        return "\(header).\(payload).sig-not-checked"
    }

    // ------------------------------------------------------------ authPath ----

    func testAuthPathFollowsCodexHome() throws {
        XCTAssertEqual(switcher.authPath, authPath)
    }

    func testActiveAccountIDNilWhenNoFile() throws {
        XCTAssertNil(switcher.activeAccountID())
    }

    // ------------------------------------------------------------ capture ----

    func testCaptureCurrentStoresWholeSnapshot() throws {
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1"))
        let captured = try switcher.captureCurrent(name: "甲")
        XCTAssertEqual(captured.id, "acct-A")
        XCTAssertEqual(captured.name, "甲")
        XCTAssertEqual(switcher.store.load().count, 1)
        XCTAssertEqual(switcher.activeAccountID(), "acct-A")
        // 整份 bundle 存下：auth_mode / OPENAI_API_KEY 不丢
        let stored = switcher.store.get("acct-A")
        XCTAssertEqual(stored?.bundle["auth_mode"] as? String, "chatgpt")
        XCTAssertNotNil(stored?.bundle["OPENAI_API_KEY"])
        XCTAssertEqual(storedRefreshToken("acct-A"), "R1")
    }

    func testCaptureCurrentWithoutLiveThrows() throws {
        XCTAssertThrowsError(try switcher.captureCurrent(name: "x")) { error in
            guard case CodexAccountError.noLiveCredentials = error else {
                return XCTFail("expected noLiveCredentials, got \(error)")
            }
        }
    }

    /// 空备注名 → 用 JWT 里的 email 兜底命名，并展示 email。
    func testCaptureCurrentParsesEmailFromIDToken() throws {
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1",
                             idToken: Self.fakeJWT(email: "alice@example.com")))
        let captured = try switcher.captureCurrent(name: "")
        XCTAssertEqual(captured.email, "alice@example.com")
        XCTAssertEqual(captured.name, "alice@example.com")
    }

    // ------------------------------------------------------------ switch ----

    func testSwitchToUnknownThrows() throws {
        XCTAssertThrowsError(try switcher.switchTo("ghost")) { error in
            guard case CodexAccountError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    /// ★核心：回采 before 覆盖 —— 切走时把 live 的（已轮换的）refresh_token 存回旧账号。
    func testSwitchRecapturesRotatedTokenBeforeOverwrite() throws {
        // 1) 登录 A(R1) → 存 A
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1"))
        try switcher.captureCurrent(name: "甲")
        // 2) 登录 B(Rb) → 存 B
        writeLiveAuth(bundle(accountID: "acct-B", refreshToken: "Rb"))
        try switcher.captureCurrent(name: "乙")
        XCTAssertEqual(switcher.store.load().count, 2)
        // 3) 回到 A，Codex CLI 把 A 的 refresh_token 轮换成 R1'
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1-rotated"))

        try switcher.switchTo("acct-B")

        // 关键：账号库里 A 已是轮换后的 R1'（不是陈旧 R1）——否则下次切回 A 会登出
        XCTAssertEqual(storedRefreshToken("acct-A"), "R1-rotated")
        // live auth.json 变成 B，且是 B 被捕获时的 Rb
        XCTAssertEqual(switcher.activeAccountID(), "acct-B")
        XCTAssertEqual(liveRefreshToken(), "Rb")
        XCTAssertNotNil(switcher.store.get("acct-B")?.lastUsedAt)
    }

    /// 再切回 A：写回应是回采到的最新 A bundle（R1'），而非最初捕获的 R1。
    func testSwitchBackWritesRecapturedBundle() throws {
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1"))
        try switcher.captureCurrent(name: "甲")
        writeLiveAuth(bundle(accountID: "acct-B", refreshToken: "Rb"))
        try switcher.captureCurrent(name: "乙")
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1-rotated"))
        try switcher.switchTo("acct-B")     // 回采 A=R1'，写 B

        try switcher.switchTo("acct-A")     // 回采 B，写 A

        XCTAssertEqual(switcher.activeAccountID(), "acct-A")
        XCTAssertEqual(liveRefreshToken(), "R1-rotated")   // 回采链路生效
    }

    /// 切到当前已生效的账号：不回采自身，bundle 原样保持（幂等）。
    func testSwitchSameAccountIsIdempotent() throws {
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1"))
        try switcher.captureCurrent(name: "甲")
        try switcher.switchTo("acct-A")
        XCTAssertEqual(switcher.activeAccountID(), "acct-A")
        XCTAssertEqual(liveRefreshToken(), "R1")
    }

    func testSwitchWritesAuthWith0600() throws {
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1"))
        try switcher.captureCurrent(name: "甲")
        writeLiveAuth(bundle(accountID: "acct-B", refreshToken: "Rb"))
        try switcher.captureCurrent(name: "乙")
        writeLiveAuth(bundle(accountID: "acct-A", refreshToken: "R1"))
        try switcher.switchTo("acct-B")
        let attrs = try FileManager.default.attributesOfItem(atPath: authPath)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
    }
}
