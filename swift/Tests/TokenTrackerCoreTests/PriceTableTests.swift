//
//  PriceTableTests.swift
//  TokenTrackerCoreTests
//
//  对照 tokentracker/pricing.py 的行为：精确 → 最长子串 → default → nil。
//

import XCTest
@testable import TokenTrackerCore

final class PriceTableTests: XCTestCase {
    /// tests/differential/prices.json（稳定基线，不随仓库根 prices.json 漂移）
    private func loadDifferentialPrices() -> PriceTable {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TokenTrackerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // repo root
        return PriceTable.load(from: repo.appendingPathComponent("tests/differential/prices.json").path)
    }

    func testExactMatch() {
        let t = loadDifferentialPrices()
        // claude-sonnet-4-5: 1200*3 + 300*15 + 4000*0.3 + 800*0.75 = 9900 (/1e6)
        XCTAssertEqual(t.cost(for: "claude-sonnet-4-5", input: 1200, output: 300,
                              cacheRead: 4000, cacheWrite: 800), 0.0099)
    }

    func testLongestSubstringWins() {
        let t = loadDifferentialPrices()
        // "gpt-5.6-luna-preview" 必须命中 "gpt-5.6-luna" 而不是 "gpt-5"
        let cost = t.cost(for: "gpt-5.6-luna-preview", input: 1_000_000, output: 0)
        XCTAssertEqual(cost, 2.0)
    }

    func testDefaultFallbackForUnknownModel() {
        let t = loadDifferentialPrices()
        // 不在表中的模型走 default：1500*2 + 60*10 = 3600 (/1e6)
        XCTAssertEqual(t.cost(for: "unpriced-model-x", input: 1500, output: 60), 0.0036)
    }

    func testEmptyModelIsUnpriced() {
        let t = loadDifferentialPrices()
        XCTAssertNil(t.cost(for: "", input: 100, output: 100))
    }

    func testHalfEvenRounding() {
        // Python round(x, 8) 为 half-even；构造恰好在第 9 位为 5 的值。
        let t = PriceTable(fallback: nil, models: ["m": PriceRate(input: 0.0005)])
        XCTAssertEqual(t.cost(for: "m", input: 1, output: 0), 0.0)
    }
}
