import AppKit
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class ScrollPerformanceTests: XCTestCase {
    override func tearDown() {
        ScrollActivity.shared.setScrollingForTesting(nil)
        super.tearDown()
    }

    func testScrollActivityClearsRegisteredHoversOnScrollStart() {
        let activity = ScrollActivity.shared
        activity.setScrollingForTesting(false)
        XCTAssertFalse(activity.isScrolling)

        var clearedCount = 0
        let box = HoverTokenBox()
        box.setActive(true) { clearedCount += 1 }

        activity.setScrollingForTesting(true)
        XCTAssertTrue(activity.isScrolling)
        XCTAssertEqual(clearedCount, 1)

        // 再次保持滚动状态不应重复触发已清理的回调
        activity.setScrollingForTesting(true)
        XCTAssertEqual(clearedCount, 1)

        // 手动反注册后滚动不应再触发
        activity.setScrollingForTesting(false)
        box.setActive(true) { clearedCount += 1 }
        box.unregister()
        activity.setScrollingForTesting(true)
        XCTAssertEqual(clearedCount, 1)
    }

    func testAdaptiveLayoutsSwitchBetweenHorizontalAndVerticalWithFiniteSizes() {
        let splitWide = NSHostingView(rootView: AdaptiveSplitLayout(
            minLeadingWidth: 480, trailingWidth: 300, spacing: 12
        ) {
            Color.red.frame(height: 120)
            Color.blue.frame(height: 80)
        }.frame(width: 900))
        XCTAssertEqual(splitWide.fittingSize.height, 120, accuracy: 1)

        let splitNarrow = NSHostingView(rootView: AdaptiveSplitLayout(
            minLeadingWidth: 480, trailingWidth: 300, spacing: 12
        ) {
            Color.red.frame(height: 120)
            Color.blue.frame(height: 80)
        }.frame(width: 600))
        XCTAssertEqual(splitNarrow.fittingSize.height, 212, accuracy: 1)

        let splitUnbounded = NSHostingView(rootView: AdaptiveSplitLayout(
            minLeadingWidth: 480, trailingWidth: 300, spacing: 12
        ) {
            Color.red.frame(height: 100)
            Color.blue.frame(height: 60)
        })
        XCTAssertTrue(splitUnbounded.fittingSize.width.isFinite)
        XCTAssertTrue(splitUnbounded.fittingSize.height.isFinite)
        XCTAssertEqual(splitUnbounded.fittingSize.height, 100, accuracy: 1)

        let equalWide = NSHostingView(rootView: AdaptiveEqualColumnsLayout(
            minColumnWidth: 300, spacing: 16, equalHeight: true
        ) {
            Color.red.frame(height: 140)
            Color.blue.frame(height: 90)
        }.frame(width: 800))
        XCTAssertEqual(equalWide.fittingSize.height, 140, accuracy: 1)

        let equalNarrow = NSHostingView(rootView: AdaptiveEqualColumnsLayout(
            minColumnWidth: 300, spacing: 16, equalHeight: true
        ) {
            Color.red.frame(height: 140)
            Color.blue.frame(height: 90)
        }.frame(width: 500))
        XCTAssertEqual(equalNarrow.fittingSize.height, 246, accuracy: 1)

        let tilesWide = NSHostingView(rootView: AdaptiveTileGridLayout(
            maxColumns: 4, fallbackColumns: 2, minColumnWidth: 118, spacing: 12
        ) {
            Color.red.frame(height: 70)
            Color.green.frame(height: 80)
            Color.blue.frame(height: 65)
            Color.orange.frame(height: 75)
        }.frame(width: 600))
        XCTAssertEqual(tilesWide.fittingSize.height, 80, accuracy: 1)

        let tilesNarrow = NSHostingView(rootView: AdaptiveTileGridLayout(
            maxColumns: 4, fallbackColumns: 2, minColumnWidth: 118, spacing: 12
        ) {
            Color.red.frame(height: 70)
            Color.green.frame(height: 80)
            Color.blue.frame(height: 65)
            Color.orange.frame(height: 75)
        }.frame(width: 400))
        XCTAssertEqual(tilesNarrow.fittingSize.height, 80 + 12 + 75, accuracy: 1)

        let dividedWide = NSHostingView(rootView: AdaptiveDividedPairLayout(
            minFirstWidth: 260, minSecondWidth: 320, horizontalSpacing: 20, verticalSpacing: 14
        ) {
            Color.red.frame(height: 100)
            Divider().frame(height: 112)
            Color.blue.frame(height: 90)
        }.frame(width: 760))
        XCTAssertEqual(dividedWide.fittingSize.height, 112, accuracy: 1)

        let dividedNarrow = NSHostingView(rootView: AdaptiveDividedPairLayout(
            minFirstWidth: 260, minSecondWidth: 320, horizontalSpacing: 20, verticalSpacing: 14
        ) {
            Color.red.frame(height: 100)
            Divider().frame(height: 112)
            Color.blue.frame(height: 90)
        }.frame(width: 500))
        XCTAssertEqual(dividedNarrow.fittingSize.height, 204, accuracy: 1)
    }

    func testMeterBarAndSegmentedBarHaveFiniteDimensions() {
        for fraction in [-0.2, 0.0, 0.001, 0.5, 1.0, 1.5] {
            let host = NSHostingView(rootView: MeterBar(fraction: fraction, tint: .blue, height: 4).frame(width: 200))
            XCTAssertEqual(host.fittingSize.height, 4, accuracy: 0.5)
        }
        let segHost = NSHostingView(rootView: SegmentedBar(segments: [
            SegmentedBarSegment(value: 70, color: .indigo),
            SegmentedBarSegment(value: 20, color: .blue),
            SegmentedBarSegment(value: 10, color: .green),
        ], height: 10).frame(width: 240))
        XCTAssertEqual(segHost.fittingSize.height, 10, accuracy: 0.5)
    }

    func testCachedFormattersRespectDayAndTimezoneBoundaries() {
        var cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0)!
        let tokyo = TimeZone(secondsFromGMT: 9 * 3600)!
        cal.timeZone = utc

        let lateUTC = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 20, minute: 0))!
        XCTAssertEqual(CachedFormatters.shared.todayString(now: lateUTC, calendar: cal), "2026-11-22")

        var tokyoCal = Calendar(identifier: .gregorian)
        tokyoCal.timeZone = tokyo
        // 20:00 UTC is already 05:00 the next day in Tokyo
        XCTAssertEqual(CachedFormatters.shared.todayString(now: lateUTC, calendar: tokyoCal), "2026-11-23")

        let ms = Int64(lateUTC.timeIntervalSince1970 * 1000)
        XCTAssertEqual(UIFormat.sessionDateTime(ms: ms, timeZone: utc), "2026-11-22 20:00")
        XCTAssertEqual(UIFormat.sessionDateTime(ms: ms, timeZone: tokyo), "2026-11-23 05:00")
    }

    func testHeatmapSuppressesMouseHoverDuringActiveScroll() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12))!
        let chart = UsageHeatmap(rows: [], year: 2026, now: now, calendar: cal)
        let canvas = HeatmapCanvasView(frame: NSRect(x: 0, y: 0, width: 560, height: 140))
        canvas.update(chart, locale: Locale(identifier: "zh-Hans"))
        let layout = HeatmapGridLayout(chart: chart, width: 560)
        guard let targetIdx = chart.cells.indices.first(where: { chart.cells[$0] != nil }) else {
            XCTFail("Expected non-nil heatmap cell")
            return
        }
        let rect = layout.rect(targetIdx)

        var focusCalls = 0
        canvas.onFocus = { _ in focusCalls += 1 }

        // 正常聚焦应触发
        ScrollActivity.shared.setScrollingForTesting(false)
        canvas.focus(at: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(focusCalls, 1)

        // 模拟滚动态：mouseMoved 必须直接忽略
        ScrollActivity.shared.setScrollingForTesting(true)
        if let moveEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: rect.midX, y: rect.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) {
            canvas.mouseMoved(with: moveEvent)
        }
        XCTAssertEqual(focusCalls, 1)
    }
}
