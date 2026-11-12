import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class OverviewRefreshTests: XCTestCase {
    func testRangeChangeRefreshesStatisticsAndInsightsWithoutViewObserver() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = ["TT_UI_PREVIEW", "TOKENTRACKER_SETTINGS", "TOKENTRACKER_PRICES"]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        setenv(keys[0], "1", 1)
        setenv(keys[1], directory.appendingPathComponent("settings.json").path, 1)
        setenv(keys[2], directory.appendingPathComponent("prices.json").path, 1)
        let state = AppState(dbPath: directory.appendingPathComponent("usage.db").path)
        for (key, value) in zip(keys, previous) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        try state.readStore.putEvent(tool: "codex", srcKey: "today", ts: Int64(now.timeIntervalSince1970 * 1000), input: 10)
        try state.readStore.putEvent(tool: "dsh", srcKey: "yesterday", ts: Int64(yesterday.timeIntervalSince1970 * 1000), input: 20)

        let day = expectation(description: "Today statistics refreshed after changing the selected range")
        var subscription = state.$updatedAt.dropFirst().sink { _ in
            if state.statTotal.tokens == 10 { day.fulfill() }
        }
        state.range = "day"
        XCTAssertEqual(state.insights.query.start, UsageQuery.period("day").start)
        await fulfillment(of: [day], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(state.loadedRange, "day")
        XCTAssertFalse(state.dataLoading)


        let latest = expectation(description: "Rapid changes publish only the final range")
        subscription = state.$updatedAt.dropFirst().sink { _ in
            XCTAssertEqual(state.statTotal.tokens, 30)
            latest.fulfill()
        }
        state.range = "all"
        state.range = "day"
        state.range = "week"
        await fulfillment(of: [latest], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(state.insights.query.start, UsageQuery.period("week").start)
    }

    func testHourBucketsSumToolsPerHourAndIgnoreMalformedLabels() {
        func row(_ tool: String, _ label: String, _ input: Int64) -> UsageStore.DailyRow {
            var stats = UsageStore.ToolStats()
            stats.input = input
            stats.tokens = input
            return UsageStore.DailyRow(tool: tool, day: label, stats: stats)
        }
        let hours = AppState.hourBuckets([row("codex", "09:00", 10), row("dsh", "09:00", 5),
                                          row("codex", "23:00", 7), row("codex", "2026-11-12", 99),
                                          row("codex", "24:00", 99)])
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[9], 15)
        XCTAssertEqual(hours[23], 7)
        XCTAssertEqual(hours.reduce(0, +), 22)
    }

    func testMenuBarPanelHasFiniteSizeWithAndWithoutData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = ["TT_UI_PREVIEW", "TOKENTRACKER_SETTINGS", "TOKENTRACKER_PRICES"]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        setenv(keys[0], "1", 1)
        setenv(keys[1], directory.appendingPathComponent("settings.json").path, 1)
        setenv(keys[2], directory.appendingPathComponent("prices.json").path, 1)
        let state = AppState(dbPath: directory.appendingPathComponent("usage.db").path)
        for (key, value) in zip(keys, previous) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        // 预览模式自带虚构订阅卡片；再清空一次覆盖「什么都没有」的面板
        for cards in [state.subscriptionCards, []] {
            state.subscriptionCards = cards
            let view = NSHostingView(rootView: MenuBarPanelView(state: state, actions: MenuBarPanelActions()))
            let size = view.fittingSize
            XCTAssertEqual(size.width, MenuBarPanelView.width, accuracy: 0.5)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThan(size.height, 100)
            XCTAssertLessThan(size.height, 760)
        }
    }
}
