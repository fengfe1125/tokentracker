//
//  QuotaEstimatorTests.swift
//  TokenTrackerCoreTests
//
//  对齐 quotas.py 的窗口计算语义：本地估算、官方覆盖、过期/降级标注。
//

import XCTest
@testable import TokenTrackerCore

final class QuotaEstimatorPortTests: XCTestCase {
    private var tmp: TempDir!
    private var store: UsageStore!
    // 固定 2026-08-25 12:00:00 本地
    private var nowMs: Int64!

    override func setUp() async throws {
        tmp = try TempDir()
        store = try tmp.store()
        var cal = Calendar.current
        cal.timeZone = .current
        nowMs = Int64(cal.date(from: DateComponents(year: 2026, month: 8, day: 25,
                                                    hour: 12, minute: 0, second: 0))!
            .timeIntervalSince1970 * 1000)
        store.nowMs = { self.nowMs }
    }

    override func tearDown() async throws {
        tmp = nil; store = nil
    }

    private var config: QuotasConfig { .default }

    func testWindowStartSlidingAndMonth() throws {
        XCTAssertEqual(QuotaEstimator.windowStart("5h", nowMs: nowMs), nowMs - 5 * 3600 * 1000)
        XCTAssertEqual(QuotaEstimator.windowStart("7d", nowMs: nowMs), nowMs - 7 * 24 * 3600 * 1000)
        var cal = Calendar.current
        cal.timeZone = .current
        let monthStart = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        XCTAssertEqual(QuotaEstimator.windowStart("month", nowMs: nowMs),
                       Int64(monthStart.timeIntervalSince1970 * 1000))
    }

    /// 本地估算：5h 窗口计入 exact 事件，窗口外/未分配历史另列。
    func testLocalEstimation() throws {
        // 窗口内：5M tokens（含缓存），4M 非缓存
        try store.putEvent(tool: "claude", srcKey: "a", sessionID: "s", ts: nowMs - 3600_000,
                           model: "claude-sonnet-4-5",
                           input: 3_000_000, output: 1_000_000, cacheRead: 1_000_000)
        // 窗口外（6 小时前）：不计入 5h
        try store.putEvent(tool: "claude", srcKey: "b", sessionID: "s", ts: nowMs - 6 * 3600_000,
                           model: "claude-sonnet-4-5", input: 2_000_000)
        // 未分配历史：不算入窗口百分比，单独提示
        try store.putEvent(tool: "claude", srcKey: "c", sessionID: "s", ts: nowMs,
                           model: "claude-sonnet-4-5", input: 500_000,
                           timeQuality: "unallocated")
        let entries = try QuotaEstimator.compute(store: store, config: config, nowMs: nowMs)
        let claude = try XCTUnwrap(entries.first { $0.id == "claude" })
        XCTAssertEqual(claude.source, "local")
        let w5h = try XCTUnwrap(claude.windows.first { $0.key == "5h" })
        // 非缓存 input+output = 4M / 100M = 4%
        XCTAssertEqual(w5h.used, 4_000_000)
        XCTAssertEqual(w5h.limit, 100_000_000)
        XCTAssertEqual(w5h.pct, 4.0)
        // 窗口外事件非 unallocated → 只报未分配历史
        XCTAssertEqual(w5h.unallocated, 500_000)
        let w7d = try XCTUnwrap(claude.windows.first { $0.key == "7d" })
        XCTAssertEqual(w7d.used, 6_000_000)  // 两笔 exact 都进 7d
    }

    /// 官方覆盖：官方 pct 直接替换本地估算；stale 标注。
    func testOfficialOverrideAndStale() throws {
        let official = OfficialResult(
            windows: ["5h": OfficialWindow(pct: 42.34, used: nil, limit: nil,
                                           resetsAt: "2026-08-25T17:00:00Z")],
            staleMin: 18, error: "timeout")
        let entries = try QuotaEstimator.compute(store: store, config: config, nowMs: nowMs) { name in
            name == "claude-oauth" ? official : nil
        }
        let claude = try XCTUnwrap(entries.first { $0.id == "claude" })
        XCTAssertEqual(claude.source, "official")
        XCTAssertTrue(claude.note.contains("18 分钟前"))
        let w5h = try XCTUnwrap(claude.windows.first { $0.key == "5h" })
        XCTAssertEqual(w5h.pct, 42.3)
        XCTAssertEqual(w5h.source, "official")
        XCTAssertTrue(w5h.stale)
        XCTAssertEqual(w5h.resetsAt, "2026-08-25T17:00:00Z")
        // 7d 无官方数据 → 本地兜底
        let w7d = try XCTUnwrap(claude.windows.first { $0.key == "7d" })
        XCTAssertEqual(w7d.source, "local")
    }

    /// USD 窗口（OpenCode Go）：按 dsh deepseek 前缀的估算成本统计。
    func testUSDWindowWithModelPrefix() throws {
        try store.putEvent(tool: "dsh", srcKey: "x", sessionID: "s", ts: nowMs - 3600_000,
                           model: "deepseek-v4-pro", input: 1_000_000, cost: 3.25)
        try store.putEvent(tool: "dsh", srcKey: "y", sessionID: "s", ts: nowMs - 3600_000,
                           model: "other-model", input: 1_000_000, cost: 9.99)
        let entries = try QuotaEstimator.compute(store: store, config: config, nowMs: nowMs)
        let go = try XCTUnwrap(entries.first { $0.id == "go" })
        let w5h = try XCTUnwrap(go.windows.first { $0.key == "5h" })
        XCTAssertEqual(w5h.unit, "usd")
        XCTAssertEqual(w5h.used, 3.25)
        XCTAssertEqual(w5h.limit, 12)
        XCTAssertEqual(w5h.pct ?? 0, 27.1, accuracy: 0.05)
    }

    /// 官方 plan 合并：重复时只保留信息量更大的一边。
    func testOfficialPlanMerge() throws {
        let official = OfficialResult(
            windows: ["5h": OfficialWindow(pct: 1)],
            plan: "Pro")
        let entries = try QuotaEstimator.compute(store: store, config: config, nowMs: nowMs) { name in
            name == "claude-oauth" ? official : nil
        }
        let claude = try XCTUnwrap(entries.first { $0.id == "claude" })
        // "Pro" 已包含在配置 "Pro/Max" 里 → 保持配置
        XCTAssertEqual(claude.plan, "Pro/Max")
    }

    /// 无官方且无用量：pct 为 0（不是 nil）。
    func testEmptyWindowShowsZero() throws {
        let entries = try QuotaEstimator.compute(store: store, config: config, nowMs: nowMs)
        let codex = try XCTUnwrap(entries.first { $0.id == "codex" })
        let w5h = try XCTUnwrap(codex.windows.first { $0.key == "5h" })
        XCTAssertEqual(w5h.pct, 0)
        XCTAssertEqual(w5h.used, 0)
    }
}
