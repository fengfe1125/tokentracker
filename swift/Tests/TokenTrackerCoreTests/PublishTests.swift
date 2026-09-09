//
//  PublishTests.swift
//  TokenTrackerCoreTests
//
//  上报侧：三道闸的决策、设置白名单、token 解析顺序。
//  publishDecision 是纯函数（无时钟无网络），所有分支直接断言。
//

import XCTest
@testable import TokenTrackerCore

final class PublishTests: XCTestCase {

    // ------------------------------------------------------ 三道闸 ----

    private func decide(enabled: Bool = true, configured: Bool = true,
                        lastHash: String = "old", newHash: String = "new",
                        lastOkAt: Double = 0, failures: Int = 0,
                        now: Double = 1_000_000) -> PublishDecision {
        publishDecision(enabled: enabled, configured: configured,
                        lastHash: lastHash, newHash: newHash,
                        lastOkAt: lastOkAt, failures: failures, now: now)
    }

    func testGatesInPriorityOrder() {
        XCTAssertEqual(decide(enabled: false), .skipDisabled)
        XCTAssertEqual(decide(configured: false), .skipUnconfigured)
        // 关闭优先于未配置：关掉的时候不该抱怨没配
        XCTAssertEqual(decide(enabled: false, configured: false), .skipDisabled)
        XCTAssertEqual(decide(), .publish)
    }

    func testContentDedupe() {
        XCTAssertEqual(decide(lastHash: "same", newHash: "same"), .skipUnchanged)
        // 首次上报时 lastHash 为空，不能被当成「未变化」
        XCTAssertEqual(decide(lastHash: "", newHash: ""), .publish)
        XCTAssertEqual(decide(lastHash: "", newHash: "abc"), .publish)
    }

    func testMinIntervalThrottle() {
        let now: Double = 1_000_000
        // 刚发过 60 秒，内容变了也要等
        XCTAssertEqual(decide(lastOkAt: now - 60, now: now), .skipThrottled)
        XCTAssertEqual(decide(lastOkAt: now - PublishThrottle.minInterval + 1, now: now),
                       .skipThrottled)
        XCTAssertEqual(decide(lastOkAt: now - PublishThrottle.minInterval, now: now), .publish)
    }

    /// onFinish 每 60 秒触发一次 = 一天 1440 次。三道闸后必须远低于免费额度。
    func testThrottleCapsDailyWrites() {
        let perDay = 86_400 / PublishThrottle.minInterval
        XCTAssertLessThanOrEqual(perDay, 96)
        XCTAssertLessThan(perDay * 2, 1000, "两行/次 × 每日次数必须远低于 KV 的 1000 写")
    }

    func testBackoffGrowsAndCaps() {
        XCTAssertEqual(PublishThrottle.backoff(failures: 0), 0)
        XCTAssertEqual(PublishThrottle.backoff(failures: 1), 60)
        XCTAssertEqual(PublishThrottle.backoff(failures: 2), 120)
        XCTAssertEqual(PublishThrottle.backoff(failures: 5), 960)
        XCTAssertEqual(PublishThrottle.backoff(failures: 30), PublishThrottle.maxBackoff)
    }

    func testBackoffBlocksThenReleases() {
        let now: Double = 1_000_000
        // 失败 3 次 → 退避 240 秒
        XCTAssertEqual(decide(lastOkAt: now - 100, failures: 3, now: now), .skipBackoff)
        // 退避过了，但最小间隔还没到 —— 应报节流而不是退避
        XCTAssertEqual(decide(lastOkAt: now - 300, failures: 3, now: now), .skipThrottled)
        XCTAssertEqual(decide(lastOkAt: now - 1000, failures: 3, now: now), .publish)
    }

    // ------------------------------------------------ 内容哈希去重 ----

    /// generated_at 必须被剔除后再算哈希，否则每次载荷都不同，去重形同虚设。
    func testContentHashIgnoresGeneratedAt() throws {
        let dir = try TempDir()
        let store = try dir.store()
        let noon = Int64(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0,
                                               of: Date())!.timeIntervalSince1970 * 1000)
        try store.putEvent(tool: "claude", srcKey: "a", sessionID: "s",
                           ts: noon - 86_400_000, input: 10)
        try store.conn.commit()

        let a = try PublicStatsBuilder.build(store: store, nowMs: noon)
        let b = try PublicStatsBuilder.build(store: store, nowMs: noon + 7_200_000)
        XCTAssertNotEqual(a.generatedAt, b.generatedAt, "前提：两次的 generated_at 不同")
        XCTAssertEqual(PublicStatsPublisher.contentHash(a),
                       PublicStatsPublisher.contentHash(b),
                       "只有发布时间不同，哈希必须一致")
        XCTAssertFalse(PublicStatsPublisher.contentHash(a).isEmpty)
    }

    // ---------------------------------------------------- 设置白名单 ----

    /// 漏登记 isValid 的键会在读和写两侧被静默丢弃，所以两处必须同时覆盖。
    func testPublishSettingsRoundTrip() throws {
        let dir = try TempDir()
        let store = SettingsStore(path: dir.path("settings.json"))
        XCTAssertTrue(store.set(key: "publish_enabled", value: NSNumber(value: true)))
        XCTAssertTrue(store.set(key: "publish_endpoint", value: "https://tt.sakuramu.edu.kg"))
        XCTAssertTrue(store.set(key: "publish_handle", value: "sakuramu"))
        XCTAssertTrue(store.set(key: "publish_days", value: NSNumber(value: 730)))

        let effective = store.effective()
        XCTAssertEqual((effective["publish_enabled"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(effective["publish_endpoint"] as? String, "https://tt.sakuramu.edu.kg")
        XCTAssertEqual(effective["publish_handle"] as? String, "sakuramu")
        XCTAssertEqual((effective["publish_days"] as? NSNumber)?.intValue, 730)
    }

    func testPublishSettingsDefaultsAreSafe() {
        let defaults = SettingsStore.defaults
        XCTAssertEqual((defaults["publish_enabled"] as? NSNumber)?.boolValue, false,
                       "把数据发到公网的开关默认必须是关的")
        XCTAssertEqual(defaults["publish_endpoint"] as? String, "")
        XCTAssertEqual(defaults["publish_handle"] as? String, "")
    }

    /// bearer token 走明文 HTTP 就是凭据泄漏，必须在校验层拒掉。
    func testEndpointRejectsPlaintextHTTP() {
        XCTAssertFalse(SettingsStore.isValid(key: "publish_endpoint",
                                             value: "http://tt.sakuramu.edu.kg"))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_endpoint", value: "ftp://x.com"))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_endpoint",
                                             value: "https://x.com/a\nX: 1"))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_endpoint",
                                             value: String(repeating: "https://a.com/", count: 40)))
        XCTAssertTrue(SettingsStore.isValid(key: "publish_endpoint", value: ""))
        XCTAssertTrue(SettingsStore.isValid(key: "publish_endpoint", value: "https://tt.a.com"))
        XCTAssertTrue(SettingsStore.isValid(key: "publish_endpoint",
                                            value: "https://localhost:8787/base"))
    }

    func testHandleAndDaysValidation() {
        XCTAssertTrue(SettingsStore.isValid(key: "publish_handle", value: "sakuramu"))
        XCTAssertTrue(SettingsStore.isValid(key: "publish_handle", value: "a1-b2"))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_handle", value: "-lead"))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_handle", value: "UPPER"))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_handle", value: "a"))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_handle",
                                            value: String(repeating: "a", count: 40)))
        XCTAssertTrue(SettingsStore.isValid(key: "publish_days", value: NSNumber(value: 365)))
        XCTAssertFalse(SettingsStore.isValid(key: "publish_days", value: NSNumber(value: 1000)))
    }

    // -------------------------------------------------------- token ----

    /// 解析顺序：环境变量 → 钥匙串 → 文件。这里验文件兜底与不存在时的返回。
    func testTokenFallbackFile() throws {
        let dir = try TempDir()
        let path = dir.path("publish_token")
        let store = KeychainPublishTokenStore(fallbackPath: path)
        XCTAssertNil(store.read(handle: "nobody-should-have-this-handle-xyz"))
        try "  secret-token-value\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.read(handle: "nobody-should-have-this-handle-xyz"),
                       "secret-token-value", "应去掉首尾空白")
    }

    // ------------------------------------------------------ 状态文件 ----

    func testPublishStateRoundTrip() throws {
        let dir = try TempDir()
        let path = dir.path("publish_state.json")
        XCTAssertEqual(PublishState.load(path: path), PublishState(), "文件不存在时返回默认值")

        var state = PublishState()
        state.lastHash = "deadbeef"
        state.lastOkAt = 1_700_000_000
        state.lastError = "HTTP 429"
        state.consecutiveFailures = 2
        state.tzFirstSeen = "Asia/Shanghai"
        state.save(path: path)
        XCTAssertEqual(PublishState.load(path: path), state)

        // 密钥类邻居，必须 0600
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }

    /// 发布失败绝不能抛错、绝不能阻塞扫描。
    func testPublisherNeverThrowsOnHTTPFailure() throws {
        let dir = try TempDir()
        let settings = SettingsStore(path: dir.path("settings.json"))
        settings.set(key: "publish_enabled", value: NSNumber(value: true))
        settings.set(key: "publish_endpoint", value: "https://tt.example.com")
        settings.set(key: "publish_handle", value: "tester")
        try "tok".write(toFile: dir.path("token"), atomically: true, encoding: .utf8)

        let store = try dir.store()
        try store.putEvent(tool: "claude", srcKey: "a", sessionID: "s",
                           ts: store.nowMs() - 86_400_000, input: 10)
        try store.conn.commit()

        let publisher = PublicStatsPublisher(
            settings: settings, statePath: dir.path("publish_state.json"),
            tokens: KeychainPublishTokenStore(fallbackPath: dir.path("token")),
            http: { _, _, _, _ in (503, ["error": "upstream_down"]) },
            now: { 2_000_000 })
        let outcome = publisher.publishIfNeeded(store: store, force: true)
        XCTAssertEqual(outcome.status, 503)
        XCTAssertTrue(outcome.error.contains("503"))

        let state = PublishState.load(path: dir.path("publish_state.json"))
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertTrue(state.lastHash.isEmpty, "失败不得推进内容哈希，否则下次会被误判为未变化")
    }

    func testPublisherSuccessRecordsHashAndClearsError() throws {
        let dir = try TempDir()
        let settings = SettingsStore(path: dir.path("settings.json"))
        settings.set(key: "publish_enabled", value: NSNumber(value: true))
        settings.set(key: "publish_endpoint", value: "https://tt.example.com")
        settings.set(key: "publish_handle", value: "tester")
        try "tok".write(toFile: dir.path("token"), atomically: true, encoding: .utf8)

        let store = try dir.store()
        try store.putEvent(tool: "claude", srcKey: "a", sessionID: "s",
                           ts: store.nowMs() - 86_400_000, input: 10)
        try store.conn.commit()

        let seen = StateBox<[String]>([])
        let publisher = PublicStatsPublisher(
            settings: settings, statePath: dir.path("publish_state.json"),
            tokens: KeychainPublishTokenStore(fallbackPath: dir.path("token")),
            http: { url, headers, _, method in
                seen.value = [url, method, headers["authorization"] ?? ""]
                return (200, ["ok": true])
            },
            now: { 2_000_000 })
        let outcome = publisher.publishIfNeeded(store: store, force: true)
        XCTAssertTrue(outcome.error.isEmpty)
        XCTAssertGreaterThan(outcome.bytes, 0)
        XCTAssertEqual(seen.value[0], "https://tt.example.com/v1/stats/tester")
        XCTAssertEqual(seen.value[1], "PUT")
        XCTAssertEqual(seen.value[2], "Bearer tok")

        let state = PublishState.load(path: dir.path("publish_state.json"))
        XCTAssertFalse(state.lastHash.isEmpty)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertTrue(state.lastError.isEmpty)
        XCTAssertEqual(state.tzFirstSeen, TimeZone.current.identifier)

        // 第二次同样内容 → 去重跳过，不再发请求
        seen.value = []
        XCTAssertEqual(publisher.publishIfNeeded(store: store).decision, .skipUnchanged)
        XCTAssertTrue(seen.value.isEmpty, "去重后不应再发起 HTTP")
    }
}
