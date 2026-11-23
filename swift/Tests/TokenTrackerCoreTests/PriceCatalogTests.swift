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
        XCTAssertEqual(Set(result.updatedProviders),
                       Set(["anthropic", "deepseek", "moonshot", "xai", "openai", "google", "minimax"]))

        let document = PriceCatalogDocument.load(from: path)
        XCTAssertEqual(document.lastSuccessAtMs, 1_000)
        XCTAssertEqual(document.versions.count, 20)
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

    func testNewSourcesShortContextTableAndSourceAliasesPrice() async throws {
        let tmp = try TempDir()
        let path = tmp.path("prices.json")
        let pages = samplePages()
        let service = PriceSyncService(path: path) { url in Data((pages[url.absoluteString] ?? "").utf8) }
        let result = await service.synchronize(nowMs: 1_000)
        XCTAssertEqual(result.status, "success")
        let table = PriceTable.load(from: path)
        func cost(_ provider: String?, _ model: String, at: Int64 = 1_000, input: Int64 = 1_000_000,
                  output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) -> Double? {
            table.quote(provider: provider, model: model, input: input, output: output,
                        cacheRead: cacheRead, cacheWrite: cacheWrite, eventAtMs: at)?.cost
        }

        // OpenAI 旗舰表按「短上下文」列读取，并去掉「(<272K context length)」注记。
        XCTAssertEqual(cost("openai", "gpt-6.1-sol", output: 1_000_000, cacheRead: 1_000_000,
                            cacheWrite: 1_000_000), 14.6)
        XCTAssertEqual(cost("openai", "gpt-5.5"), 5)
        XCTAssertEqual(cost("openai", "gpt-5.1", input: 0, cacheRead: 1_000_000), 0.125)
        XCTAssertEqual(cost("openai", "codex/gpt-6.1-sol"), 2)

        // DeepSeek API 名 deepseek-flash 由 V4.1-Flash 提供，目录别名可直接命中。
        XCTAssertTrue(PriceCatalogDocument.load(from: path).versions.contains {
            $0.model == "deepseek-flash" && $0.aliases.contains("deepseek-v4.1-flash")
        })
        XCTAssertEqual(cost(nil, "workbuddy/deepseek-v4.1-flash"), 0.15)

        // Gemini：Standard 付费列、带日期的调价，以及 Antigravity 的推理强度后缀。
        XCTAssertEqual(cost("google", "gemini-4-neon-xhigh", output: 1_000_000, cacheRead: 1_000_000), 18.15)
        XCTAssertEqual(cost("google", "gemini-4-argon", at: 500), 2)
        XCTAssertEqual(cost("google", "gemini-4-argon"), 2)
        XCTAssertEqual(cost("google", "gemini-4-argon-high", at: 1_796_112_000_000), 4)
        XCTAssertEqual(cost("google", "gemini-4-argon", at: 1_796_111_999_999), 2)
        XCTAssertEqual(cost("google", "gemini-4-hydrogen"), 1.5)
        XCTAssertNil(cost("google", "gemini-2.5-flash-image"))

        // MiniMax：Standard 表、512k 以内档位、永久折扣后的价格；Priority 表不覆盖。
        XCTAssertEqual(cost(nil, "MiniMax-M3", output: 1_000_000, cacheRead: 1_000_000), 1.56)
        XCTAssertEqual(cost(nil, "MiniMax-M3.1-Flash"), 0.15)

        // 带日期的调价生效后再同步同一页面，不会把「through」旧价重新加成新版本。
        let before = PriceCatalogDocument.load(from: path).versions
        let later = await service.synchronize(nowMs: 1_796_198_400_000)
        XCTAssertEqual(later.status, "success")
        let after = PriceCatalogDocument.load(from: path).versions.filter { $0.provider == "google" }
        XCTAssertEqual(after.count, before.filter { $0.provider == "google" }.count)
        XCTAssertEqual(PriceTable.load(from: path).quote(provider: "google", model: "gemini-4-argon",
            input: 1_000_000, output: 0, eventAtMs: 1_796_198_400_000)?.cost, 4)
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

            ### Standard pricing data
            | Model | Short context input | Short context output | Short context cached input | Short context 30m write | Short context 12h write | Long context input | Long context output | Long context cached input | Long context 30m write | Long context 12h write |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
            | gpt-6.1-sol | $2.00 | $10.00 | $0.10 | $2.50 | $5.00 | $4.00 | $15.00 | $0.20 | $5.00 | $10.00 |
            | gpt-5.5 (<272K context length) | $5.00 | $30.00 | $0.50 | - | - | $10.00 | $45.00 | $1.00 | - | - |

            | Model | Input | Output | Cached input |
            | --- | --- | --- | --- |
            | gpt-5.1 | $1.25 | $10.00 | $0.125 |

            ### Batch pricing data
            | Model | Short context input | Short context output | Short context cached input | Short context 30m write | Short context 12h write | Long context input | Long context output | Long context cached input | Long context 30m write | Long context 12h write |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
            | gpt-6.1-sol | $1.00 | $5.00 | $0.05 | $1.25 | $2.50 | $2.00 | $7.50 | $0.10 | $2.50 | $5.00 |
            """,
            "https://ai.google.dev/gemini-api/docs/pricing": """
            # Gemini Developer API pricing
            ## Gemini 4 Argon  {% id="gemini-4-argon" %}
            {% tabs %}
            {% tab title="Standard" %}
            {% table %}
            * Feature
            * Free Tier
            * Paid Tier, per 1M tokens in USD
            ---
            * Input price
            * Not available
            * $2.00 through November 30, 2026.
            $4.00 starting December 1, 2026.
            ---
            * Output price (including thinking tokens)
            * Not available
            * $10.00 through November 30, 2026.
            $20.00 starting December 1, 2026.
            ---
            * Context caching price
            * Not available
            * $0.10 through November 30, 2026.
            $0.20 starting December 1, 2026.
            {% /table %}
            {% /tab %}
            {% tab title="Batch" %}
            {% table %}
            ---
            * Input price
            * Not available
            * $1.00 through November 30, 2026.
            {% /table %}
            {% /tab %}
            {% /tabs %}
            ## Gemini 2.5 Flash Image  {% id="gemini-2.5-flash-image" %}
            {% table %}
            ---
            * Input price
            * Not available
            * $0.30 (text / image)
            ---
            * Output price
            * Not available
            * $0.039 per image{% sup %}*{% /sup %}
            {% /table %}
            ## Gemini 4 Neon  {% id="gemini-4-neon" %}
            {% tabs %}
            {% tab title="Standard" %}
            {% table %}
            ---
            * Input price
            * Not available
            * $3.00
            ---
            * Output price (including thinking tokens)
            * Not available
            * $15.00
            ---
            * Context caching price
            * Not available
            * $0.15 Implicit caching only (explicit caching is not supported).
            {% /table %}
            {% /tab %}
            {% /tabs %}
            ## Gemini 4 Hydrogen  {% id="gemini-4-hydrogen" %}
            {% tabs %}
              {% tab title="Standard" %}
              {% table %}
              * Feature
              * Free Tier
              * Paid Tier, per 1M tokens in USD

              ---

              * Input price
              * Free of charge
              * $1.50

              ---

              * Output price (including thinking tokens)
              * Free of charge
              * $7.50
            {% /table %}
            {% /tab %}
            {% /tabs %}
            """,
            "https://platform.minimax.io/docs/pricing/overview.md": """
            ## LLM

            | **Model** | **Input** \\$ / M tokens | **Output** \\$ / M tokens | **Prompt caching Read** \\$ / M tokens |
            | :- | :-: | :-: | :-: |
            | **MiniMax-M3.1-Flash** | \\$0.15 | \\$0.60 | \\$0.015 |

            > [tab] Standard
            >
            > | **Model** | **Input** \\$ / M tokens | **Output** \\$ / M tokens | **Prompt caching Read** \\$ / M tokens |
            > | :- | :-: | :-: | :-: |
            > | **MiniMax-M3** ≤ 512k input tokens Permanent 50% off | ~~\\$0.60~~ \\$0.30 | ~~\\$2.40~~ \\$1.20 | ~~\\$0.12~~ \\$0.06 |
            > | **MiniMax-M3** > 512k input tokens\\* Permanent 50% off | ~~\\$1.20~~ \\$0.60 | ~~\\$4.80~~ \\$2.40 | ~~\\$0.24~~ \\$0.12 |

            > [tab] Priority\\*
            >
            > | **Model** | **Input** \\$ / M tokens | **Output** \\$ / M tokens | **Prompt caching Read** \\$ / M tokens |
            > | :- | :-: | :-: | :-: |
            > | **MiniMax-M3** ≤ 512k input tokens Permanent 50% off | ~~\\$0.90~~ \\$0.45 | ~~\\$3.60~~ \\$1.80 | ~~\\$0.18~~ \\$0.09 |

            ## Video

            <table><thead><tr><th>Model</th><th>Output Resolution</th><th>Output Video per second</th></tr></thead>
            <tbody><tr><td>**MiniMax-H3**</td><td>2K</td><td>\\$0.13</td></tr></tbody></table>
            """,
        ]
    }
}
