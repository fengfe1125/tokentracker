//
//  PublicStatsTests.swift
//  TokenTrackerCoreTests
//
//  公开载荷会被发到公网、进 CDN 缓存、不可撤销，所以这里的断言分两类：
//  一类保证数字对，一类保证**不该出去的东西没出去**。后者是隐私契约本身。
//

import XCTest
@testable import TokenTrackerCore

final class PublicStatsTests: XCTestCase {

    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    // ---------------------------------------------------------- 连续天数 ----

    func testStreaksTableDriven() {
        let cases: [(name: String, days: [String], today: String, current: Int, longest: Int)] = [
            ("空",             [], "2026-09-09", 0, 0),
            ("只有今天",        ["2026-09-09"], "2026-09-09", 1, 1),
            ("只有昨天·宽限",   ["2026-09-08"], "2026-09-09", 1, 1),
            ("只有前天·已断",   ["2026-09-07"], "2026-09-09", 0, 1),
            ("连续四天",        ["2026-09-06", "2026-09-07", "2026-09-08", "2026-09-09"], "2026-09-09", 4, 4),
            ("断裂 3 与 5",     ["2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04",
                                "2026-09-07", "2026-09-08", "2026-09-09"], "2026-09-09", 3, 5),
            ("跨年",           ["2025-12-30", "2025-12-31", "2026-01-01"], "2026-01-01", 3, 3),
            ("跨闰日",         ["2028-02-28", "2028-02-29", "2028-03-01"], "2028-03-01", 3, 3),
        ]
        for c in cases {
            let got = PublicMetrics.streaks(activeDays: Set(c.days), today: c.today, timeZone: shanghai)
            XCTAssertEqual(got.current, c.current, "current 不符：\(c.name)")
            XCTAssertEqual(got.longest, c.longest, "longest 不符：\(c.name)")
        }
    }

    /// 日期加减必须走 Calendar。用 ts ± 86_400_000 的实现会在夏令时切换日少一天或多一天，
    /// 让连续段被腰斩。Asia/Shanghai 无夏令时，所以这条必须显式指定 America/New_York。
    func testStreaksSurvivesDaylightSaving() {
        // 2026-03-08 春季前跳，2026-11-01 秋季回拨。
        let spring = ["2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10"]
        let springStreaks = PublicMetrics.streaks(activeDays: Set(spring),
                                                  today: "2026-03-10", timeZone: newYork)
        XCTAssertEqual(springStreaks.current, 5)
        XCTAssertEqual(springStreaks.longest, 5)

        let fall = ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"]
        let fallStreaks = PublicMetrics.streaks(activeDays: Set(fall),
                                                today: "2026-11-02", timeZone: newYork)
        XCTAssertEqual(fallStreaks.current, 4)
        XCTAssertEqual(fallStreaks.longest, 4)
    }

    // ------------------------------------------------------ 最长连续段 ----

    private func events(_ tool: String, _ session: String, _ offsetsMinutes: [Int]) -> [BurstEvent] {
        let base: Int64 = 1_788_000_000_000
        return offsetsMinutes.map { BurstEvent(tool: tool, session: session,
                                               ts: base + Int64($0) * 60_000) }
    }

    func testLongestBurstEmptyAndSingleEvent() {
        XCTAssertNil(PublicMetrics.longestBurst([]))
        // 单事件会话不构成「聊天」，不能被当成时长 0 的段参与比较。
        XCTAssertNil(PublicMetrics.longestBurst(events("claude", "a", [0])))
    }

    func testLongestBurstGapBoundaryIsStrictlyGreater() {
        // 29 分钟 → 同一段
        XCTAssertEqual(PublicMetrics.longestBurst(events("claude", "a", [0, 29]))?.seconds, 29 * 60)
        // 正好 30 分钟 → 仍是同一段（阈值是 >，不是 >=）
        XCTAssertEqual(PublicMetrics.longestBurst(events("claude", "a", [0, 30]))?.seconds, 30 * 60)
        // 31 分钟 → 切成两个单事件段 → 无有效段
        XCTAssertNil(PublicMetrics.longestBurst(events("claude", "a", [0, 31])))
    }

    func testLongestBurstPicksLongestRunAndCountsEvents() {
        // 三段：10 分钟 / 40 分钟（最长，在中间）/ 5 分钟
        let e = events("claude", "a", [0, 5, 10,
                                       60, 80, 100,
                                       200, 205])
        let burst = PublicMetrics.longestBurst(e)
        XCTAssertEqual(burst?.seconds, 40 * 60)
        XCTAssertEqual(burst?.events, 3)
        XCTAssertEqual(burst?.tool, "claude")
    }

    /// session_id 只在 tool 内唯一（表的唯一键是 (tool, src_key)）。
    /// 两个工具下的同名会话绝不能被折算成一段。
    func testLongestBurstDoesNotMergeAcrossTools() {
        var e = events("claude", "shared-id", [0, 10])
        e += events("codex", "shared-id", [11, 12])
        let burst = PublicMetrics.longestBurst(e)
        XCTAssertEqual(burst?.seconds, 10 * 60, "跨工具被错误合并了")
    }

    // ------------------------------------------------------------ 峰值 ----

    func testPeakDay() {
        XCTAssertNil(PublicMetrics.peakDay([]))
        XCTAssertNil(PublicMetrics.peakDay([("2026-09-01", 0), ("2026-09-02", 0)]))
        XCTAssertEqual(PublicMetrics.peakDay([("2026-09-01", 5), ("2026-09-02", 9),
                                              ("2026-09-03", 2)])?.day, "2026-09-02")
        // 并列取较晚的日期
        XCTAssertEqual(PublicMetrics.peakDay([("2026-09-01", 9), ("2026-09-05", 9)])?.day, "2026-09-05")
    }

    // ------------------------------------------------------------ 载荷 ----

    /// 当天本地时间正午的毫秒时间戳，避免测试踩到日界。
    private func noonToday() -> Int64 {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        return Int64(noon.timeIntervalSince1970 * 1000)
    }

    private func daysAgo(_ n: Int) -> Int64 { noonToday() - Int64(n) * 86_400_000 }

    func testTotalsIdentityAndUndatedDisclosure() throws {
        let dir = try TempDir()
        let store = try dir.store()
        try store.putEvent(tool: "claude", srcKey: "a", sessionID: "s1",
                           ts: daysAgo(1), input: 500)
        // 无法还原时间的存量历史：不进热力图，但必须留在总量里并被披露。
        try store.putEvent(tool: "claude", srcKey: "b", sessionID: "s2",
                           ts: daysAgo(1), input: 1000, timeQuality: "unallocated")
        try store.conn.commit()

        let payload = try PublicStatsBuilder.build(store: store, nowMs: noonToday())
        XCTAssertEqual(payload.totals.tokens, 1500)
        XCTAssertEqual(payload.totals.tokensDated, 500)
        XCTAssertEqual(payload.totals.tokensUndated, 1000)
        XCTAssertEqual(payload.daily.tokens.reduce(0, +), 500)
        XCTAssertEqual(payload.caveats.undatedShare, 0.6667, accuracy: 0.0001)
        // 恒等式必须成立，否则公开页面会出现无法解释的缺口。
        XCTAssertEqual(payload.totals.tokensDated + payload.totals.tokensUndated,
                       payload.totals.tokens)
    }

    /// 回归：opencode / hermes 全部走累计快照，ts 是**扫描时刻**而非事件时刻，
    /// 观测点十几分钟一个。不限定 exact 的话会被串成「连续聊了几十小时」。
    func testLongestBurstIgnoresSnapshotOnlyTools() throws {
        let dir = try TempDir()
        let store = try dir.store()
        // 40 小时内每 18 分钟一个观测点，全是 observed。
        var ts = daysAgo(3)
        for i in 0..<130 {
            try store.putEvent(tool: "opencode", srcKey: "snap\(i)", sessionID: "long-session",
                               ts: ts, input: 100,
                               timeQuality: "observed", intervalStart: ts - 1_080_000)
            ts += 1_080_000
        }
        // 一段真实的 20 分钟对话。
        try store.putEvent(tool: "claude", srcKey: "c1", sessionID: "chat", ts: daysAgo(1), input: 10)
        try store.putEvent(tool: "claude", srcKey: "c2", sessionID: "chat",
                           ts: daysAgo(1) + 20 * 60_000, input: 10)
        try store.conn.commit()

        let payload = try PublicStatsBuilder.build(store: store, nowMs: noonToday())
        XCTAssertEqual(payload.longestBurst?.agent, "claude")
        XCTAssertEqual(payload.longestBurst?.seconds, 20 * 60)
        XCTAssertEqual(payload.longestBurst?.basis, "exact")
        XCTAssertTrue(payload.caveats.snapshotOnlyAgents.contains("opencode"),
                      "只有累计快照的工具必须被披露")
    }

    /// 隐私契约：把已知敏感值种进库，断言序列化结果里一个都搜不到。
    /// golden fixture 抓「多了字段」，这条抓「字段里混进了内容」。
    func testPayloadLeaksNothingSensitive() throws {
        let dir = try TempDir()
        let store = try dir.store()
        let secrets = ["/Users/sakura/secret-client-project", "abc-123-session-uuid",
                       "claude-opus-4-20260101", "帮我重构支付网关的密钥轮换逻辑"]
        try store.putEvent(tool: "claude", srcKey: "/Users/sakura/secret/log.jsonl",
                           sessionID: secrets[1], project: secrets[0],
                           ts: daysAgo(1), model: secrets[2], input: 100, output: 50)
        try store.setSessionTitle(tool: "claude", sessionID: secrets[1], title: secrets[3])
        try store.conn.commit()

        let text = String(data: try PublicStatsBuilder.build(store: store,
                                                             nowMs: noonToday()).encoded(),
                          encoding: .utf8)!
        for secret in secrets + ["/Users/sakura", "log.jsonl", "secret"] {
            XCTAssertFalse(text.contains(secret), "载荷泄漏了敏感内容：\(secret)")
        }
    }

    /// 顶层键是白名单。新增任何字段都必须先改这里 —— 强制一次有意识的隐私复核。
    /// peak / longest_burst 是 Optional，为空时整个键省略，所以用「子集 + 必需集」而非全等。
    func testPayloadTopLevelKeysAreWhitelisted() throws {
        let allowed: Set<String> = [
            "v", "generated_at", "tz", "tz_offset_minutes", "app_version",
            "range", "totals", "daily", "peak", "streak", "longest_burst",
            "agents", "caveats",
        ]
        let required = allowed.subtracting(["peak", "longest_burst"])

        func keys(_ store: UsageStore) throws -> Set<String> {
            let data = try PublicStatsBuilder.build(store: store, nowMs: noonToday()).encoded()
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(object["v"] as? Int, TokenTrackerCore.publicStatsFormatVersion)
            return Set(object.keys)
        }

        // 单事件：没有连续段，longest_burst 应缺席。
        let sparse = try TempDir()
        let sparseStore = try sparse.store()
        try sparseStore.putEvent(tool: "claude", srcKey: "a", sessionID: "s",
                                 ts: daysAgo(1), input: 10)
        try sparseStore.conn.commit()
        let sparseKeys = try keys(sparseStore)
        XCTAssertTrue(sparseKeys.isSubset(of: allowed),
                      "出现了白名单外的字段：\(sparseKeys.subtracting(allowed))")
        XCTAssertTrue(required.isSubset(of: sparseKeys),
                      "缺少必需字段：\(required.subtracting(sparseKeys))")
        XCTAssertFalse(sparseKeys.contains("longest_burst"))

        // 有连续段：两个可选键都应在场，且仍不越界。
        let full = try TempDir()
        let fullStore = try full.store()
        try fullStore.putEvent(tool: "claude", srcKey: "a", sessionID: "s",
                               ts: daysAgo(1), input: 10)
        try fullStore.putEvent(tool: "claude", srcKey: "b", sessionID: "s",
                               ts: daysAgo(1) + 600_000, input: 10)
        try fullStore.conn.commit()
        let fullKeys = try keys(fullStore)
        XCTAssertEqual(fullKeys, allowed,
                       "数据齐全时应恰好是白名单全集，多出：\(fullKeys.subtracting(allowed))")
    }

    /// generated_at 取整到小时：分钟级精度连续几个月就是一条作息信号。
    func testGeneratedAtIsHourRounded() throws {
        let dir = try TempDir()
        let store = try dir.store()
        try store.putEvent(tool: "claude", srcKey: "a", sessionID: "s", ts: daysAgo(1), input: 10)
        try store.conn.commit()

        let odd = (noonToday() / 3_600_000) * 3_600_000 + 37 * 60_000 + 12_345
        let payload = try PublicStatsBuilder.build(store: store, nowMs: odd)
        XCTAssertTrue(payload.generatedAt.hasSuffix(":00:00Z"),
                      "generated_at 未取整到小时：\(payload.generatedAt)")
    }

    func testPayloadStaysSmallOverAFullYear() throws {
        let dir = try TempDir()
        let store = try dir.store()
        for day in 0..<365 {
            try store.putEvent(tool: ScannerRegistry.all[day % ScannerRegistry.all.count],
                               srcKey: "e\(day)", sessionID: "s\(day)",
                               ts: daysAgo(day), input: Int64(day) * 100_003, output: 7)
        }
        try store.conn.commit()

        let payload = try PublicStatsBuilder.build(store: store, days: 365, nowMs: noonToday())
        XCTAssertEqual(payload.range.days, 365)
        XCTAssertEqual(payload.daily.tokens.count, payload.range.days)
        XCTAssertEqual(payload.daily.tokens.reduce(0, +), payload.daily.windowTokens)
        XCTAssertLessThan(try payload.encoded().count, 32_768)
    }

    func testEmptyDatabaseProducesValidPayload() throws {
        let dir = try TempDir()
        let store = try dir.store()
        let payload = try PublicStatsBuilder.build(store: store, nowMs: noonToday())
        XCTAssertEqual(payload.totals.tokens, 0)
        XCTAssertEqual(payload.streak.current, 0)
        XCTAssertNil(payload.peak)
        XCTAssertNil(payload.longestBurst)
        XCTAssertTrue(payload.agents.isEmpty)
        // 数组长度与 range.days 的不变式在空库上同样必须成立。
        XCTAssertEqual(payload.daily.tokens.count, payload.range.days)
    }
}
