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
    func testShortRangesUseHourGridAndAllUsesTrimmedYear() {
        func row(_ day: String, _ tokens: Int64) -> UsageStore.DailyRow {
            var stats = UsageStore.ToolStats(); stats.tokens = tokens; stats.input = tokens
            return UsageStore.DailyRow(tool: "codex", day: day, stats: stats)
        }
        func hour(_ day: Int, _ hour: Int, _ tokens: Int64) -> UsageStore.DailyRow {
            let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
            var stats = UsageStore.ToolStats(); stats.tokens = tokens; stats.input = tokens
            return UsageStore.DailyRow(tool: "codex", day: String(Int64(start.timeIntervalSince1970 * 1000)), stats: stats)
        }
        let now = date(2026, 10, 29) // Thursday 12:00
        let data = HeatmapDataset(rows: [row("2026-08-03", 900), row("2026-10-27", 20), row("2026-10-29", 15)], calendar: calendar)
        let hours = [hour(27, 9, 20), hour(29, 8, 6), hour(29, 11, 4)]
        let expected: [(String, Int, Int, Int64, Int)] = [("day", 1, 13, 10, 2), ("week", 7, 6 * 24 + 13, 30, 3), ("month", 29, 28 * 24 + 13, 30, 3)]
        for (range, rows, elapsed, total, active) in expected {
            let chart = UsageHeatmap(dataset: data, request: HeatmapRequest(range: range), hours: hours, now: now, calendar: calendar)
            XCTAssertEqual(chart.unit, .hour, range)
            XCTAssertEqual(chart.rowDays.count, rows, range)
            XCTAssertEqual(chart.cells.count, rows * 24, range)
            XCTAssertEqual(chart.elapsedHours, elapsed, range)
            XCTAssertEqual(chart.cells.compactMap { $0 }.count, elapsed, "\(range): future hours stay blank")
            XCTAssertEqual(chart.totalTokens, total, range)
            XCTAssertEqual(chart.activeHours, active, range)
            XCTAssertEqual(chart.peak?.tokens, range == "day" ? 6 : 20, range)
            XCTAssertEqual(chart.hourlyExcludedTokens, 5, "\(range): 15 day tokens, 10 placed in hours")
            let layout = HeatmapGridLayout(chart: chart, width: 700)
            XCTAssertEqual(layout.rect(23).maxX, 700, accuracy: 0.5, "\(range): columns span the width")
            for index in chart.cells.indices where chart.cells[index] != nil {
                let rect = layout.rect(index)
                XCTAssertEqual(layout.index(at: NSPoint(x: rect.midX, y: rect.midY)), index, range)
            }
        }
        let all = UsageHeatmap(dataset: data, request: HeatmapRequest(range: "all"), now: now, calendar: calendar)
        XCTAssertEqual(all.unit, .day)
        XCTAssertEqual(all.bands.map(\.year), [2026])
        XCTAssertEqual(all.cells.compactMap { $0 }.count, 302, "The year ends at today; no future placeholders")
        XCTAssertEqual(all.columns, 44)
        XCTAssertEqual(all.totalTokens, 935)
        XCTAssertEqual(all.rangeDays, 88)
        XCTAssertEqual(all.cells.compactMap { $0 }.filter(all.contains).count, 88, "Days before the first usage are context only")
        let layout = HeatmapGridLayout(chart: all, width: 700)
        XCTAssertEqual(layout.rect(all.cells.count - 1).maxX, 700, accuracy: 0.5)
    }

    func testHourBucketsPreserveDSTAndDoNotSpreadIntervals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UsageStore(path: directory.appendingPathComponent("usage.db").path)
        let midnight = calendar.startOfDay(for: date(2024, 11, 3))
        let first = Int64(midnight.addingTimeInterval(90 * 60).timeIntervalSince1970 * 1000)
        let second = first + 3_600_000 // Two 01:30s, distinct absolute hours.
        try store.putEvent(tool: "codex", srcKey: "first-0130", ts: first, input: 10, output: 20, cacheRead: 30, cacheWrite: 40)
        try store.putEvent(tool: "other", srcKey: "second-0130", ts: second, input: 50)
        try store.putEvent(tool: "other", srcKey: "cross-hour", ts: second, input: 200,
                           timeQuality: "observed", intervalStart: first)
        let next = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let rows = try store.heatmapHours(from: midnight, to: next, calendar: calendar)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.day)).count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.stats.tokens }, 150)
        let dataset = HeatmapDataset(rows: try store.daily(rangeKey: "all"), calendar: calendar)
        let fall = UsageHeatmap(dataset: dataset, request: HeatmapRequest(range: "day"), hours: rows,
                                now: midnight.addingTimeInterval(24.5 * 3600), calendar: calendar) // 23:30 on a 25-hour day
        XCTAssertEqual(fall.cells.compactMap { $0 }.count, 24, "The repeated 01:00 hour shares one column")
        XCTAssertEqual(fall.cells[1]?.tokens, 150)
        XCTAssertEqual(fall.elapsedHours, 25)
        XCTAssertEqual(fall.hourlyExcludedTokens, 200)
        let spring = calendar.startOfDay(for: date(2024, 3, 10))
        let skipped = UsageHeatmap(dataset: dataset, request: HeatmapRequest(range: "day"), hours: [],
                                   now: spring.addingTimeInterval(22.5 * 3600), calendar: calendar)
        XCTAssertNil(skipped.cells[2], "The skipped 02:00 hour stays blank")
        XCTAssertEqual(skipped.cells.compactMap { $0 }.count, 23)
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
        XCTAssertEqual(week.activeDays, 1)
        XCTAssertEqual(week.hourlyExcludedTokens, 280, "Day-only rows are reported, not spread across hours")
    }
}
