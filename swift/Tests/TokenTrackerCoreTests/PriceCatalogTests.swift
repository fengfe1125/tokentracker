import XCTest
@testable import TokenTrackerCore

final class PriceCatalogTests: XCTestCase {
    func testOfficialPageSamplesSyncIntoSharedVersionedCatalog() async throws {
        let tmp = try TempDir()
        let path = tmp.path("prices.json")
        let pages = samplePages()
        let service = PriceSyncService(path: path) { url in
            guard let page = pages[url.absoluteString] else { throw URLError(.badURL) }
            return Data(page.utf8)
        }

        let result = await service.synchronize(nowMs: 1_000)
        XCTAssertEqual(result.status, "success")
        XCTAssertEqual(Set(result.updatedProviders), Set(["anthropic", "deepseek", "moonshot", "xai", "openai"]))

        let document = PriceCatalogDocument.load(from: path)
        XCTAssertEqual(document.lastSuccessAtMs, 1_000)
        XCTAssertEqual(document.versions.count, 11)
        let table = PriceTable.load(from: path)
        let anthropic = table.quote(provider: "anthropic", model: "claude-sonnet-4-5",
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
            cacheWrite: 1_000_000, eventAtMs: 1_000)
        XCTAssertEqual(anthropic?.cost, 22.05)
        XCTAssertNotNil(table.quote(provider: "anthropic", model: "claude-fable-5-1",
            input: 1_000_000, output: 1_000_000, eventAtMs: 1_000))
        let kimi = table.quote(provider: "moonshot", model: "kimi-k3", input: 1_000_000,
                               output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000,
                               eventAtMs: 1_000)
        XCTAssertEqual(kimi?.cost, 21.3)
        XCTAssertEqual(kimi?.conditions.isEmpty, false)
        XCTAssertEqual(table.quote(provider: "moonshot", model: "kimi-k2.7-code",
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
            eventAtMs: 1_000)?.cost, 5.14)
        XCTAssertEqual(table.quote(provider: "deepseek", model: "deepseek-flash",
                                   input: 1_000_000, output: 1_000_000,
                                   cacheRead: 1_000_000, cacheWrite: 1_000_000,
                                   eventAtMs: 1_000)?.cost, 0.903)
        XCTAssertEqual(table.quote(provider: "openai", model: "gpt-6-sol",
                                   input: 1_000_000, output: 1_000_000,
                                   cacheRead: 1_000_000, cacheWrite: 1_000_000,
                                   eventAtMs: 1_000)?.cost, 14.7)
        XCTAssertEqual(table.quote(provider: "openai", model: "o4-mini",
                                   input: 1_000_000, output: 1_000_000,
                                   eventAtMs: 1_000)?.cost, 2)
        XCTAssertTrue(document.versions.allSatisfy { $0.sourceURL.hasPrefix("https://") })
    }

    func testChangedPriceKeepsHistoryAndFailedSyncPreservesLastGoodCatalog() async throws {
        let tmp = try TempDir()
        let path = tmp.path("prices.json")
        let firstPages = samplePages()
        let first = PriceSyncService(path: path) { url in Data((firstPages[url.absoluteString] ?? "").utf8) }
        let firstResult = await first.synchronize(nowMs: 100)
        XCTAssertEqual(firstResult.status, "success")

        var changedPages = samplePages()
        changedPages["https://developers.openai.com/api/docs/pricing.md"] = changedPages["https://developers.openai.com/api/docs/pricing.md"]!
            .replacingOccurrences(of: "$2.00", with: "$4.00")
        let secondPages = changedPages
        let second = PriceSyncService(path: path) { url in Data((secondPages[url.absoluteString] ?? "").utf8) }
        let secondResult = await second.synchronize(nowMs: 200)
        XCTAssertEqual(secondResult.status, "success")
        let updated = PriceTable.load(from: path)
        XCTAssertEqual(updated.quote(provider: "openai", model: "gpt-6-sol", input: 1_000_000,
                                     output: 0, eventAtMs: 150)?.cost, 2)
        XCTAssertEqual(updated.quote(provider: "openai", model: "gpt-6-sol", input: 1_000_000,
                                     output: 0, eventAtMs: 250)?.cost, 4)

        let before = PriceCatalogDocument.load(from: path)
        let failing = PriceSyncService(path: path) { _ in throw URLError(.notConnectedToInternet) }
        let failure = await failing.synchronize(nowMs: 300)
        let after = PriceCatalogDocument.load(from: path)
        XCTAssertEqual(failure.status, "failed")
        XCTAssertEqual(after.versions, before.versions)
        XCTAssertEqual(after.lastSuccessAtMs, before.lastSuccessAtMs)
        XCTAssertEqual(after.lastAttemptAtMs, 300)
    }

    func testCachedRatesRemainAvailableWhenAutomaticSyncSettingIsOff() throws {
        let tmp = try TempDir()
        let path = tmp.path("prices.json")
        let catalog = PriceCatalogDocument(lastAttemptAtMs: 100, lastSuccessAtMs: 100,
            syncStatus: "success", versions: [PriceVersion(id: "cached", provider: "openai",
                model: "gpt-5", effectiveAtMs: 100, fetchedAtMs: 100,
                sourceURL: "https://openai.com/api/pricing/", rates: PriceRate(input: 1))])
        try catalog.save(to: path)
        let settings = SettingsStore(path: tmp.path("settings.json"))
        XCTAssertTrue(settings.set(key: "price_sync_enabled", value: false))
        XCTAssertEqual(PriceTable.load(from: path).quote(provider: "openai", model: "gpt-5",
            input: 1_000_000, output: 0, eventAtMs: 200)?.cost, 1)
    }

    func testFailedSyncKeepsExplicitLegacyRatesAndDropsGenericDefault() async throws {
        let tmp = try TempDir()
        let path = tmp.path("prices.json")
        let old = #"{"default":{"input":99},"models":{"gpt-5":{"input":1,"output":2}}}"#
        try Data(old.utf8).write(to: URL(fileURLWithPath: path))
        let service = PriceSyncService(path: path) { _ in throw URLError(.notConnectedToInternet) }
        let result = await service.synchronize(nowMs: 300)
        XCTAssertEqual(result.status, "failed")
        let document = PriceCatalogDocument.load(from: path)
        XCTAssertTrue(document.versions.contains { $0.model == "gpt-5" })
        XCTAssertFalse(document.versions.contains { $0.model == "default" })
        XCTAssertEqual(PriceTable.load(from: path).quote(provider: "openai", model: "gpt-5",
            input: 1_000_000, output: 0, eventAtMs: 400)?.cost, 1)
    }

    func testTwentyFourHourSyncDueBoundary() {
        XCTAssertTrue(PriceSyncService.isDue(lastSuccessAtMs: 0, nowMs: 100))
        XCTAssertFalse(PriceSyncService.isDue(lastSuccessAtMs: 100, nowMs: 100 + PriceSyncService.intervalMs - 1))
        XCTAssertTrue(PriceSyncService.isDue(lastSuccessAtMs: 100, nowMs: 100 + PriceSyncService.intervalMs))
    }

    private func samplePages() -> [String: String] {
        [
            "https://docs.anthropic.com/en/docs/about-claude/pricing": """
            <table><tr><th>Model</th><th>Input</th><th>Output</th><th>Cache Write (1 hour)</th><th>Cache Read</th><th>Cache Write (5 minutes)</th></tr>
            <tr><td>Claude Sonnet 4.5</td><td>$3.00</td><td>$15.00</td><td>$6.00</td><td>$0.30</td><td>$3.75</td></tr></table>
            <table><tr><th>Model</th><th>Input</th><th>Output</th><th>Cache Write (1 hour)</th><th>Cache Read</th><th>Cache Write (5 minutes)</th></tr>
            <tr><td>Claude Fable 5.1</td><td>$10.00</td><td>$50.00</td><td>$20.00</td><td>$0.25</td><td>$12.50</td></tr></table>
            """,
            "https://api-docs.deepseek.com/quick_start/pricing/": """
            <table>
            <tr><th>MODEL</th><th>deepseek-flash</th><th>deepseek-v4-pro</th></tr>
            <tr><td>1M INPUT TOKENS (CACHE HIT)</td></tr><tr><td>OFF-PEAK</td><td>$0.003</td><td>$0.022</td></tr>
            <tr><td>1M INPUT TOKENS (CACHE MISS)</td></tr><tr><td>OFF-PEAK</td><td>$0.15</td><td>$0.66</td></tr>
            <tr><td>1M OUTPUT TOKENS</td></tr><tr><td>OFF-PEAK</td><td>$0.6</td><td>$1.98</td></tr>
            </table>
            """,
            "https://platform.moonshot.ai/docs/pricing/chat": """
            <DocTable columns={[
              { title: "Model" }, { title: "Unit" },
              { title: "Cache Write Price (TTL 5min)" }, { title: "Cache Write Price (TTL 1h)" },
              { title: "Cached Input Price" }, { title: "Input Price" }, { title: "Output Price" },
            ]} rows={[
              ["kimi-k3", "1M tokens", <>{"$"}3.00</>, <>{"$"}6.00</>, <>{"$"}0.30</>, <>{"$"}3.00</>, <>{"$"}15.00</>],
            ]} />
            <DocTable columns={[
              { title: "Model" }, { title: "Unit" }, { title: "Input Price (Cache Hit)" },
              { title: "Input Price (Cache Miss)" }, { title: "Output Price" },
            ]} rows={[
              ["kimi-k2.7-code", "1M tokens", <>{"$"}0.19</>, <>{"$"}0.95</>, <>{"$"}4.00</>],
              ["kimi-k2.7-code-highspeed", "1M tokens", <>{"$"}0.38</>, <>{"$"}1.90</>, <>{"$"}8.00</>],
              ["kimi-k2.6", "1M tokens", <>{"$"}0.16</>, <>{"$"}0.95</>, <>{"$"}4.00</>],
            ]} />
            """,
            "https://docs.x.ai/developers/pricing": """
            <table><tr><th>Model</th><th>Input</th><th>Cached</th><th>Output</th></tr>
            <tr><td>grok-4.7 Long context ≥ 200k tokens</td><td>500k</td><td>$2.00</td><td>$0.50</td><td>$6.00</td><td>$4.00</td><td>$1.00</td><td>$12.00</td></tr></table>
            """,
            "https://developers.openai.com/api/docs/pricing.md": """
            ## Flagship models
            Standard Batch Flex Fast mode
            Short context | Long context
            --- | ---
            Model | Input | Cached input | Cache writes | Output | Input | Cached input | Cache writes | Output
            --- | --- | --- | --- | --- | --- | --- | --- | ---
            gpt-6-sol | $2.00 | $0.20 | $2.50 | $10.00 | $4.00 | $0.40 | $5.00 | $15.00
            o4-mini | $0.50 | $0.05 | - | $1.50 | $1.00 | $0.10 | - | $3.00
            gpt-6-sol | $1.00 | $0.10 | $1.25 | $5.00 | $2.00 | $0.20 | $2.50 | $7.50
            """,
        ]
    }
}
