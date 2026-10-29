import AppKit
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

final class UsageHeatmapTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testLeapYearAndDSTKeepEveryLocalDayExactlyOnce() {
        let map = UsageHeatmap(rows: [], year: 2024, now: date(2024, 12, 31), calendar: calendar)
        let days = map.weeks.flatMap { $0 }.compactMap { $0 }
        XCTAssertEqual(days.count, 366)
        XCTAssertEqual(Set(days.map(\.date)).count, 366)
        XCTAssertEqual(days.filter { calendar.component(.month, from: $0.date) == 2 }.count, 29)
        XCTAssertTrue(map.weeks.allSatisfy { $0.count == 7 })
        let future = UsageHeatmap(rows: [], year: 2026, now: date(2026, 1, 2), calendar: calendar)
        XCTAssertEqual(future.weeks.flatMap { $0 }.compactMap { $0 }.count, 2)
        XCTAssertNil(future.weeks.first?.first!) // Jan 1, 2026 is Thursday.
    }

    func testAllAgentsAndCacheTokensRespectExistingDailyTimeQuality() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UsageStore(path: directory.appendingPathComponent("usage.db").path)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let midnight = Calendar.current.startOfDay(for: yesterday)
        let ts = Int64(midnight.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        try store.putEvent(tool: "codex", srcKey: "exact", ts: ts, input: 10, output: 20, cacheRead: 30, cacheWrite: 40)
        try store.putEvent(tool: "unlisted-agent", srcKey: "observed", ts: ts, input: 50,
                           timeQuality: "observed", intervalStart: ts - 1000)
        try store.putEvent(tool: "dsh", srcKey: "cross-day", ts: ts, input: 200,
                           timeQuality: "observed", intervalStart: ts - 7_200_000)
        try store.putEvent(tool: "pi", srcKey: "undated", ts: ts, input: 300, timeQuality: "unallocated")
        let rows = try store.daily(rangeKey: "all")
        let map = UsageHeatmap(rows: rows, year: Calendar.current.component(.year, from: yesterday))
        XCTAssertEqual(map.totalTokens, 150)
        XCTAssertEqual(map.activeDays, 1)
        let day = try XCTUnwrap(map.weeks.flatMap { $0 }.compactMap { $0 }.first { $0.tokens > 0 })
        XCTAssertEqual(day.agents.map(\.tool), ["codex", "unlisted-agent"])
        XCTAssertEqual(day.estimatedTokens, 50)
        XCTAssertEqual(try store.stats().total.tokens - map.totalTokens, 500)
        XCTAssertEqual(map.level(for: 0), 0)
        XCTAssertEqual(map.level(for: 150), 4)
    }

    @MainActor
    func testNativeHeatmapHasFiniteSizeAtMinimumWindowWidth() {
        for width: CGFloat in [560, 700] {
            let host = NSHostingView(rootView: UsageHeatmapView(rows: [], excludedTokens: 42,
                loading: false, error: nil, yi: false).frame(width: width))
            XCTAssertTrue(host.fittingSize.height.isFinite)
            XCTAssertGreaterThan(host.fittingSize.height, 180)
        }
    }
}
