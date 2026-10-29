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
            let model = UsageHeatmapModel(path: "/tmp/unused-heatmap-size-test.db")
            let host = NSHostingView(rootView: UsageHeatmapView(model: model, yi: false).frame(width: width))
            XCTAssertTrue(host.fittingSize.height.isFinite)
            XCTAssertGreaterThan(host.fittingSize.height, 180)
        }
    }
    func testPeriodBoundariesAndAdaptiveAllHistory() throws {
        let now = date(2026, 10, 29)
        let empty = HeatmapDataset(rows: [], calendar: calendar)
        let expected: [(HeatmapPeriod, Int)] = [(.day, 13), (.week, 4), (.month, 29), (.year, 302)]
        for (period, count) in expected {
            let chart = UsageHeatmap(dataset: empty, request: HeatmapRequest(period: period, anchor: now), now: now, calendar: calendar)
            XCTAssertEqual(chart.cells.compactMap { $0 }.count, count, "\(period)")
            XCTAssertLessThanOrEqual(chart.cells.count, 378)
        }
        let custom = HeatmapRequest(period: .custom, anchor: now, start: date(2024, 2, 28), end: date(2024, 3, 1))
        let chart = UsageHeatmap(dataset: empty, request: custom, now: now, calendar: calendar)
        XCTAssertEqual(chart.cells.compactMap { $0 }.count, 3) // Both endpoints, leap day included.
        XCTAssertEqual(calendar.component(.day, from: chart.end), 2)
        let long = HeatmapRequest(period: .custom, anchor: now, start: date(2010, 1, 1), end: now)
        let all = UsageHeatmap(dataset: empty, request: long, now: now, calendar: calendar)
        XCTAssertEqual(all.unit, .month)
        XCTAssertLessThanOrEqual(all.cells.count, 372)
        let veryLong = UsageHeatmap(dataset: empty,
            request: HeatmapRequest(period: .custom, anchor: now, start: date(1900, 1, 1), end: now),
            now: now, calendar: calendar)
        XCTAssertEqual(veryLong.unit, .year(1))
        XCTAssertLessThanOrEqual(veryLong.cells.count, 372)
    }

    func testHourBucketsPreserveDSTAndDoNotSpreadIntervals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UsageStore(path: directory.appendingPathComponent("usage.db").path)
        let day = date(2024, 11, 3)
        let midnight = calendar.startOfDay(for: day)
        let first = Int64(midnight.addingTimeInterval(90 * 60).timeIntervalSince1970 * 1000)
        let second = first + 3_600_000 // Two 01:30s, distinct absolute hours.
        try store.putEvent(tool: "codex", srcKey: "first-0130", ts: first, input: 10, output: 20, cacheRead: 30, cacheWrite: 40)
        try store.putEvent(tool: "other", srcKey: "second-0130", ts: second, input: 50)
        try store.putEvent(tool: "other", srcKey: "cross-hour", ts: second, input: 200,
                           timeQuality: "observed", intervalStart: first)
        let rows = try store.heatmapHours(on: day, calendar: calendar)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.day)).count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.stats.tokens }, 150)
        let fall = UsageHeatmap(dataset: HeatmapDataset(rows: [], calendar: calendar),
            request: HeatmapRequest(period: .day, anchor: day), hours: rows,
            now: date(2026, 10, 29), calendar: calendar)
        XCTAssertEqual(fall.cells.compactMap { $0 }.count, 25)
        XCTAssertEqual(fall.totalTokens, 150)
        let spring = UsageHeatmap(dataset: HeatmapDataset(rows: [], calendar: calendar),
            request: HeatmapRequest(period: .day, anchor: date(2024, 3, 10)),
            now: date(2026, 10, 29), calendar: calendar)
        XCTAssertEqual(spring.cells.compactMap { $0 }.count, 23)
    }

    @MainActor
    func testPointerHotPathKeepsSnapshotAndAvoidsAggregation() {
        let chart = UsageHeatmap(rows: [], year: 2026, now: date(2026, 12, 31), calendar: calendar)
        let canvas = HeatmapCanvasView(frame: NSRect(x: 0, y: 0, width: 560, height: 140))
        canvas.update(chart, locale: Locale(identifier: "zh-Hans"))
        let layout = HeatmapGridLayout(chart: chart, width: 560)
        let indices = chart.cells.indices.filter { chart.cells[$0] != nil }
        let begin = Date()
        for index in indices {
            let rect = layout.rect(index)
            XCTAssertEqual(layout.index(at: NSPoint(x: rect.midX, y: rect.midY)), index)
        }
        for n in 0..<500 {
            let rect = layout.rect(indices[n % indices.count])
            canvas.focus(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        let seconds = Date().timeIntervalSince(begin)
        print("Heatmap: 500 pointer updates = \(seconds)s")
        XCTAssertLessThan(seconds, 3) // Old aggregation alone took ~15 s for 500 updates on 26k rows.
        XCTAssertEqual(canvas.chart?.id, chart.id)
        XCTAssertNil(layout.index(at: NSPoint(x: -1, y: -1)))
    }

    func testAllAndCustomPreserveTotalsAcrossAdaptiveBuckets() {
        func row(_ day: String, _ tool: String, _ tokens: Int64) -> UsageStore.DailyRow {
            var stats = UsageStore.ToolStats(); stats.tokens = tokens; stats.input = tokens
            return UsageStore.DailyRow(tool: tool, day: day, stats: stats)
        }
        let rows = [row("1990-01-01", "codex", 100), row("2026-10-29", "unknown-agent", 250),
                    row("2026-10-29", "codex", 30), row("2027-01-01", "codex", 999)]
        let data = HeatmapDataset(rows: rows, excludedTokens: 42, calendar: calendar)
        let now = date(2026, 10, 29)
        let all = UsageHeatmap(dataset: data, request: HeatmapRequest(period: .all), now: now, calendar: calendar)
        XCTAssertEqual(all.unit, .year(1))
        XCTAssertEqual(all.totalTokens, 380)
        XCTAssertEqual(all.activeDays, 2)
        XCTAssertEqual(all.excludedTokens, 42)
        XCTAssertEqual(all.cells.compactMap { $0 }.flatMap(\.agents).reduce(0) { $0 + $1.tokens }, 380)
        let custom = UsageHeatmap(dataset: data,
            request: HeatmapRequest(period: .custom, start: now, end: now), now: now, calendar: calendar)
        XCTAssertEqual(custom.totalTokens, 280)
        XCTAssertEqual(custom.activeDays, 1)
        XCTAssertEqual(custom.cells.compactMap { $0 }.first?.agents.map(\.tool), ["unknown-agent", "codex"])
    }

    func testRangeLabelsUsePeriodMeaningInBothLanguages() {
        let previous = L10n.language
        defer { L10n.setLanguage(previous) }
        L10n.setLanguage("en")
        XCTAssertEqual(HeatmapPeriod.allCases.map { L10n.text($0.title) }, ["Day", "Week", "Month", "Year", "Custom", "All"])
        L10n.setLanguage("zh-Hans")
        XCTAssertEqual(HeatmapPeriod.allCases.map { L10n.text($0.title) }, ["日", "周", "月", "年", "自选", "全部"])
    }

}
