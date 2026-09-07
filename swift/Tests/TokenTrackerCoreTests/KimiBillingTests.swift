//
//  KimiBillingTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_billing.py 的 KimiReadOnlyTest / KimiSelfRefreshTest。
//

import XCTest
@testable import TokenTrackerCore

final class KimiBillingPortTests: XCTestCase {
    private var tmp: TempDir!
    private var credDir: String!
    private var credPath: String!
    private var clockBox: StateBox<Double>!
    private var ctx: BillingContext!
    private var httpCalls: [String] = []
    private var httpImpl: BillingHTTP!

    private let now = 1_000_000.0

    override func setUp() async throws {
        tmp = try TempDir()
        credDir = tmp.path(".kimi-code", "credentials")
        try FileManager.default.createDirectory(atPath: credDir, withIntermediateDirectories: true)
        credPath = credDir + "/kimi-code.json"
        clockBox = StateBox(now)
        httpCalls = []
        let clock: () -> Double = { [clockBox] in clockBox!.value }
        // 默认 200 + 周期配额（remaining 55 / limit 100 → 45%）
        let calls = StateBox<[String]>([])
        let http: BillingHTTP = { url, headers, body, method in
            calls.value.append(url)
            return (200, ["usage": ["limit": 100, "remaining": 55]])
        }
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: clock, http: http)
        _ = calls
    }

    override func tearDown() async throws {
        tmp = nil; ctx = nil; httpImpl = nil
    }

    private func writeCredentials(_ overrides: [String: Any] = [:]) throws {
        var data: [String: Any] = ["access_token": "fake-access", "expires_at": now + 900]
        for (k, v) in overrides { data[k] = v }
        let json = try JSONSerialization.data(withJSONObject: data)
        try json.write(to: URL(fileURLWithPath: credPath))
    }

    private var usage: [String: Any] { KimiBilling(ctx: ctx).usage() }

    // ---------------------------------------------------------- 只读路径 ----

    /// test_valid_access_without_refresh_token_is_used_without_writes
    func testValidAccessWithoutRefreshTokenIsUsedWithoutWrites() throws {
        try writeCredentials()
        let before = try Data(contentsOf: URL(fileURLWithPath: credPath))
        let result = usage
        let windows = result["windows"] as? [String: Any]
        let w7d = windows?["7d"] as? [String: Any]
        XCTAssertEqual((w7d?["pct"] as? NSNumber)?.doubleValue ?? -1, 45, accuracy: 1e-9)
        // 凭据未被改写
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: credPath)), before)
    }

    /// test_invalid_or_expired_credentials_without_refresh_token_never_request_or_write
    func testInvalidOrExpiredCredentialsNeverRequest() throws {
        var httpUsed = false
        let http: BillingHTTP = { _, _, _, _ in httpUsed = true; return (200, [:]) }
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: { self.clockBox.value }, http: http)
        let cases: [(content: String?, expected: String)] = [
            (nil, "no_credentials"), ("", "parse"), ("{broken", "parse"),
            ("[]", "parse"), ("null", "parse"),
            (#"{"access_token":123}"#, "parse"),
            (#"{"access_token":" "}"#, "no_token"),
            (#"{"access_token":"","refresh_token":"fake-refresh"}"#, "no_token"),
            (#"{"access_token":"fake","expires_at":999999}"#, "expired"),
            (#"{"access_token":"fake","expires_at":"bad"}"#, "parse"),
            (#"{"access_token":"fake","expires_at":1e999}"#, "parse"),
        ]
        for (content, expected) in cases {
            try? FileManager.default.removeItem(atPath: credPath)
            httpUsed = false
            if let content {
                try content.write(toFile: credPath, atomically: true, encoding: .utf8)
            }
            let result = usage
            XCTAssertEqual(result["error"] as? String, expected, content ?? "nil")
            XCTAssertFalse(httpUsed, content ?? "nil")
        }
    }

    /// test_custom_root_and_rotated_refresh_token_are_left_untouched
    func testCustomRootWithRefreshTokenUntouched() throws {
        try writeCredentials(["refresh_token": "fake-refresh"])
        let before = try Data(contentsOf: URL(fileURLWithPath: credPath))
        let beforeAttrs = try FileManager.default.attributesOfItem(atPath: credPath)
        let result = usage
        XCTAssertNotNil(result["windows"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: credPath)), before)
        let afterAttrs = try FileManager.default.attributesOfItem(atPath: credPath)
        XCTAssertEqual(beforeAttrs[.modificationDate] as? Date,
                       afterAttrs[.modificationDate] as? Date)
    }

    /// test_rejected_access_attempts_self_heal_then_reports_expired
    func testRejectedAccessAttemptsSelfHealThenReportsExpired() throws {
        try writeCredentials(["refresh_token": "fake-refresh"])
        let before = try Data(contentsOf: URL(fileURLWithPath: credPath))
        var callCount = 0
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: { self.clockBox.value },
                             http: { _, _, _, _ in callCount += 1; return (401, [:]) })
        let result = usage
        XCTAssertEqual(result["error"] as? String, "expired")
        XCTAssertTrue((result["detail"] as? String ?? "").contains("kimi login"))
        XCTAssertEqual(callCount, 1)   // 只有 usages 一次（刷新端点未触发）
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: credPath)), before)
    }

    // ---------------------------------------------------------- 自刷新 ----

    private func writeExpiredCredentials() throws {
        try writeCredentials(["expires_at": now - 60, "refresh_token": "fake-refresh",
                              "scope": "FEATURE_CODING", "token_type": "Bearer",
                              "expires_in": 900])
    }

    /// test_expired_token_refreshes_writes_back_and_uses_new_token
    func testExpiredTokenRefreshesWritesBackAndUsesNewToken() throws {
        try writeExpiredCredentials()
        var calls: [(String, [String: String], Data?, String)] = []
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: { self.clockBox.value },
                             http: { url, headers, body, method in
                                 calls.append((url, headers, body, method))
                                 if url.hasSuffix("/api/oauth/token") {
                                     return (200, ["access_token": "new-access",
                                                   "refresh_token": "new-refresh",
                                                   "expires_in": 900])
                                 }
                                 return (200, ["usage": ["limit": 100, "remaining": 55]])
                             })
        let result = usage
        let windows = result["windows"] as? [String: Any]
        XCTAssertEqual(((windows?["7d"] as? [String: Any])?["pct"] as? NSNumber)?
            .doubleValue ?? -1, 45, accuracy: 1e-9)

        // 刷新请求：form 编码 + public client_id
        XCTAssertEqual(calls.count, 2)
        let (url, headers, body, method) = calls[0]
        XCTAssertEqual(url, "https://auth.kimi.com/api/oauth/token")
        XCTAssertEqual(method, "POST")
        XCTAssertEqual(headers["Content-Type"], "application/x-www-form-urlencoded")
        let bodyText = String(data: body ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues:
            bodyText.split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 2)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            })
        XCTAssertEqual(fields["client_id"], "17e5f671-d194-4dfb-9706-5516cb48c098")
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["refresh_token"], "fake-refresh")
        // usages 用新 token
        XCTAssertEqual(calls[1].0, "https://api.kimi.com/coding/v1/usages")
        XCTAssertEqual(calls[1].1["Authorization"], "Bearer new-access")
        // 写回：全部键保留、token 轮换、expires_at 更新、0600
        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: credPath))) as? [String: Any]
        XCTAssertEqual(saved?["access_token"] as? String, "new-access")
        XCTAssertEqual(saved?["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(saved?["scope"] as? String, "FEATURE_CODING")
        XCTAssertEqual((saved?["expires_in"] as? NSNumber)?.intValue, 900)
        XCTAssertEqual((saved?["expires_at"] as? NSNumber)?.doubleValue ?? 0,
                       now + 900, accuracy: 0.001)
        let attrs = try FileManager.default.attributesOfItem(atPath: credPath)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
    }

    /// test_refresh_invalid_grant_rereads_disk_for_winner_token
    func testRefreshInvalidGrantRereadsDiskForWinnerToken() throws {
        try writeExpiredCredentials()
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: { self.clockBox.value },
                             http: { url, _, _, _ in
                                 if url.hasSuffix("/api/oauth/token") {
                                     // 赢家已把新凭据写盘，我们只是后动手的一方
                                     try? #"{"access_token":"winner-access","expires_at":1000900,"refresh_token":"winner-refresh"}"#
                                         .write(toFile: self.credPath, atomically: true,
                                                encoding: .utf8)
                                     return (400, ["error": "invalid_grant"])
                                 }
                                 return (200, ["usage": ["limit": 100, "remaining": 55]])
                             })
        let result = usage
        let windows = result["windows"] as? [String: Any]
        XCTAssertEqual(((windows?["7d"] as? [String: Any])?["pct"] as? NSNumber)?
            .doubleValue ?? -1, 45, accuracy: 1e-9)
    }

    /// test_refresh_failure_without_winner_reports_expired
    func testRefreshFailureWithoutWinnerReportsExpired() throws {
        try writeExpiredCredentials()
        let before = try Data(contentsOf: URL(fileURLWithPath: credPath))
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: { self.clockBox.value },
                             http: { url, _, _, _ in
                                 url.hasSuffix("/api/oauth/token")
                                     ? (400, ["error": "invalid_grant"])
                                     : (200, ["usage": ["limit": 100, "remaining": 55]])
                             })
        let result = usage
        XCTAssertEqual(result["error"] as? String, "expired")
        XCTAssertTrue((result["detail"] as? String ?? "").contains("自动刷新失败"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: credPath)), before)  // 败北不改凭据
    }

    /// test_expired_without_refresh_token_errors_without_http
    func testExpiredWithoutRefreshTokenErrorsWithoutHTTP() throws {
        try writeExpiredCredentials()
        try? FileManager.default.removeItem(atPath: credPath)
        try #"{"access_token":"fake-access","expires_at":999940}"#
            .write(toFile: credPath, atomically: true, encoding: .utf8)
        var httpUsed = false
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: { self.clockBox.value },
                             http: { _, _, _, _ in httpUsed = true; return (200, [:]) })
        let result = usage
        XCTAssertEqual(result["error"] as? String, "expired")
        XCTAssertTrue((result["detail"] as? String ?? "").contains("无 refresh_token"))
        XCTAssertFalse(httpUsed)
    }

    /// test_lock_timeout_returns_none
    func testLockTimeoutReturnsNone() throws {
        try writeExpiredCredentials()
        let lockPath = credDir + "/.tokentracker-refresh.lock"
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        let fd = open(lockPath, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        // timeout=0：立即超时（首检即中）
        let fresh = KimiBilling(ctx: ctx).freshCredentials(timeout: 0)
        XCTAssertNil(fresh)
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// test_non_mainland_region_uses_ai_hosts / test_oauth_host_env_override
    func testRegionAndEnvHosts() throws {
        // 非大陆 region → .ai 域
        try "global".write(toFile: tmp.path(".kimi-code", "region"),
                           atomically: true, encoding: .utf8)
        var calls: [String] = []
        try writeExpiredCredentials()
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")],
                             clock: { self.clockBox.value },
                             http: { url, _, _, _ in
                                 calls.append(url)
                                 if url.hasSuffix("/api/oauth/token") {
                                     return (200, ["access_token": "new-access",
                                                   "refresh_token": "new-refresh",
                                                   "expires_in": 900])
                                 }
                                 return (200, ["usage": ["limit": 100, "remaining": 55]])
                             })
        _ = usage
        XCTAssertEqual(calls[0], "https://auth.kimi.ai/api/oauth/token")
        XCTAssertEqual(calls[1], "https://api.kimi.ai/coding/v1/usages")

        // 环境变量覆盖
        calls = []
        try writeExpiredCredentials()
        ctx = BillingContext(home: tmp.url.path,
                             env: ["KIMI_CODE_HOME": tmp.path(".kimi-code"),
                                   "KIMI_CODE_OAUTH_HOST": "https://auth.example.com"],
                             clock: { self.clockBox.value },
                             http: { url, _, _, _ in
                                 calls.append(url)
                                 if url.hasSuffix("/api/oauth/token") {
                                     return (200, ["access_token": "new-access",
                                                   "refresh_token": "new-refresh",
                                                   "expires_in": 900])
                                 }
                                 return (200, ["usage": ["limit": 100, "remaining": 55]])
                             })
        _ = usage
        XCTAssertEqual(calls[0], "https://auth.example.com/api/oauth/token")
    }
}
