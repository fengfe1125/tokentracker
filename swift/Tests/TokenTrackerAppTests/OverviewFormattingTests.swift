import XCTest
@testable import TokenTrackerApp

final class OverviewFormattingTests: XCTestCase {
    private var previousLanguage = "en"

    override func setUp() {
        super.setUp()
        previousLanguage = L10n.language
        L10n.setLanguage("zh-Hans")
    }

    override func tearDown() {
        L10n.setLanguage(previousLanguage)
        super.tearDown()
    }

    func testOverviewUsesYiOnlyForValuesAtLeastOneYi() {
        XCTAssertEqual(UIFormat.overviewTokens(224_815_945, yi: true), "≈ 2.25 亿")
        XCTAssertEqual(UIFormat.overviewTokens(4_655_851, yi: true), "≈ 465.59 万")
        XCTAssertEqual(UIFormat.overviewTokens(579_605, yi: true), "≈ 57.96 万")
    }

    func testOverviewUsesWanWhenYiIsDisabled() {
        XCTAssertEqual(UIFormat.overviewTokens(224_815_945, yi: false), "≈ 22481.59 万")
    }

    func testCompactPicksWanOrYiByMagnitude() {
        // 200 万在「亿」模式下曾显示成 0.02亿，和旁边的 871.7K 混用两套单位。
        XCTAssertEqual(UIFormat.compact(2_011_300, yi: true), "201.1万")
        XCTAssertEqual(UIFormat.compact(34_350_000, yi: true), "3435万")
        XCTAssertEqual(UIFormat.compact(838_075_250, yi: true), "8.38亿")
        XCTAssertEqual(UIFormat.compact(9_999, yi: true), "9999")
        XCTAssertEqual(UIFormat.compact(871_700, yi: false), "871.7K")
        L10n.setLanguage("en")
        XCTAssertEqual(UIFormat.compact(838_075_250, yi: true), "838.08M")
    }

    func testShareKeepsTinyNonZeroPartsVisible() {
        XCTAssertEqual(UIFormat.share(0, of: 100), "0%")
        XCTAssertEqual(UIFormat.share(5, of: 0), "0%")
        XCTAssertEqual(UIFormat.share(1, of: 100_000), "<0.1%")
        XCTAssertEqual(UIFormat.share(923, of: 1000), "92.3%")
    }
}
