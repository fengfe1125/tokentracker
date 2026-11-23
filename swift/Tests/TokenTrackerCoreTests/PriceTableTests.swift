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
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return PriceTable.load(from: fixtures.appendingPathComponent("Fixtures/differential/prices.json").path)
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

    func testRelayPrefixIsStrippedOnlyWhenExactNameHasNoMatch() {
        let t = PriceTable(versions: [
            version("xai", "grok-4.7", 3, id: "grok"),
            version("openai", "gpt-6.1-sol", 2, id: "sol"),
            version("deepseek", "deepseek-flash", 1, id: "ds"),
            version("openai", "gateway/special", 9, id: "explicit"),
        ])
        // 记录的供应商与剥离后模型一致时直接命中。
        let sol = t.quote(provider: "openai", model: "codex/gpt-6.1-sol", input: 1_000_000, output: 0)
        XCTAssertEqual(sol?.priceVersionID, "sol")
        XCTAssertEqual(sol?.cost, 2)
        XCTAssertTrue(sol?.conditions.contains { $0.contains("'codex/'") } ?? false)
        // Codex 记为 openai，但转发的是 xAI 模型：回退到唯一供应商。
        let grok = t.quote(provider: "openai", model: "grok/grok-4.7", input: 1_000_000, output: 0)
        XCTAssertEqual(grok?.provider, "xai")
        XCTAssertEqual(grok?.cost, 3)
        // 多层前缀取最后一个 / 之后的名字；无供应商时同样可用。
        XCTAssertEqual(t.quote(model: "workbuddy/deepseek/deepseek-flash", input: 1_000_000,
                               output: 0)?.priceVersionID, "ds")
        // 目录里显式带 / 的名字优先精确匹配，且不附加转发说明。
        let explicit = t.quote(provider: "openai", model: "gateway/special", input: 1_000_000, output: 0)
        XCTAssertEqual(explicit?.priceVersionID, "explicit")
        XCTAssertEqual(explicit?.conditions, [])
        // 剥离后仍不做子串或后缀匹配。
        XCTAssertNil(t.quote(model: "auto/grok-4.7@500k", input: 1_000_000, output: 0))
        XCTAssertNil(t.quote(model: "group/auto-gpt-6-1-sol", input: 1_000_000, output: 0))
        XCTAssertNil(t.quote(model: "relay/", input: 1_000_000, output: 0))
        XCTAssertNil(t.quote(model: "/gpt-6.1-sol", input: 1_000_000, output: 0))
    }

    func testRelayPrefixWithAmbiguousBaseModelStaysUnpriced() {
        let t = PriceTable(versions: [version("openai", "shared", 1),
                                      version("moonshot", "shared", 2)])
        XCTAssertNil(t.quote(provider: "xai", model: "relay/shared", input: 1_000_000, output: 0))
        XCTAssertEqual(t.quote(provider: "moonshot", model: "relay/shared", input: 1_000_000,
                               output: 0)?.cost, 2)
    }

    func testRepriceBackfillsRelayPrefixedEvents() throws {
        let tmp = try TempDir()
        let store = try tmp.store()
        try store.putEvent(tool: "codex", srcKey: "k1", ts: 1_000, model: "grok/grok-4.7",
                           input: 1_000_000, provider: "openai")
        let prices = PriceTable(versions: [version("xai", "grok-4.7", 3, id: "grok")])
        XCTAssertEqual(try store.reprice(prices), 1)
        let row = try XCTUnwrap(store.conn.queryOne(
            "SELECT cost,provider,price_version_id FROM usage_events WHERE src_key='k1'"))
        XCTAssertEqual(row.double("cost"), 3)
        XCTAssertEqual(row.string("provider"), "xai")
        XCTAssertEqual(row.string("price_version_id"), "grok")
    }

    func testEventsBeforeFirstVersionUseEarliestRateButLaterChangesStillSplit() {
        let t = PriceTable(versions: [
            version("openai", "gpt-5", 1, id: "v1", effective: 100),
            version("openai", "gpt-5", 2, id: "v2", effective: 200),
        ])
        let early = t.quote(provider: "openai", model: "gpt-5", input: 1_000_000, output: 0, eventAtMs: 50)
        XCTAssertEqual(early?.priceVersionID, "v1")
        XCTAssertTrue(early?.conditions.contains { $0.contains("predates the first catalog version") } ?? false)
        XCTAssertNil(t.quote(provider: "openai", model: "gpt-5", input: 1_000_000, output: 0,
                             eventAtMs: 150)?.conditions.first)
        // 区间跨越首个版本的生效点不算跨价，跨越之后的调价仍保持未计价。
        XCTAssertEqual(t.quote(provider: "openai", model: "gpt-5", input: 1_000_000, output: 0,
                               eventAtMs: 150, intervalStartMs: 50)?.cost, 1)
        XCTAssertNil(t.quote(provider: "openai", model: "gpt-5", input: 1_000_000, output: 0,
                             eventAtMs: 250, intervalStartMs: 50))
    }

    func testKnownAliasAndEffortSuffixAreRetriedAsExactNames() {
        let t = PriceTable(versions: [
            version("deepseek", "deepseek-flash", 0.15, id: "ds"),
            version("google", "gemini-4-neon", 3, id: "neon"),
            version("anthropic", "claude-opus-5-5", 5, id: "opus"),
        ])
        let alias = t.quote(provider: "openai", model: "workbuddy/deepseek-v4.1-flash",
                            input: 1_000_000, output: 0)
        XCTAssertEqual(alias?.priceVersionID, "ds")
        XCTAssertEqual(alias?.provider, "deepseek")
        XCTAssertEqual(alias?.conditions.count, 2)
        XCTAssertEqual(t.quote(provider: "google", model: "gemini-4-neon-xhigh", input: 1_000_000,
                               output: 0)?.priceVersionID, "neon")
        XCTAssertEqual(t.quote(provider: "anthropic", model: "claude-opus-5-5-medium", input: 1_000_000,
                               output: 0)?.cost, 5)
        // 只去掉一个已知强度后缀，其余后缀仍不匹配。
        XCTAssertNil(t.quote(provider: "google", model: "gemini-4-neon-tiered-high", input: 1_000_000, output: 0))
        XCTAssertNil(t.quote(provider: "google", model: "gemini-4-neon-max", input: 1_000_000, output: 0))
        XCTAssertNil(t.quote(model: "deepseek-v4.1-flash-free", input: 1_000_000, output: 0))
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
