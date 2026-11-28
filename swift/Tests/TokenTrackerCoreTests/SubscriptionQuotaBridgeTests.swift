//
//  SubscriptionQuotaBridgeTests.swift
//  TokenTrackerCoreTests
//
//  CLI quotas 的官方窗口来源：TokenTracker 账号库快照 → QuotaEstimator。
//

import XCTest
@testable import TokenTrackerCore

final class SubscriptionQuotaBridgeTests: XCTestCase {
    private func card(_ provider: SubscriptionProvider, active: Bool = true, label: String = "a",
                      _ snapshot: SubscriptionSnapshot) -> SubscriptionCard {
        let account = SubscriptionAccount(provider: provider, label: label,
                                          source: SubscriptionSource(tool: "TokenTracker", location: label),
                                          isActive: active, credential: nil, providerAccountID: label)
        return SubscriptionCard(account: account, snapshot: snapshot)
    }

    func testFixedWindowsMapByDurationAndKeepFirstOfEachKey() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = SubscriptionSnapshot(status: .current, windows: [
            SubscriptionWindow(id: "five_hour", duration: 18_000, usedPercent: 12, resetsAt: reset),
            SubscriptionWindow(id: "seven_day", duration: 604_800, usedPercent: 40),
            SubscriptionWindow(id: "seven_day_opus", duration: 604_800, usedPercent: 99),
            SubscriptionWindow(id: "pool", duration: nil, usedPercent: 70),
            SubscriptionWindow(id: "monthly", duration: 2_592_000, usedPercent: 5,
                               used: 3, limit: 60, unit: "usd"),
        ], plan: "Max", sampledAt: Date())
        let result = try XCTUnwrap(SubscriptionQuotaBridge.officialResult("claude-oauth", cards: [card(.claude, snapshot)]))
        XCTAssertEqual(Set(result.windows?.keys ?? [:].keys), ["5h", "7d", "month"])
        XCTAssertEqual(result.windows?["5h"]?.pct, 12)
        XCTAssertEqual(result.windows?["5h"]?.resetsAt, ISO8601DateFormatter().string(from: reset))
        XCTAssertEqual(result.windows?["7d"]?.pct, 40, "同键只取第一个窗口")
        XCTAssertEqual(result.windows?["month"]?.limit, 60)
        XCTAssertEqual(result.plan, "Max")
        XCTAssertNil(result.staleMin)
        XCTAssertNil(result.error)
    }

    func testNoAccountOrAmbiguousAccountFallsBackToLocal() {
        let snapshot = SubscriptionSnapshot(status: .current, windows: [
            SubscriptionWindow(id: "rolling", duration: 18_000, usedPercent: 1)])
        XCTAssertNil(SubscriptionQuotaBridge.officialResult("go", cards: []))
        XCTAssertNil(SubscriptionQuotaBridge.officialResult("go", cards: [
            card(.go, label: "one", snapshot), card(.go, label: "two", snapshot)]), "无法确定账号时不取任意一个")
        XCTAssertNil(SubscriptionQuotaBridge.officialResult("go", cards: [card(.go, active: false, snapshot)]))
        XCTAssertNil(SubscriptionQuotaBridge.officialResult("unknown", cards: [card(.go, snapshot)]))
    }

    func testStaleAndFailedSnapshots() throws {
        let now = Date()
        let stale = SubscriptionSnapshot(status: .stale, windows: [
            SubscriptionWindow(id: "limit-0", duration: 18_000, usedPercent: 30)],
                                         sampledAt: now.addingTimeInterval(-600))
        let staleResult = try XCTUnwrap(SubscriptionQuotaBridge.officialResult("kimi", cards: [card(.kimi, stale)], now: now))
        XCTAssertEqual(staleResult.staleMin, 10)
        XCTAssertEqual(staleResult.windows?["5h"]?.pct, 30)

        let failed = SubscriptionSnapshot(status: .expired, problem: .credentialExpired)
        let failedResult = try XCTUnwrap(SubscriptionQuotaBridge.officialResult("codex", cards: [card(.codex, failed)]))
        XCTAssertNil(failedResult.windows)
        XCTAssertEqual(failedResult.error, "credentialExpired")
    }

    func testEstimatorUsesBridgedOfficialWindows() throws {
        let store = try UsageStore(path: ":memory:")
        let snapshot = SubscriptionSnapshot(status: .current, windows: [
            SubscriptionWindow(id: "rolling", duration: 18_000, usedPercent: 42),
            SubscriptionWindow(id: "weekly", duration: 604_800, usedPercent: 7),
            SubscriptionWindow(id: "monthly", duration: 2_592_000, usedPercent: 3),
        ], plan: "OpenCode Go", sampledAt: Date())
        let cards = [card(.go, snapshot)]
        let entries = try QuotaEstimator.compute(store: store, config: .default, nowMs: store.nowMs()) {
            SubscriptionQuotaBridge.officialResult($0, cards: cards)
        }
        let go = try XCTUnwrap(entries.first { $0.id == "go" })
        XCTAssertEqual(go.source, "official")
        XCTAssertEqual(go.windows.first { $0.key == "5h" }?.pct, 42)
        let claude = try XCTUnwrap(entries.first { $0.id == "claude" })
        XCTAssertEqual(claude.source, "local", "没有账号库账号时用本地估算，不读取 Claude Code 登录态")
    }
}
