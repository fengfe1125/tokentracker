//
//  ClaudeBillingTests.swift
//  TokenTrackerCoreTests
//
//  移植 test_billing.py 的 Claude 窗口解析与桌面兜底用例。
//

import XCTest
@testable import TokenTrackerCore

final class ClaudeBillingPortTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() async throws { tmp = try TempDir() }
    override func tearDown() async throws { tmp = nil }

    /// 构造：钥匙串返回未过期凭据，http 返回指定 usage 载荷。
    private func makeBilling(usagePayload: [String: Any],
                             httpStatus: Int = 200) -> ClaudeBilling {
        var ctx = BillingContext(home: tmp.url.path, http: { _, _, _, _ in
            (httpStatus, usagePayload)
        })
        ctx.keychainRead = {
            ["claudeAiOauth": ["accessToken": "fake-access",
                               "expiresAt": Date().timeIntervalSince1970 * 1000 + 3_600_000]]
        }
        ctx.keychainWrite = { _ in true }
        return ClaudeBilling(ctx: ctx)
    }

    /// test_official_utilization_is_already_percent：0.5→0.5%、1→1%（不猜单位）
    func testOfficialUtilizationIsAlreadyPercent() {
        let billing = makeBilling(usagePayload: [
            "five_hour": ["utilization": 0.5, "resets_at": "2026-09-08T01:00:00Z"],
            "seven_day": ["utilization": 1, "resets_at": nil],
        ])
        let result = billing.oauthUsage()
        let windows = result["windows"] as? [String: Any]
        let w5h = windows?["5h"] as? [String: Any]
        let w7d = windows?["7d"] as? [String: Any]
        XCTAssertEqual((w5h?["pct"] as? NSNumber)?.doubleValue ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual((w7d?["pct"] as? NSNumber)?.doubleValue ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(result["_via"] as? String, "oauth")
        XCTAssertEqual((w5h?["resets_at"] as? NSNumber)?.int64Value,
                       1788829200000)  // 2026-09-08T01:00:00Z
    }

    /// test_invalid_percentages_are_absent
    func testInvalidPercentagesAreAbsent() {
        let billing = makeBilling(usagePayload: [
            "five_hour": ["utilization": "abc"],
            "seven_day": ["utilization": Double.nan],
            "seven_day_sonnet": ["utilization": 33],
        ])
        let result = billing.oauthUsage()
        let windows = result["windows"] as? [String: Any] ?? [:]
        XCTAssertNil(windows["5h"])
        XCTAssertNil(windows["7d"])
        XCTAssertNotNil(windows["7d_sonnet"])
    }

    /// test_desktop_fallback_preserves_oauth_rate_limit
    func testDesktopFallbackPreservesOAuthRateLimit() throws {
        // 桌面采样文件（新鲜样本）
        let claudeDir = tmp.path("Library", "Application Support", "Claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let sample: [String: Any] = ["samples": [
            ["t": Date().timeIntervalSince1970 * 1000 - 60_000,
             "u": ["fh": 45, "sd": 12]],
        ]]
        let data = try JSONSerialization.data(withJSONObject: sample)
        try data.write(to: URL(fileURLWithPath: claudeDir + "/plan-usage-history.json"))

        var ctx = BillingContext(home: tmp.url.path, http: { _, _, _, _ in
            (429, ["_retry_after": 300])
        })
        ctx.keychainRead = {
            ["claudeAiOauth": ["accessToken": "fake-access",
                               "expiresAt": Date().timeIntervalSince1970 * 1000 + 3_600_000]]
        }
        let result = ClaudeBilling(ctx: ctx).oauthUsage()
        XCTAssertEqual(result["_via"] as? String, "desktop")
        XCTAssertEqual((result["_retry_after"] as? NSNumber)?.intValue, 300)
        XCTAssertEqual(result["_oauth_err"] as? String, "http_429")
        let windows = result["windows"] as? [String: Any]
        XCTAssertEqual(((windows?["5h"] as? [String: Any])?["pct"] as? NSNumber)?
            .doubleValue ?? -1, 45, accuracy: 1e-9)
    }

    /// 桌面采样 >30min 视为无效。
    func testStaleDesktopSampleIgnored() throws {
        let claudeDir = tmp.path("Library", "Application Support", "Claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let sample: [String: Any] = ["samples": [
            ["t": Date().timeIntervalSince1970 * 1000 - 31 * 60_000, "u": ["fh": 45]],
        ]]
        let data = try JSONSerialization.data(withJSONObject: sample)
        try data.write(to: URL(fileURLWithPath: claudeDir + "/plan-usage-history.json"))
        var ctx = BillingContext(home: tmp.url.path, http: { _, _, _, _ in (200, [:]) })
        ctx.keychainRead = { nil }
        ctx.keychainWrite = { _ in false }
        let result = ClaudeBilling(ctx: ctx).oauthUsage()
        XCTAssertEqual(result["error"] as? String, "no_credentials")
    }

    /// 空壳凭据（官方 bug 清空的条目）被跳过。
    func testShellCredentialsSkipped() throws {
        var ctx = BillingContext(home: tmp.url.path, http: { _, _, _, _ in (200, [:]) })
        ctx.keychainRead = { ["claudeAiOauth": [:]] }   // accessToken/refreshToken 皆空
        ctx.keychainWrite = { _ in false }
        let result = ClaudeBilling(ctx: ctx).oauthUsage()
        XCTAssertEqual(result["error"] as? String, "no_credentials")
    }

    func testCurrentLoginRejectsSavedBackupDesktopAndUnscopedCache() throws {
        let backup = tmp.path(".tokentracker", "claude_cred_backup.json")
        atomicWriteJSON(backup, ["claudeAiOauth": ["accessToken": "old-account", "refreshToken": "old-refresh"]])
        atomicWriteJSON(tmp.path("Library", "Application Support", "Claude", "plan-usage-history.json"),
                        ["samples": [["t": Date().timeIntervalSince1970 * 1000, "u": ["fh": 0]]]])
        var calls = 0
        var ctx = BillingContext(home: tmp.url.path, env: [:], http: { _, _, _, _ in
            calls += 1
            return (200, ["five_hour": ["utilization": 0]])
        })
        ctx.keychainRead = { ["claudeAiOauth": ["accessToken": "", "refreshToken": ""]] }
        let cachePath = tmp.path("quota-cache.json")
        atomicWriteJSON(cachePath, ["claude-oauth": [Date().timeIntervalSince1970,
            ["windows": ["5h": ["pct": 0]], "_via": "oauth"]] as [Any]])
        let service = OfficialQuotaService(ctx: ctx, cache: OfficialCache(diskPath: cachePath), currentLoginOnly: true)
        let result = service.cached("claude-oauth")
        XCTAssertEqual(result["error"] as? String, "no_credentials")
        XCTAssertNil(result["windows"])
        XCTAssertEqual(calls, 0, "Never query an inactive backup login for the HUD")
    }

    func testCurrentLoginPrefersKeychainAndDoesNotReuseAnotherLoginCache() throws {
        let future = Date().timeIntervalSince1970 * 1000 + 3_600_000
        atomicWriteJSON(tmp.path(".claude", ".credentials.json"), ["claudeAiOauth": [
            "accessToken": "different-file-login", "expiresAt": future + 100_000]])
        var activeToken: String? = "first-login"
        var requested: [String] = []
        var ctx = BillingContext(home: tmp.url.path, env: [:], http: { _, headers, _, _ in
            let auth = headers["Authorization"] ?? ""
            requested.append(auth)
            return (200, ["five_hour": ["utilization": auth == "Bearer first-login" ? 12 : 34]])
        })
        ctx.keychainRead = {
            activeToken.map { ["claudeAiOauth": ["accessToken": $0, "expiresAt": future]] }
        }
        let cachePath = tmp.path("quota-cache.json")
        atomicWriteJSON(cachePath, [:])
        let service = OfficialQuotaService(ctx: ctx, cache: OfficialCache(diskPath: cachePath), currentLoginOnly: true)
        func pct() -> Double? {
            let raw = service.cached("claude-oauth")
            return OfficialQuotaService.toOfficialResult(raw).windows?["5h"]?.pct
        }
        XCTAssertEqual(pct(), 12)
        activeToken = "second-login"
        XCTAssertEqual(pct(), 34, "Changing the active credential bypasses the first login's cached quota")
        XCTAssertEqual(requested, ["Bearer first-login", "Bearer second-login"])
        activeToken = nil
        // After sign-out, a genuinely present CLI credentials file is the next active source.
        XCTAssertEqual(service.fetch("claude-oauth")["_via"] as? String, "oauth")
        XCTAssertEqual(requested.last, "Bearer different-file-login")
    }
}
