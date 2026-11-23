//
//  PriceTable.swift
//  TokenTrackerCore
//
//  Event-time price lookup over the shared local price catalog. Model names
//  match by provider plus an exact model ID or alias; relay prefixes, known
//  source aliases and reasoning-effort suffixes are retried as exact names.
//

import Foundation

/// API rate in USD per million tokens. The four counters are disjoint.
public struct PriceRate: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }

    public init(input: Double = 0, output: Double = 0,
                cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(input: try c.decodeIfPresent(Double.self, forKey: .input) ?? 0,
                  output: try c.decodeIfPresent(Double.self, forKey: .output) ?? 0,
                  cacheRead: try c.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0,
                  cacheWrite: try c.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0)
    }
}

public struct PriceVersion: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var model: String
    public var aliases: [String]
    public var effectiveAtMs: Int64
    public var fetchedAtMs: Int64
    public var sourceURL: String
    public var rates: PriceRate
    /// Conditions and assumptions that the token logs cannot fully identify.
    public var conditions: [String]

    enum CodingKeys: String, CodingKey {
        case id, provider, model, aliases, rates, conditions
        case effectiveAtMs = "effective_at_ms"
        case fetchedAtMs = "fetched_at_ms"
        case sourceURL = "source_url"
    }

    public init(id: String, provider: String, model: String, aliases: [String] = [],
                effectiveAtMs: Int64, fetchedAtMs: Int64, sourceURL: String,
                rates: PriceRate, conditions: [String] = []) {
        self.id = id
        self.provider = PriceTable.normalizeProvider(provider)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases
        self.effectiveAtMs = effectiveAtMs
        self.fetchedAtMs = fetchedAtMs
        self.sourceURL = sourceURL
        self.rates = rates
        self.conditions = conditions
    }
}

public struct PriceQuote: Equatable, Sendable {
    public let cost: Double
    public let provider: String
    public let priceVersionID: String
    public let conditions: [String]

    public var isConditionalEstimate: Bool { !conditions.isEmpty }
}

public struct PriceTable: Sendable {
    public var versions: [PriceVersion]

    public init(versions: [PriceVersion] = []) {
        self.versions = versions
    }

    /// No guessed default rate: missing or corrupt catalogs leave events unpriced.
    public static let `default` = PriceTable()

    /// Loads the shared catalog. Legacy files are read only for explicit model
    /// keys; a legacy `default` key is deliberately ignored.
    public static func load(from path: String) -> PriceTable {
        guard let data = FileManager.default.contents(atPath: path) else { return .default }
        if let document = try? JSONDecoder().decode(PriceCatalogDocument.self, from: data),
           document.schemaVersion == PriceCatalogDocument.currentSchemaVersion {
            return PriceTable(versions: document.versions)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return .default }
        let models = (dict["models"] as? [String: Any]) ?? dict
        let effectiveModels = models.filter { $0.key != "default" }
        let versions = effectiveModels.compactMap { model, raw -> PriceVersion? in
            guard let values = raw as? [String: Any],
                  let provider = legacyProvider(for: model) else { return nil }
            func number(_ key: String) -> Double {
                (values[key] as? NSNumber)?.doubleValue ?? 0
            }
            return PriceVersion(id: "legacy:\(provider):\(model)", provider: provider,
                model: model, aliases: [], effectiveAtMs: 0, fetchedAtMs: 0,
                sourceURL: "legacy local price file",
                rates: PriceRate(input: number("input"), output: number("output"),
                                 cacheRead: number("cache_read"), cacheWrite: number("cache_write")),
                conditions: ["Legacy local rate; source and effective date are unknown."])
        }
        return PriceTable(versions: versions)
    }

    public static func normalizeProvider(_ value: String) -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "claude", "anthropic": return "anthropic"
        case "openai", "open_ai", "codex": return "openai"
        case "deepseek", "dsh": return "deepseek"
        case "kimi", "moonshot", "moonshotai": return "moonshot"
        case "xai", "x-ai", "grok": return "xai"
        case "google", "gemini", "google_ai": return "google"
        case "minimax", "mini-max": return "minimax"
        default: return key
        }
    }

    private static func legacyProvider(for model: String) -> String? {
        let value = model.lowercased()
        if value.hasPrefix("claude-") { return "anthropic" }
        if value.hasPrefix("gpt-") || value.hasPrefix("o1") || value.hasPrefix("o3")
            || value.hasPrefix("o4") || value.hasPrefix("codex-") { return "openai" }
        if value.hasPrefix("deepseek-") { return "deepseek" }
        if value.hasPrefix("kimi-") { return "moonshot" }
        if value.hasPrefix("grok-") { return "xai" }
        if value.hasPrefix("gemini-") { return "google" }
        if value.hasPrefix("minimax-") { return "minimax" }
        return nil
    }

    /// Model names that a source logs under a different name than the official
    /// price table. Keys and values are normalized (lowercased) model IDs.
    static let knownModelAliases: [String: String] = [
        // DeepSeek's `deepseek-flash` API model is served by DeepSeek-V4.1-Flash;
        // relays such as WorkBuddy log the versioned name.
        "deepseek-v4.1-flash": "deepseek-flash",
    ]

    /// Reasoning-effort suffixes that some clients (Antigravity) append to the
    /// model ID. Effort changes token counts, not the per-token rate.
    static let effortSuffixes = ["-minimal", "-low", "-medium", "-high", "-xhigh"]

    /// Looks up an event-time version. The name is first matched exactly by
    /// provider plus model ID or alias. Without a recorded provider, a unique
    /// exact match is safe; ambiguous names are unpriced.
    ///
    /// Only when the exact name has no match, these forms are retried in order,
    /// each still as an exact name: the part after a relay prefix
    /// (`codex/gpt-6.1-sol`), a known model alias, and the name without a
    /// reasoning-effort suffix (`gemini-4-neon-xhigh`). The recorded provider
    /// usually names the client rather than the upstream owner, so a retried
    /// name that misses under it falls back to a unique provider.
    ///
    /// Events earlier than a model's first catalog version use that earliest
    /// version (the first official rate seen); later rate changes still split
    /// by event time, and observed intervals that cross a change stay unpriced.
    public func quote(provider rawProvider: String? = nil, model: String,
                      input: Int64, output: Int64, cacheRead: Int64 = 0,
                      cacheWrite: Int64 = 0, eventAtMs: Int64 = 0,
                      intervalStartMs: Int64? = nil) -> PriceQuote? {
        let modelKey = Self.normalizeModel(model)
        guard !modelKey.isEmpty else { return nil }
        let normalizedProvider = rawProvider.map { Self.normalizeProvider($0) } ?? ""
        let provider = normalizedProvider.isEmpty ? nil : normalizedProvider
        guard let (matchingModels, matchNotes) = resolveVersions(modelKey: modelKey, provider: provider),
              let earliest = matchingModels.min(by: { $0.effectiveAtMs < $1.effectiveAtMs })
        else { return nil }
        var notes = matchNotes
        let at = eventAtMs > 0 ? eventAtMs : Int64.max
        let selected: PriceVersion
        if let current = matchingModels.filter({ $0.effectiveAtMs <= at })
            .max(by: { $0.effectiveAtMs < $1.effectiveAtMs }) {
            selected = current
        } else {
            selected = earliest
            notes.append("Event predates the first catalog version of this model; estimated with the earliest official rate on record.")
        }
        if let start = intervalStartMs, start > 0, start < at,
           matchingModels.contains(where: {
               $0.effectiveAtMs > earliest.effectiveAtMs && start < $0.effectiveAtMs && $0.effectiveAtMs <= at
           }) {
            return nil
        }
        let inputCost = Double(input) * selected.rates.input
        let outputCost = Double(output) * selected.rates.output
        let cacheReadCost = Double(cacheRead) * selected.rates.cacheRead
        let cacheWriteCost = Double(cacheWrite) * selected.rates.cacheWrite
        let rawCost = (inputCost + outputCost + cacheReadCost + cacheWriteCost) / 1_000_000
        // Match Python's round(..., 8), which uses half-even rounding.
        let cost = (rawCost * 1e8).rounded(.toNearestOrEven) / 1e8
        return PriceQuote(cost: cost, provider: Self.normalizeProvider(selected.provider),
                          priceVersionID: selected.id, conditions: selected.conditions + notes)
    }

    /// Resolves the catalog versions for a logged model name, returning notes
    /// that describe any non-exact step used to reach them.
    private func resolveVersions(modelKey: String, provider: String?) -> ([PriceVersion], [String])? {
        let exact = exactMatches(model: modelKey, provider: provider)
        if !exact.isEmpty { return (exact, []) }

        var forms: [(name: String, notes: [String])] = []
        var base = modelKey
        var baseNotes: [String] = []
        if let (prefix, stripped) = Self.splitRelayPrefix(modelKey) {
            base = stripped
            baseNotes = ["Matched after removing relay prefix '\(prefix)/'; the relay's own billing may differ from the official rate."]
            forms.append((base, baseNotes))
        }
        if let alias = Self.knownModelAliases[base] {
            forms.append((alias, baseNotes + ["Matched model '\(base)' as its official API name '\(alias)'."]))
        }
        if let suffix = Self.effortSuffixes.first(where: { base.hasSuffix($0) && base.count > $0.count }) {
            let stripped = String(base.dropLast(suffix.count))
            forms.append((stripped, baseNotes + ["Matched after removing reasoning-effort suffix '\(suffix)'; effort changes token counts, not the per-token rate."]))
        }
        for form in forms {
            var matches = exactMatches(model: form.name, provider: provider)
            if matches.isEmpty, provider != nil {
                matches = exactMatches(model: form.name, provider: nil)
            }
            if !matches.isEmpty { return (matches, form.notes) }
        }
        return nil
    }

    /// Exact model/alias matches. Without a provider the match must resolve to a
    /// single provider; otherwise the name is ambiguous and returns no versions.
    private func exactMatches(model modelKey: String, provider: String?) -> [PriceVersion] {
        let matches = versions.filter { version in
            let names = [version.model] + version.aliases
            return names.contains { Self.normalizeModel($0) == modelKey }
                && (provider == nil || Self.normalizeProvider(version.provider) == provider)
        }
        guard provider == nil else { return matches }
        return Set(matches.map { Self.normalizeProvider($0.provider) }).count == 1 ? matches : []
    }

    /// Splits `relay/model` at the last `/`. Both parts must be non-empty.
    static func splitRelayPrefix(_ modelKey: String) -> (prefix: String, base: String)? {
        guard let slash = modelKey.lastIndex(of: "/") else { return nil }
        let prefix = String(modelKey[..<slash])
        let base = String(modelKey[modelKey.index(after: slash)...])
        guard !prefix.isEmpty, !base.isEmpty else { return nil }
        return (prefix, base)
    }

    /// Convenience for non-event UI calculations. Callers that persist an event
    /// should use `quote` so the provider and price version are saved with it.
    public func cost(for model: String, input: Int64, output: Int64,
                     cacheRead: Int64 = 0, cacheWrite: Int64 = 0) -> Double? {
        quote(model: model, input: input, output: output,
              cacheRead: cacheRead, cacheWrite: cacheWrite)?.cost
    }

    private static func normalizeModel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
