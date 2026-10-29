import Combine
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
        XCTAssertEqual(state.heatmapRows.reduce(Int64(0)) { $0 + $1.stats.tokens }, 30)

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
}
