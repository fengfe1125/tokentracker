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
    func testRangesMatchOverviewBoundsInAnnualLayout() {
        let now = date(2026, 10, 29) // Thursday
        let empty = HeatmapDataset(rows: [], calendar: calendar)
        let expected: [(String, Int, Int)] = [("day", 1, 1), ("week", 7, 2), ("month", 29, 5), ("all", 302, 53)]
        for (range, days, columns) in expected {
            let chart = UsageHeatmap(dataset: empty, request: HeatmapRequest(range: range), now: now, calendar: calendar)
            XCTAssertEqual(chart.cells.compactMap { $0 }.count, days, range)
            XCTAssertEqual(chart.bands.count, 1, range)
            XCTAssertEqual(chart.columns, columns, range)
            XCTAssertTrue(chart.weeks.allSatisfy { $0.count == 7 }, range)
        }
        let week = UsageHeatmap(dataset: empty, request: HeatmapRequest(range: "week"), now: date(2026, 1, 2), calendar: calendar)
        XCTAssertEqual(week.bands.count, 1, "Short ranges stay one block across New Year")
        XCTAssertEqual(week.cells.compactMap { $0 }.count, 7)
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

    func testAllHistoryStacksCalendarYearsAndKeepsTotals() {
        func row(_ day: String, _ tool: String, _ tokens: Int64) -> UsageStore.DailyRow {
            var stats = UsageStore.ToolStats(); stats.tokens = tokens; stats.input = tokens
            return UsageStore.DailyRow(tool: tool, day: day, stats: stats)
        }
        let rows = [row("2024-12-31", "codex", 100), row("2026-10-29", "unknown-agent", 250),
                    row("2026-10-29", "codex", 30), row("2027-01-01", "codex", 999)]
        let data = HeatmapDataset(rows: rows, excludedTokens: 42, calendar: calendar)
        let now = date(2026, 10, 29)
        let all = UsageHeatmap(dataset: data, request: HeatmapRequest(range: "all"), now: now, calendar: calendar)
        XCTAssertEqual(all.bands.map(\.year), [2024, 2025, 2026])
        XCTAssertEqual(all.bands.map(\.firstColumn), [0, all.bands[0].columns, all.bands[0].columns + all.bands[1].columns])
        XCTAssertEqual(all.totalTokens, 380)
        XCTAssertEqual(all.activeDays, 2)
        XCTAssertEqual(all.excludedTokens, 42)
        XCTAssertEqual(all.cells.compactMap { $0 }.count, 366 + 365 + 302)
        XCTAssertEqual(all.cells.compactMap { $0 }.flatMap(\.agents).reduce(0) { $0 + $1.tokens }, 380)
        let layout = HeatmapGridLayout(chart: all, width: 700)
        for index in all.cells.indices where all.cells[index] != nil {
            let rect = layout.rect(index)
            XCTAssertEqual(layout.index(at: NSPoint(x: rect.midX, y: rect.midY)), index)
        }
        XCTAssertGreaterThan(layout.rect(all.cells.count - 1).minY, layout.rect(0).maxY + 7 * 3)
        let week = UsageHeatmap(dataset: data, request: HeatmapRequest(range: "week"), now: now, calendar: calendar)
        XCTAssertEqual(week.totalTokens, 280)
        XCTAssertEqual(week.activeDays, 1)
        XCTAssertEqual(week.cells.compactMap { $0 }.first { $0.tokens > 0 }?.agents.map(\.tool), ["unknown-agent", "codex"])
    }
}
