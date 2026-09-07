//
//  MenuBarFormatterTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_menubar.py 的纯逻辑用例（无 AppKit、无网络、无真实偏好）。
//

import XCTest
@testable import TokenTrackerCore

private func entry(_ id: String, name: String = "", pct: Double?,
                   source: String = "official", stale: Bool = false,
                   label: String = "") -> MenuBarQuotaEntry {
    MenuBarQuotaEntry(id: id, name: name,
                      windows: [MenuBarQuotaWindow(pct: pct, source: source,
                                                   stale: stale, label: label)])
}

final class CompactTitlePortTests: XCTestCase {
    func testCompactTitleRemovesAllSpaces() {
        let e = entry("claude", pct: 45)
        let today = MenuBarToday(tokens: 32_522_521, cost: 0)
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: today, entries: [e], provider: "claude"),
                       "⚡ 32.52M · C 45%")
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: today, entries: [e],
                                           provider: "claude", compact: true),
                       "⚡32.52M·C45%")
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: nil, entries: nil,
                                           provider: "off", compact: true), "⚡—")
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: MenuBarToday(tokens: 100, cost: 0),
                                           entries: nil, provider: "off", compact: true),
                       "⚡100")
    }
}

final class RingTitlePortTests: XCTestCase {
    private let claudeEntry = entry("claude", pct: 56)

    func testRingTitleDropsBoltAndPercent() {
        let today = MenuBarToday(tokens: 87_920_000, cost: 0)
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: today, entries: [claudeEntry],
                                           provider: "claude", ring: true),
                       "87.92M · C")
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: today, entries: [claudeEntry],
                                           provider: "claude", compact: true, ring: true),
                       "87.92M·C")
        // 非圆环模式保持原样
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: today, entries: [claudeEntry],
                                           provider: "claude", compact: true),
                       "⚡87.92M·C56%")
    }

    func testRingTitleKeepsEstimateMarker() {
        let e = entry("claude", pct: 56, source: "local")
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: MenuBarToday(tokens: 100, cost: 0),
                                           entries: [e], provider: "claude", ring: true),
                       "100 · C≈")
    }

    func testRingTitleWithoutQuotaData() {
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: MenuBarToday(tokens: 100, cost: 0),
                                           entries: [], provider: "claude", ring: true), "100")
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: nil, entries: [], provider: "off",
                                           ring: true), "—")
    }

    func testRingSpecMatchesTitleThresholds() {
        for (pct, role) in [(0.0, "quota_ok"), (12.0, "quota_ok"), (49.9, "quota_ok"),
                            (50.0, "quota_warn"), (56.0, "quota_warn"), (79.9, "quota_warn"),
                            (80.0, "quota_crit"), (100.0, "quota_crit")] {
            let spec = MenuBarFmt.ringSpec(entries: [entry("claude", pct: pct)],
                                           provider: "claude")
            XCTAssertEqual(spec.role, role, "pct=\(pct)")
            XCTAssertEqual(spec.pct, pct)
            XCTAssertEqual(spec.role, MenuBarFmt.quotaUrgency(pct))
        }
    }

    func testRingSpecIsGreyWithoutData() {
        let cases: [([MenuBarQuotaEntry], String?)] = [
            ([], "claude"), ([claudeEntry], "off"), ([claudeEntry], nil),
            ([MenuBarQuotaEntry(id: "claude", name: "Claude", windows: [])], "claude"),
        ]
        for (entries, provider) in cases {
            let spec = MenuBarFmt.ringSpec(entries: entries, provider: provider)
            XCTAssertNil(spec.pct, "\(provider ?? "nil")")
            XCTAssertEqual(spec.role, "quota_none")
        }
    }

    func testRingSpecClampsOutOfRangePct() {
        XCTAssertEqual(MenuBarFmt.ringSpec(entries: [entry("c", pct: 143)], provider: "c").pct, 100)
        XCTAssertEqual(MenuBarFmt.ringSpec(entries: [entry("c", pct: -5)], provider: "c").pct, 0)
    }

    func testRingGlyphTracksFill() {
        XCTAssertEqual(MenuBarFmt.ringGlyph((nil, "quota_none")), "○")
        XCTAssertEqual(MenuBarFmt.ringGlyph((0, "quota_ok")), "○")
        XCTAssertEqual(MenuBarFmt.ringGlyph((56, "quota_warn")), "◑")
        XCTAssertEqual(MenuBarFmt.ringGlyph((100, "quota_crit")), "●")
    }
}

final class TitleSourcePortTests: XCTestCase {
    /// test_source_marker_does_not_depend_on_note
    func testSourceMarkerDoesNotDependOnNote() {
        for (source, stale, expected) in [("official", false, "45%"),
                                          ("official", true, "~45%"),
                                          ("local", false, "≈45%")] {
            let e = entry("claude", pct: 45, source: source, stale: stale)
            XCTAssertEqual(MenuBarFmt.fmtTitle(today: MenuBarToday(tokens: 100, cost: 0),
                                               entries: [e], provider: "claude"),
                           "⚡ 100 · C " + expected)
        }
    }
}

final class SegmentRenderPortTests: XCTestCase {
    func testSegmentsJoinMatchesTitleText() {
        let e = MenuBarQuotaEntry(id: "claude", name: "Claude Code",
                                  windows: [MenuBarQuotaWindow(pct: 45, source: "official",
                                                               stale: false, label: "")])
        for compact in [false, true] {
            let today = MenuBarToday(tokens: 12_300_000, cost: 0)
            let segs = MenuBarFmt.fmtSegments(today: today, entries: [e],
                                              provider: "claude", compact: compact)
            XCTAssertEqual(segs.map(\.text).joined(),
                           MenuBarFmt.fmtTitle(today: today, entries: [e],
                                               provider: "claude", compact: compact))
        }
    }

    func testRolesCoverUrgencyAndMarkers() {
        for (pct, role) in [(10.0, "quota_ok"), (50.0, "quota_warn"), (79.9, "quota_warn"),
                            (80.0, "quota_crit"), (100.0, "quota_crit")] {
            let e = entry("claude", pct: pct)
            let roles = MenuBarFmt.fmtSegments(today: MenuBarToday(tokens: 1, cost: 0),
                                               entries: [e], provider: "claude").map(\.role)
            XCTAssertEqual(roles.last, role, "pct=\(pct)")
        }
        let stale = entry("claude", pct: 45, stale: true)
        let local = entry("claude", pct: 45, source: "local")
        XCTAssertTrue(MenuBarFmt.fmtSegments(today: MenuBarToday(tokens: 1, cost: 0),
                                             entries: [stale], provider: "claude")
            .contains(MenuBarSegment(" ~", "marker")))
        XCTAssertTrue(MenuBarFmt.fmtSegments(today: MenuBarToday(tokens: 1, cost: 0),
                                             entries: [local], provider: "claude")
            .contains(MenuBarSegment(" ≈", "marker")))
    }

    func testMenuLineSegments() {
        let e = MenuBarQuotaEntry(id: "kimi", name: "Kimi",
                                  windows: [MenuBarQuotaWindow(pct: 74, source: "official",
                                                               stale: false, label: "周 (7天)")])
        let segs = MenuBarFmt.quotaLineSegments(e)
        XCTAssertEqual(segs.map(\.text).joined(), "● Kimi · 周 (7天) 74%")
        XCTAssertEqual(segs.first?.role, "dot_kimi")
        XCTAssertEqual(segs.last?.role, "quota_warn")
    }

    func testTodayLineSegments() {
        XCTAssertEqual(MenuBarFmt.todayLineSegments(MenuBarToday(tokens: 1500, cost: 2.5))
            .map(\.text).joined(), "今日 1.50K tokens · $2.50")
        XCTAssertEqual(MenuBarFmt.todayLineSegments(nil),
                       [MenuBarSegment("今日暂无数据（点「立即扫描」）", "dim")])
    }

    func testHexRGB() {
        let (r, g, b) = MenuBarFmt.hexRGB("#d97757")
        XCTAssertEqual(r, Double(0xD9) / 255, accuracy: 1e-9)
        XCTAssertEqual(g, Double(0x77) / 255, accuracy: 1e-9)
        XCTAssertEqual(b, Double(0x57) / 255, accuracy: 1e-9)
        XCTAssertEqual(MenuBarFmt.hexRGB("d97757").0, r)
    }

    func testAnimationCurves() {
        XCTAssertEqual(MenuBarFmt.spinnerFrame(10), String(Array(MenuBarFmt.spinner)[0]))
        XCTAssertEqual(MenuBarFmt.spinnerFrame(3), String(Array(MenuBarFmt.spinner)[3]))
        XCTAssertEqual(MenuBarFmt.flashAlpha(-1), 0)
        XCTAssertEqual(MenuBarFmt.flashAlpha(0.3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MenuBarFmt.flashAlpha(99), 1.0)
        for t in [0.0, 0.5, 1.3, 2.0, 5.7] {
            XCTAssertGreaterThanOrEqual(MenuBarFmt.pulseAlpha(t), MenuBarFmt.pulseMin - 1e-9)
        }
    }
}

final class YiFormatPortTests: XCTestCase {
    /// test_fmt_tokens_yi / test_title_segments_yi / test_today_line_yi
    func testFmtTokensYi() {
        XCTAssertEqual(MenuBarFmt.fmtTokens(5.5e8, yi: true), "5.50亿")
        XCTAssertEqual(MenuBarFmt.fmtTokens(55_000_000, yi: true), "0.55亿")
        XCTAssertEqual(MenuBarFmt.fmtTokens(1e8, yi: true), "1.00亿")
        XCTAssertEqual(MenuBarFmt.fmtTokens(999_999, yi: true), "1000.0K") // 不足 1M 保持 K
        XCTAssertEqual(MenuBarFmt.fmtTokens(99_999_999, yi: true), "1.00亿")
        XCTAssertEqual(MenuBarFmt.fmtTokens(5.5e8), "550.00M")             // 关闭时保持原样
    }

    func testTitleSegmentsYi() {
        let e = entry("claude", pct: 12)
        let today = MenuBarToday(tokens: 550_000_000, cost: 0)
        XCTAssertTrue(MenuBarFmt.fmtSegments(today: today, entries: [e], provider: "claude",
                                             compact: true, yi: true)
            .contains(MenuBarSegment("5.50亿", "tokens")))
        XCTAssertEqual(MenuBarFmt.fmtTitle(today: today, entries: [e], provider: "claude",
                                           compact: true, yi: true), "⚡5.50亿·C12%")
    }

    func testTodayLineYi() {
        XCTAssertTrue(MenuBarFmt.todayLineSegments(MenuBarToday(tokens: 330_000_000,
                                                                cost: 1.5), yi: true)
            .contains(MenuBarSegment("3.30亿", "tokens")))
    }
}
