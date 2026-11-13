import XCTest
import SwiftUI
import AppKit
import TokenTrackerCore
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
}
