//
//  PriceTableTests.swift
//  TokenTrackerCoreTests
//
//  Exact provider/model matching and event-time price version selection.
//

import XCTest
@testable import TokenTrackerCore

final class PriceTableTests: XCTestCase {
    private func loadDifferentialPrices() -> PriceTable {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return PriceTable.load(from: repo.appendingPathComponent("tests/differential/prices.json").path)
    }

    func testExactMatchAndExplicitAlias() {
        let t = loadDifferentialPrices()
        let exact = t.quote(provider: "anthropic", model: "claude-sonnet-4-5", input: 1200,
                            output: 300, cacheRead: 4000, cacheWrite: 800)
        XCTAssertEqual(exact?.cost, 0.0099)
        XCTAssertEqual(exact?.provider, "anthropic")
        XCTAssertEqual(exact?.priceVersionID, "test:anthropic:claude-sonnet-4-5")

        let alias = t.quote(provider: "claude", model: "Claude Sonnet 4.5", input: 1_000_000,
                            output: 0)
        XCTAssertEqual(alias?.cost, 3.0)
    }

    func testNoSubstringOrDefaultFallback() {
        let t = loadDifferentialPrices()
        XCTAssertNil(t.quote(provider: "openai", model: "gpt-5.6-luna-preview",
                             input: 1_000_000, output: 0))
        XCTAssertNil(t.quote(provider: "openai", model: "unpriced-model-x",
                             input: 1_000_000, output: 0))
        XCTAssertNil(t.quote(provider: "openrouter", model: "gpt-5",
                             input: 1_000_000, output: 0))
    }

    func testUnknownModelCanStillBeCountedWithoutAQuote() throws {
        let tmp = try TempDir()
        let store = try tmp.store()
        try store.putEvent(tool: "fixture", srcKey: "unknown", model: "new-provider-model",
                           input: 12, output: 8, cacheRead: 3)
        let stats = try store.stats()
        XCTAssertEqual(stats.total.tokens, 23)
        XCTAssertEqual(stats.total.unpriced, 1)
        XCTAssertEqual(stats.total.cost, 0)
    }

    func testRepriceStoresEventTimeVersionAndLeavesCrossingIntervalUnpriced() throws {
        let tmp = try TempDir()
        let store = try tmp.store()
        let prices = PriceTable(versions: [
            version("openai", "gpt-5", 1, id: "v1", effective: 100),
            version("openai", "gpt-5", 2, id: "v2", effective: 200),
        ])
        try store.putEvent(tool: "codex", srcKey: "exact", ts: 150, model: "gpt-5",
                           input: 1_000_000, provider: "openai")
        try store.putEvent(tool: "opencode", srcKey: "crossing", ts: 250, model: "gpt-5",
                           input: 1_000_000, timeQuality: "observed", intervalStart: 150,
                           provider: "openai")
        XCTAssertEqual(try store.reprice(prices), 1)
        let exact = try XCTUnwrap(store.conn.queryOne(
            "SELECT cost,price_version_id FROM usage_events WHERE src_key='exact'"))
        XCTAssertEqual(exact.double("cost"), 1)
        XCTAssertEqual(exact.string("price_version_id"), "v1")
        let crossing = try XCTUnwrap(store.conn.queryOne(
            "SELECT cost,price_version_id FROM usage_events WHERE src_key='crossing'"))
        XCTAssertNil(crossing.doubleOrNil("cost"))
        XCTAssertNil(crossing.stringOrNil("price_version_id"))
    }

    func testUniqueModelWithoutProviderMayBeResolvedButAmbiguousModelIsUnpriced() {
        let unique = PriceTable(versions: [version("openai", "gpt-5", 1)])
        XCTAssertEqual(unique.quote(model: "gpt-5", input: 1_000_000, output: 0)?.provider, "openai")
        let ambiguous = PriceTable(versions: [version("openai", "shared", 1),
                                               version("moonshot", "shared", 2)])
        XCTAssertNil(ambiguous.quote(model: "shared", input: 1_000_000, output: 0))
    }

    func testEventTimeSelectsHistoricalPriceAndIntervalsCrossingAChangeStayUnpriced() {
        let t = PriceTable(versions: [
            version("openai", "gpt-5", 1, id: "v1", effective: 100),
            version("openai", "gpt-5", 2, id: "v2", effective: 200),
        ])
        XCTAssertEqual(t.quote(provider: "openai", model: "gpt-5", input: 1_000_000,
                               output: 0, eventAtMs: 150)?.priceVersionID, "v1")
        XCTAssertEqual(t.quote(provider: "openai", model: "gpt-5", input: 1_000_000,
                               output: 0, eventAtMs: 250)?.cost, 2)
        XCTAssertNil(t.quote(provider: "openai", model: "gpt-5", input: 1_000_000,
                             output: 0, eventAtMs: 250, intervalStartMs: 150))
    }

    func testHalfEvenRounding() {
        let t = PriceTable(versions: [version("openai", "m", 0.0005)])
        XCTAssertEqual(t.quote(provider: "openai", model: "m", input: 1, output: 0)?.cost, 0.0)
    }

    private func version(_ provider: String, _ model: String, _ input: Double,
                         id: String = "v", effective: Int64 = 0) -> PriceVersion {
        PriceVersion(id: id, provider: provider, model: model,
                     effectiveAtMs: effective, fetchedAtMs: effective,
                     sourceURL: "fixture://prices", rates: PriceRate(input: input))
    }
}
