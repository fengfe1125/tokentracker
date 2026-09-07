//
//  BillingCacheTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_billing.py 的 BillingCacheTest / ProviderRetryTest。
//

import XCTest
@testable import TokenTrackerCore

final class BillingCachePortTests: XCTestCase {
    private var tmp: TempDir!
    private var cache: OfficialCache!
    private var clockBox: StateBox<Double>!

    override func setUp() async throws {
        tmp = try TempDir()
        clockBox = StateBox(1_000_000.0)
        let clock: () -> Double = { [clockBox] in clockBox!.value }
        cache = OfficialCache(diskPath: tmp.path("official_cache.json"), clock: clock)
    }

    override func tearDown() async throws {
        tmp = nil; cache = nil; clockBox = nil
    }

    /// test_failure_with_stale_result_obeys_error_backoff
    func testFailureWithStaleResultObeysErrorBackoff() {
        var calls = 0
        let fetch: () throws -> [String: Any] = {
            calls += 1
            return calls == 1
                ? ["windows": ["5h": ["pct": 45]]]
                : ["error": "offline"]
        }
        _ = cache.cached("provider", fn: fetch)
        clockBox.value += 121
        XCTAssertEqual(cache.cached("provider", fn: fetch)["_stale_min"] as? Int, 2)
        clockBox.value += 60
        XCTAssertEqual(cache.cached("provider", fn: fetch)["_stale_min"] as? Int, 3)
        XCTAssertEqual(calls, 2)
    }

    /// test_retry_after_is_not_bypassed_by_forced_refresh
    func testRetryAfterIsNotBypassedByForcedRefresh() {
        var calls = 0
        let fetch: () throws -> [String: Any] = {
            calls += 1
            return ["error": "http_429", "_retry_after": 300]
        }
        _ = cache.cached("provider", fn: fetch)
        clockBox.value += 121
        _ = cache.cached("provider", force: true, fn: fetch)
        XCTAssertEqual(calls, 1)
        clockBox.value += 180
        _ = cache.cached("provider", force: true, fn: fetch)
        XCTAssertEqual(calls, 2)
    }

    /// test_successful_fallback_still_honors_retry_after
    func testSuccessfulFallbackStillHonorsRetryAfter() {
        var calls = 0
        let fetch: () throws -> [String: Any] = {
            calls += 1
            return ["windows": ["5h": ["pct": 45]], "_via": "desktop", "_retry_after": 300]
        }
        _ = cache.cached("provider", fn: fetch)
        clockBox.value += 121
        _ = cache.cached("provider", force: true, fn: fetch)
        XCTAssertEqual(calls, 1)
    }

    /// test_long_backoff_does_not_keep_success_fresh_or_beyond_24_hours
    func testLongBackoffDoesNotKeepSuccessFresh() {
        var calls = 0
        let fetch: () throws -> [String: Any] = {
            calls += 1
            return ["windows": ["5h": ["pct": 45]], "_via": "desktop", "_retry_after": 90_000]
        }
        _ = cache.cached("provider", fn: fetch)
        clockBox.value += 121
        var result = cache.cached("provider", force: true, fn: fetch)
        XCTAssertEqual(result["_stale_min"] as? Int, 2)
        clockBox.value += 24 * 3600
        result = cache.cached("provider", force: true, fn: fetch)
        XCTAssertEqual(result["error"] as? String, "http_429")
        XCTAssertNil(result["windows"])
        XCTAssertEqual(calls, 1)
    }

    /// test_memory_and_disk_success_expire_after_24_hours
    func testMemoryAndDiskSuccessExpireAfter24Hours() {
        var calls = 0
        let fetch: () throws -> [String: Any] = {
            calls += 1
            return calls == 1 ? ["windows": ["5h": ["pct": 45]]] : ["error": "offline"]
        }
        _ = cache.cached("provider", fn: fetch)
        clockBox.value += 24 * 3600 + 1
        let result = cache.cached("provider", fn: fetch)
        XCTAssertEqual(result["error"] as? String, "offline")
        XCTAssertNil(result["_stale_min"])
    }

    /// test_success_and_error_cache_last_120_seconds
    func testSuccessAndErrorCacheLast120Seconds() {
        for (key, data) in [("success", ["windows": [:]] as [String: Any]),
                            ("error", ["error": "offline"] as [String: Any])] {
            var calls = 0
            let fetch: () throws -> [String: Any] = { calls += 1; return data }
            _ = cache.cached(key, fn: fetch)
            clockBox.value += 119
            _ = cache.cached(key, fn: fetch)
            XCTAssertEqual(calls, 1, key)
            clockBox.value += 1
            _ = cache.cached(key, fn: fetch)
            XCTAssertEqual(calls, 2, key)
        }
    }

    /// test_simultaneous_force_callers_share_one_request
    func testSimultaneousForceCallersShareOneRequest() {
        let callCount = StateBox(0)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let fetch: () throws -> [String: Any] = {
            callCount.value += 1
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return ["windows": ["5h": ["pct": 45]]]
        }
        let group = DispatchGroup()
        var results: [[String: Any]] = []
        let resultsLock = NSLock()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                let r = self.cache.cached("provider", force: true, fn: fetch)
                resultsLock.lock()
                results.append(r)
                resultsLock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.2)   // 让所有调用方都进入等待
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(callCount.value, 1)
        XCTAssertEqual(results.count, 8)
    }

    /// test_disk_writes_preserve_all_providers_across_processes（线程版：
    /// 多写者并发 flock + 原子替换不丢 key）
    func testDiskWritesPreserveAllProviders() {
        let group = DispatchGroup()
        for index in 0..<5 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for seq in 0..<15 {
                    self.cache.diskStore("\(index)", ts: self.clockBox.value,
                                         data: ["sequence": seq])
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        let data = FileManager.default.contents(atPath: cache.diskPath)
        let saved = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        XCTAssertEqual(Set(saved?.keys.map { $0 } ?? []), ["0", "1", "2", "3", "4"])
        for key in ["0", "1", "2", "3", "4"] {
            let record = saved?[key] as? [Any]
            XCTAssertEqual((record?[1] as? [String: Any])?["sequence"] as? Int, 14, key)
        }
    }

    /// versionFn：来源文件更新后下轮轮询重读（不等失败退避），但不绕过 429。
    /// 对齐 test_credentials_update_recovers_on_next_poll_without_force /
    /// test_credentials_change_does_not_bypass_rate_limit。
    func testSourceVersionChangeRecoversWithoutBypassingRateLimit() {
        var calls = 0
        let version = StateBox<[AnyHashable?]>(["v1"])
        var response: [String: Any] = ["error": "http_429", "_retry_after": 300]
        let fetch: () throws -> [String: Any] = { calls += 1; return response }
        // 第一次：429 限流
        var result = cache.cached("kimi", versionFn: { version.value }, fn: fetch)
        XCTAssertEqual(result["error"] as? String, "http_429")
        // 来源更新 + 普通轮询：仍在 429 退避内 → 不发请求
        version.value = ["v2"]
        clockBox.value += 60
        result = cache.cached("kimi", versionFn: { version.value }, fn: fetch)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result["error"] as? String, "http_429")
        // 退避结束后：来源变化直接触发新请求（即使失败退避未到也不等 120s 无版本场景）
        clockBox.value += 240
        response = ["windows": ["7d": ["pct": 45]]]
        result = cache.cached("kimi", versionFn: { version.value }, fn: fetch)
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(result["windows"])
    }
}

final class ProviderRetryPortTests: XCTestCase {
    /// test_providers_preserve_retry_after：四家 provider 429 都保留 Retry-After
    func testProvidersPreserveRetryAfter() throws {
        let tmp = try TempDir()
        let http: BillingHTTP = { _, _, _, _ in
            (429, ["error": "http_429", "_retry_after": 300])
        }
        // Claude：无桌面采样文件、无凭据文件；钥匙串返回有效凭据走 trySource → 429
        let claudeCtx = BillingContext(home: tmp.path("claude"), http: http)
        var claudeCtx2 = claudeCtx
        claudeCtx2.keychainRead = {
            ["claudeAiOauth": ["accessToken": "fake",
                               "expiresAt": Date().timeIntervalSince1970 * 1000 + 3_600_000]]
        }
        let claudeResult = ClaudeBilling(ctx: claudeCtx2).oauthUsage()
        XCTAssertEqual(claudeResult["error"] as? String, "http_429")
        XCTAssertEqual((claudeResult["_retry_after"] as? NSNumber)?.intValue, 300)

        // Kimi
        let kimiHome = tmp.path("kimi_home", ".kimi-code", "credentials")
        try FileManager.default.createDirectory(atPath: kimiHome, withIntermediateDirectories: true)
        try #"{"access_token":"fake-access","expires_at":99999999999}"#
            .write(toFile: kimiHome + "/kimi-code.json", atomically: true, encoding: .utf8)
        var kimiCtx = BillingContext(home: tmp.path("kimi_home"), http: http)
        kimiCtx.env = ["KIMI_CODE_HOME": tmp.path("kimi_home", ".kimi-code")]
        let kimiResult = KimiBilling(ctx: kimiCtx).usage()
        XCTAssertEqual(kimiResult["error"] as? String, "http_429")
        XCTAssertEqual((kimiResult["_retry_after"] as? NSNumber)?.intValue, 300)

        // Codex（RPC 兑底关闭：cliResolver 找不到）
        let codexHome = tmp.path("codex_home", ".codex")
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"fake"}}"#
            .write(toFile: codexHome + "/auth.json", atomically: true, encoding: .utf8)
        var codexCtx = BillingContext(home: tmp.path("codex_home"), http: http)
        codexCtx.cliResolver = { _ in nil }
        let codexResult = CodexBilling(ctx: codexCtx).usage()
        XCTAssertEqual(codexResult["error"] as? String, "http_429")
        XCTAssertEqual((codexResult["_retry_after"] as? NSNumber)?.intValue, 300)

        // Go
        var goCtx = BillingContext(home: tmp.path("go_home"), http: http)
        goCtx.env = ["OPENCODE_GO_API_KEY": "fake"]
        let goResult = GoBilling(ctx: goCtx).usage()
        XCTAssertEqual(goResult["error"] as? String, "http_429")
        XCTAssertEqual((goResult["_retry_after"] as? NSNumber)?.intValue, 300)
    }
}
