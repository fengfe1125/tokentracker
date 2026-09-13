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
}
