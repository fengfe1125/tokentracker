import XCTest
import SwiftUI
import AppKit
@testable import TokenTrackerCore
@testable import TokenTrackerApp

final class TrendChartTests: XCTestCase {
    @MainActor
    func testSubscriptionCardsHandleUnboundedHostMeasurement() async {
        // 账号页的额度区：AppKit 创建窗口时会用无限宽度来量，结果必须有限
        for card in SubscriptionCard.previewCards() {
            let view = NSHostingView(rootView: AccountQuotaView(card: card))
            let size = view.fittingSize
            XCTAssertTrue(size.width.isFinite, card.id)
            XCTAssertTrue(size.height.isFinite, card.id)
            XCTAssertGreaterThan(size.width, 0, card.id)
            XCTAssertGreaterThan(size.height, 0, card.id)
        }
    }

    func testAxisCeilingCoversMaximumAndSplitsIntoFourEvenTicks() {
        for value in [0.0004, 0.9, 1, 37, 118_000_000, 126_400_000, 999, 1000] {
            let top = TrendScale.niceCeiling(value)
            XCTAssertGreaterThanOrEqual(top, value)
            XCTAssertLessThanOrEqual(top, value * 1.6 + 1e-12, "\(value)")
            XCTAssertEqual(TrendScale.ticks(top: top).count, 5)
            XCTAssertEqual(TrendScale.ticks(top: top).last, top)
        }
        XCTAssertEqual(TrendScale.niceCeiling(0), 1)
        XCTAssertEqual(TrendScale.niceCeiling(118_000_000), 120_000_000)
    }

    func testAxisLabelsFollowLanguageAndUnitSetting() {
        let previous = L10n.language
        defer { L10n.setLanguage(previous) }
        L10n.setLanguage("zh-Hans")
        XCTAssertEqual(TrendScale.tokenLabel(120_000_000, yi: true), "1.2亿")
        XCTAssertEqual(TrendScale.tokenLabel(90_000_000, yi: true), "9000万")
        XCTAssertEqual(TrendScale.tokenLabel(90_000_000, yi: false), "90M")
        XCTAssertEqual(TrendScale.tokenLabel(0, yi: true), "0")
        L10n.setLanguage("en")
        XCTAssertEqual(TrendScale.tokenLabel(120_000_000, yi: true), "120M")
        XCTAssertEqual(TrendScale.tokenLabel(1_500, yi: false), "1.5K")
        XCTAssertEqual(TrendScale.costLabel(0), "$0")
        XCTAssertEqual(TrendScale.costLabel(0.3), "$0.3")
        XCTAssertEqual(TrendScale.costLabel(300), "$300")
    }

    func testTodayDaySlotsAlwaysProduces24HoursAndMarksCurrentAndFuture() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 0, minute: 12))!
        let active = [
            TrendPoint(id: "00:00", day: "00:00", input: 100, output: 50, cacheRead: 800, cacheWrite: 50, cost: 1.25)
        ]
        let slots = TodayTrendBuilder.daySlots(from: active, now: now, calendar: calendar)
        XCTAssertEqual(slots.count, 24)
        XCTAssertEqual(slots[0].id, "00:00")
        XCTAssertEqual(slots[0].tokens, 1000)
        XCTAssertEqual(slots[0].cost, 1.25)
        XCTAssertTrue(slots[0].isCurrent)
        XCTAssertFalse(slots[0].isFuture)
        XCTAssertTrue(slots[1].isFuture)
        XCTAssertFalse(slots[1].isCurrent)
        XCTAssertEqual(slots[23].id, "23:00")
        XCTAssertTrue(slots[23].isFuture)
        XCTAssertEqual(TodayTrendBuilder.currentTimeLabel(now: now, calendar: calendar), "00:12")
    }

    func testPulsePanelActivatesOnlyForOneOrTwoActiveHours() {
        func pt(_ id: String, tokens: Double) -> TrendPoint {
            TrendPoint(id: id, day: id, input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0)
        }
        XCTAssertFalse(TodayTrendBuilder.shouldUsePulsePanel(activeHourPoints: []))
        XCTAssertFalse(TodayTrendBuilder.shouldUsePulsePanel(activeHourPoints: [pt("00:00", tokens: 0)]))
        XCTAssertTrue(TodayTrendBuilder.shouldUsePulsePanel(activeHourPoints: [pt("00:00", tokens: 120)]))
        XCTAssertTrue(TodayTrendBuilder.shouldUsePulsePanel(activeHourPoints: [
            pt("00:00", tokens: 120), pt("09:00", tokens: 80)
        ]))
        XCTAssertFalse(TodayTrendBuilder.shouldUsePulsePanel(activeHourPoints: [
            pt("00:00", tokens: 120), pt("09:00", tokens: 80), pt("10:00", tokens: 50)
        ]))
    }

    func testYesterdayDeltaPercentAvoidsFabricatingWhenBaselineMissing() {
        XCTAssertNil(TodayTrendBuilder.yesterdayDeltaPercent(todayTokens: 500, yesterdaySameTimeTokens: nil))
        XCTAssertNil(TodayTrendBuilder.yesterdayDeltaPercent(todayTokens: 500, yesterdaySameTimeTokens: 0))
        XCTAssertEqual(TodayTrendBuilder.yesterdayDeltaPercent(todayTokens: 123, yesterdaySameTimeTokens: 100), 23)
        XCTAssertEqual(TodayTrendBuilder.yesterdayDeltaPercent(todayTokens: 82, yesterdaySameTimeTokens: 100), -18)
        XCTAssertEqual(TodayTrendBuilder.yesterdayDeltaPercent(todayTokens: 100, yesterdaySameTimeTokens: 100), 0)
        XCTAssertEqual(TodayTrendBuilder.signedPercentText(23), "+23%")
        XCTAssertEqual(TodayTrendBuilder.signedPercentText(-18), "-18%")
        XCTAssertEqual(TodayTrendBuilder.signedPercentText(0), "0%")
        XCTAssertEqual(TodayTrendBuilder.hourRangeLabel("00:00"), "00:00–01:00")
        XCTAssertEqual(TodayTrendBuilder.hourRangeLabel("23:00"), "23:00–00:00")
        XCTAssertEqual(TodayPulseView.compactTodayTimeRange("2026-11-22 00:01 → 00:12", todayPrefix: "2026-11-22"),
                       "00:01 → 00:12")
    }

    func testYesterdaySameTimeTokensCountsOnlyUpToElapsedCutoffAndRespectsToolFilter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9, minute: 30, second: 0))!
        let store = try UsageStore(path: ":memory:")
        store.nowMs = { Int64(now.timeIntervalSince1970 * 1000) }

        func ms(_ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
            let d = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
            return Int64(d.timeIntervalSince1970 * 1000)
        }

        // 前天（排除）
        try store.putEvent(tool: "claude", srcKey: "d20", ts: ms(20, 8, 0), input: 1000)
        // 昨天 08:00（计入）
        try store.putEvent(tool: "claude", srcKey: "d21-a", ts: ms(21, 8, 0), input: 100, cacheRead: 200)
        // 昨天 09:20（计入，另一工具）
        try store.putEvent(tool: "codex", srcKey: "d21-b", ts: ms(21, 9, 20), input: 50, output: 25)
        // 昨天 10:00（晚于昨日同刻 09:30，排除）
        try store.putEvent(tool: "claude", srcKey: "d21-late", ts: ms(21, 10, 0), input: 999)
        // 昨天跨零点 observed（interval_start 在前天，排除）
        try store.putEvent(tool: "claude", srcKey: "d21-obs", ts: ms(21, 1, 0), input: 500,
                           timeQuality: "observed", intervalStart: ms(20, 23, 0))
        // 今天 00:10（排除）
        try store.putEvent(tool: "claude", srcKey: "d22", ts: ms(22, 0, 10), input: 777)

        XCTAssertEqual(try store.yesterdaySameTimeTokens(tool: nil, calendar: calendar), 375)
        XCTAssertEqual(try store.yesterdaySameTimeTokens(tool: "claude", calendar: calendar), 300)
        XCTAssertEqual(try store.yesterdaySameTimeTokens(tool: "codex", calendar: calendar), 75)
        XCTAssertEqual(try store.yesterdaySameTimeTokens(tool: "kimi", calendar: calendar), 0)
    }

    @MainActor
    func testTodayPulseViewAndFixed24hTrendChartHaveFiniteSizes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 0, minute: 12))!
        let active = [
            TrendPoint(id: "00:00", day: "00:00", input: 1_700_000, output: 1_100_000,
                       cacheRead: 33_200_000, cacheWrite: 2_400_000, cost: 2.84)
        ]
        let slots = TodayTrendBuilder.daySlots(from: active, now: now, calendar: calendar)
        var total = UsageStore.ToolStats()
        total.input = 1_700_000; total.output = 1_100_000
        total.cacheRead = 33_200_000; total.cacheWrite = 2_400_000
        total.tokens = 38_400_000; total.cost = 2.84; total.events = 46; total.sessions = 3

        let sessionRow = UsageStore.SessionRow(
            tool: "claude", sessionID: "s1", project: "/tmp/TokenTracker",
            workspacePath: "/tmp/TokenTracker", lastSeen: "2026-11-22 00:12:00",
            firstTs: Int64(now.timeIntervalSince1970 * 1000) - 600_000,
            ts: Int64(now.timeIntervalSince1970 * 1000),
            model: "claude-opus-4-6", title: "概览图表交互重构", stats: total
        )

        let pulseHost = NSHostingView(rootView: TodayPulseView(
            daySlots: slots,
            activePoints: active,
            total: total,
            yesterdaySameTimeTokens: 31_200_000,
            sessions: [SessionRowModel(row: sessionRow)],
            yi: true,
            onSwitchToBarChart: {},
            onSelectSession: { _ in }
        ).frame(width: 640))
        XCTAssertTrue(pulseHost.fittingSize.width.isFinite)
        XCTAssertTrue(pulseHost.fittingSize.height.isFinite)
        XCTAssertGreaterThan(pulseHost.fittingSize.height, 180)

        let chartHost = NSHostingView(rootView: TrendChart(
            points: slots, isHourly: true, yi: true, currentTimeLabel: "00:12"
        ).frame(width: 640))
        XCTAssertTrue(chartHost.fittingSize.width.isFinite)
        XCTAssertTrue(chartHost.fittingSize.height.isFinite)
        XCTAssertEqual(chartHost.fittingSize.height, 220, accuracy: 2)
    }
}
