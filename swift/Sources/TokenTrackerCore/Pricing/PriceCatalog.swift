//
//  PriceCatalog.swift
//  TokenTrackerCore
//
//  One local, versioned catalog shared by the Swift app and Python CLI.
//

import Foundation

public struct PriceCatalogDocument: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var lastAttemptAtMs: Int64
    public var lastSuccessAtMs: Int64
    public var syncStatus: String
    public var syncMessage: String
    public var versions: [PriceVersion]

    enum CodingKeys: String, CodingKey {
        case versions
        case schemaVersion = "schema_version"
        case lastAttemptAtMs = "last_attempt_at_ms"
        case lastSuccessAtMs = "last_success_at_ms"
        case syncStatus = "sync_status"
        case syncMessage = "sync_message"
    }

    public init(schemaVersion: Int = currentSchemaVersion, lastAttemptAtMs: Int64 = 0,
                lastSuccessAtMs: Int64 = 0, syncStatus: String = "never",
                syncMessage: String = "", versions: [PriceVersion] = []) {
        self.schemaVersion = schemaVersion
        self.lastAttemptAtMs = lastAttemptAtMs
        self.lastSuccessAtMs = lastSuccessAtMs
        self.syncStatus = syncStatus
        self.syncMessage = syncMessage
        self.versions = versions
    }

    public static func load(from path: String) -> PriceCatalogDocument {
        guard let data = FileManager.default.contents(atPath: path) else { return PriceCatalogDocument() }
        if let value = try? JSONDecoder().decode(PriceCatalogDocument.self, from: data),
           value.schemaVersion == currentSchemaVersion { return value }
        // Upgrade the old explicit-model table in place on the next sync. Its
        // generic `default` row is intentionally ignored by PriceTable.load.
        let legacyVersions = PriceTable.load(from: path).versions
        return PriceCatalogDocument(syncStatus: legacyVersions.isEmpty ? "never" : "legacy",
                                    versions: legacyVersions)
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct PriceSyncResult: Equatable, Sendable {
    public let status: String
    public let message: String
    public let updatedProviders: [String]
    public let lastSuccessAtMs: Int64
}

private struct PriceCandidate: Sendable {
    let provider: String
    let model: String
    let aliases: [String]
    let rates: PriceRate
    let sourceURL: String
    let conditions: [String]
    /// Effective time stated by the official page (for example "starting
    /// December 1, 2026"). Nil means the page states no date.
    var effectiveAtMs: Int64? = nil
    /// Last moment an undated rate is valid when the page says "through <date>";
    /// after it the candidate is ignored so it cannot reappear as a new version.
    var expiresAtMs: Int64? = nil
}

/// Fetches official, unauthenticated public price pages and atomically updates
/// the local catalog. A failed source never removes its previously valid rates.
public final class PriceSyncService: @unchecked Sendable {
    public typealias Fetcher = @Sendable (URL) async throws -> Data

    private struct Source: Sendable {
        let provider: String
        let url: String
    }

    public static let intervalMs: Int64 = 24 * 60 * 60 * 1000
    public static let sources: [(provider: String, url: String)] = [
        ("anthropic", "https://docs.anthropic.com/en/docs/about-claude/pricing"),
        ("deepseek", "https://api-docs.deepseek.com/quick_start/pricing/"),
        ("moonshot", "https://platform.moonshot.ai/docs/pricing/chat"),
        ("xai", "https://docs.x.ai/developers/pricing"),
        ("openai", "https://developers.openai.com/api/docs/pricing.md"),
        ("google", "https://ai.google.dev/gemini-api/docs/pricing"),
        ("minimax", "https://platform.minimax.io/docs/pricing/overview.md"),
    ]

    private let path: String
    private let fetcher: Fetcher

    public init(path: String = PriceCatalogStore.sharedPath, fetcher: Fetcher? = nil) {
        self.path = path
        self.fetcher = fetcher ?? { url in try await Self.fetchOfficialPage(url) }
    }

    public static func isDue(lastSuccessAtMs: Int64, nowMs: Int64) -> Bool {
        lastSuccessAtMs <= 0 || nowMs - lastSuccessAtMs >= intervalMs
    }

    public func synchronize(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async -> PriceSyncResult {
        var catalog = PriceCatalogDocument.load(from: path)
        let originalSuccess = catalog.lastSuccessAtMs
        var successes: [String] = []
        var failures: [String] = []

        for source in Self.sources {
            if Task.isCancelled {
                return PriceSyncResult(status: "cancelled", message: "", updatedProviders: [],
                                       lastSuccessAtMs: originalSuccess)
            }
            do {
                guard let url = URL(string: source.url) else { throw PriceSyncError.invalidURL }
                let data = try await fetcher(url)
                if Task.isCancelled {
                    return PriceSyncResult(status: "cancelled", message: "", updatedProviders: [],
                                           lastSuccessAtMs: originalSuccess)
                }
                let candidates = try OfficialPriceParser.parse(data: data, provider: source.provider,
                                                               sourceURL: source.url)
                guard !candidates.isEmpty else { throw PriceSyncError.noRecognizedRates }
                merge(candidates, into: &catalog.versions, observedAtMs: nowMs)
                successes.append(source.provider)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    return PriceSyncResult(status: "cancelled", message: "", updatedProviders: [],
                                           lastSuccessAtMs: originalSuccess)
                }
                failures.append("\(source.provider): \(Self.safeError(error))")
            }
        }

        catalog.lastAttemptAtMs = nowMs
        if !successes.isEmpty {
            catalog.lastSuccessAtMs = nowMs
            catalog.syncStatus = failures.isEmpty ? "success" : "partial"
            catalog.syncMessage = failures.joined(separator: "; ")
        } else {
            catalog.syncStatus = "failed"
            catalog.syncMessage = failures.joined(separator: "; ")
            catalog.lastSuccessAtMs = originalSuccess
        }

        do {
            try catalog.save(to: path)
        } catch {
            return PriceSyncResult(status: "failed",
                message: "Could not save the price catalog. The previous catalog remains in use.",
                updatedProviders: [], lastSuccessAtMs: originalSuccess)
        }
        return PriceSyncResult(status: catalog.syncStatus, message: catalog.syncMessage,
                               updatedProviders: successes, lastSuccessAtMs: catalog.lastSuccessAtMs)
    }

    private func merge(_ candidates: [PriceCandidate], into versions: inout [PriceVersion],
                       observedAtMs: Int64) {
        for candidate in candidates {
            if let expires = candidate.expiresAtMs, observedAtMs > expires { continue }
            let provider = PriceTable.normalizeProvider(candidate.provider)
            let key = PriceTable.modelKey(candidate.model)
            let indices = versions.indices.filter {
                PriceTable.normalizeProvider(versions[$0].provider) == provider
                    && PriceTable.modelKey(versions[$0].model) == key
            }
            func refresh(_ index: Int) {
                versions[index].aliases = Array(Set(versions[index].aliases + candidate.aliases)).sorted()
                versions[index].fetchedAtMs = observedAtMs
                versions[index].sourceURL = candidate.sourceURL
                versions[index].conditions = candidate.conditions
            }
            let effectiveAt: Int64
            if let stated = candidate.effectiveAtMs {
                // A dated rate is keyed by its stated date; a corrected
                // announcement updates that version instead of adding another.
                if let index = indices.first(where: { versions[$0].effectiveAtMs == stated }) {
                    versions[index].rates = candidate.rates
                    refresh(index)
                    continue
                }
                effectiveAt = stated
            } else {
                // Compare with the rate in effect now, not a future dated one.
                let current = indices.filter { versions[$0].effectiveAtMs <= observedAtMs }
                    .max { versions[$0].effectiveAtMs < versions[$1].effectiveAtMs }
                if let current, versions[current].rates == candidate.rates {
                    refresh(current)
                    continue
                }
                effectiveAt = observedAtMs
            }
            let baseID = "\(provider):\(key):\(effectiveAt)"
            var id = baseID
            var suffix = 2
            while versions.contains(where: { $0.id == id }) {
                id = "\(baseID):\(suffix)"
                suffix += 1
            }
            versions.append(PriceVersion(id: id, provider: provider, model: candidate.model,
                aliases: candidate.aliases, effectiveAtMs: effectiveAt,
                fetchedAtMs: observedAtMs, sourceURL: candidate.sourceURL,
                rates: candidate.rates, conditions: candidate.conditions))
        }
        versions.sort {
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            if $0.model != $1.model { return $0.model < $1.model }
            return $0.effectiveAtMs < $1.effectiveAtMs
        }
    }

    private static func safeError(_ error: Error) -> String {
        if error is PriceSyncError { return (error as? PriceSyncError)?.description ?? "parse failed" }
        if let urlError = error as? URLError { return "network error (\(urlError.code.rawValue))" }
        return "network or parse error"
    }

    private static func fetchOfficialPage(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("text/markdown,text/plain, text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PriceSyncError.badResponse
        }
        return data
    }
}

public enum PriceCatalogStore {
    public static let sharedPath = NSHomeDirectory() + "/.tokentracker/prices.json"
}

private enum PriceSyncError: Error, CustomStringConvertible {
    case invalidURL, badResponse, noRecognizedRates
    var description: String {
        switch self {
        case .invalidURL: return "invalid official source URL"
        case .badResponse: return "official source returned an error"
        case .noRecognizedRates: return "official page format was not recognized"
        }
    }
}

/// Small source-specific readers for public pricing pages. They intentionally
/// fail closed when a page changes shape so old prices are kept and the status
/// makes the failed provider visible.
private enum OfficialPriceParser {
    private struct Table {
        var rows: [[String]]
        var text: String { rows.flatMap { $0 }.joined(separator: " ") }
    }

    static func parse(data: Data, provider: String, sourceURL: String) throws -> [PriceCandidate] {
        let source = String(decoding: data, as: UTF8.self)
        let tables = parseTables(source)
        let normalized = PriceTable.normalizeProvider(provider)
        let parsed: [PriceCandidate]
        switch normalized {
        case "anthropic": parsed = parseAnthropic(tables, sourceURL)
        case "deepseek": parsed = parseDeepSeek(tables, sourceURL)
        case "moonshot": parsed = parseMoonshot(tables + parseDocTables(source), sourceURL)
        case "xai": parsed = parseXAI(tables, sourceURL)
        case "openai": parsed = parseOpenAI(tables, sourceURL)
        case "google": parsed = parseGemini(source, sourceURL)
        case "minimax":
            // The Markdown page mixes pipe tables (some inside `>` tab blocks)
            // with HTML media tables, so read both forms.
            let unquoted = source.replacingOccurrences(of: #"(?m)^>[ \t]?"#, with: "",
                                                       options: .regularExpression)
            parsed = parseMiniMax(parseMarkdownTables(unquoted) + tables, sourceURL)
        default: parsed = []
        }
        guard !parsed.isEmpty else { throw PriceSyncError.noRecognizedRates }
        return parsed
    }

    private static func parseTables(_ source: String) -> [Table] {
        let tableRegex = try! NSRegularExpression(pattern: "(?is)<table\\b[^>]*>(.*?)</table>")
        let rowRegex = try! NSRegularExpression(pattern: "(?is)<tr\\b[^>]*>(.*?)</tr>")
        let cellRegex = try! NSRegularExpression(pattern: "(?is)<t[dh]\\b[^>]*>(.*?)</t[dh]>")
        let full = NSRange(source.startIndex..., in: source)
        let htmlTables = tableRegex.matches(in: source, range: full).compactMap { tableMatch -> Table? in
            guard let tableRange = Range(tableMatch.range(at: 1), in: source) else { return nil }
            let body = String(source[tableRange])
            let rowRange = NSRange(body.startIndex..., in: body)
            let rows = rowRegex.matches(in: body, range: rowRange).compactMap { rowMatch -> [String]? in
                guard let range = Range(rowMatch.range(at: 1), in: body) else { return nil }
                let row = String(body[range])
                let cellRange = NSRange(row.startIndex..., in: row)
                let cells = cellRegex.matches(in: row, range: cellRange).compactMap { cellMatch -> String? in
                    guard let cell = Range(cellMatch.range(at: 1), in: row) else { return nil }
                    return htmlText(String(row[cell])).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return cells.isEmpty ? nil : cells
            }
            return rows.isEmpty ? nil : Table(rows: rows)
        }
        return htmlTables.isEmpty ? parseMarkdownTables(source) : htmlTables
    }

    private static func parseMarkdownTables(_ source: String) -> [Table] {
        var result: [Table] = []
        var rows: [[String]] = []
        func flush() {
            if !rows.isEmpty { result.append(Table(rows: rows)); rows = [] }
        }
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.contains("|") else {
                flush()
                continue
            }
            var parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "`", with: "")
                }
            if parts.first?.isEmpty == true { parts.removeFirst() }
            if parts.last?.isEmpty == true { parts.removeLast() }
            let cells = parts
            let isSeparator = cells.allSatisfy {
                !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" || $0.isWhitespace }
            }
            if isSeparator { continue }
            if !cells.isEmpty { rows.append(cells) }
        }
        flush()
        return result
    }

    /// Kimi publishes its price table as an MDX `DocTable` component rather
    /// than rendered HTML. Read its public columns and rows without evaluating
    /// any page scripts or JSX.
    private static func parseDocTables(_ source: String) -> [Table] {
        let regex = try! NSRegularExpression(pattern: "(?is)<DocTable\\b")
        let full = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: full).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            let block = String(source[range.lowerBound..<source.endIndex])
            guard let columns = bracketContents(after: "columns=", in: block),
                  let rows = bracketContents(after: "rows=", in: block) else { return nil }
            let titleRegex = try! NSRegularExpression(pattern: #"title\s*:\s*"([^"]+)""#)
            let titleRange = NSRange(columns.startIndex..., in: columns)
            let header = titleRegex.matches(in: columns, range: titleRange).compactMap { titleMatch -> String? in
                guard let title = Range(titleMatch.range(at: 1), in: columns) else { return nil }
                return String(columns[title])
            }
            guard !header.isEmpty else { return nil }
            let dataRows = splitTopLevel(rows, separator: ",").compactMap { rawRow -> [String]? in
                let row = rawRow.trimmingCharacters(in: .whitespacesAndNewlines)
                guard row.first == "[", row.last == "]" else { return nil }
                let content = String(row.dropFirst().dropLast())
                return splitTopLevel(content, separator: ",").map { cleanDocCell($0) }
            }
            return dataRows.isEmpty ? nil : Table(rows: [header] + dataRows)
        }
    }

    private static func bracketContents(after marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let opening = source[markerRange.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = opening
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    let start = source.index(after: opening)
                    return String(source[start..<index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func splitTopLevel(_ source: String, separator: Character) -> [String] {
        var pieces: [String] = []
        var start = source.startIndex
        var squareDepth = 0, curlyDepth = 0, parenDepth = 0
        var inString = false
        var escaped = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "[": squareDepth += 1
                case "]": squareDepth -= 1
                case "{": curlyDepth += 1
                case "}": curlyDepth -= 1
                case "(": parenDepth += 1
                case ")": parenDepth -= 1
                default: break
                }
                if character == separator && squareDepth == 0 && curlyDepth == 0 && parenDepth == 0 {
                    pieces.append(String(source[start..<index]))
                    start = source.index(after: index)
                }
            }
            index = source.index(after: index)
        }
        pieces.append(String(source[start..<source.endIndex]))
        return pieces
    }

    private static func cleanDocCell(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\\"", with: "\"")
        value = value.replacingOccurrences(of: #"\{\s*"\$"\s*\}"#,
                                           with: "$", options: .regularExpression)
        return value
    }

    private static func htmlText(_ source: String) -> String {
        var text = source
        for pattern in ["(?is)<script\\b[^>]*>.*?</script>", "(?is)<style\\b[^>]*>.*?</style>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)</?(?:br|p|div|li|section|h[1-6])\\b[^>]*>",
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</?(?:td|th|tr)\\b[^>]*>",
                                         with: " | ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&lt;": "<",
                        "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&mdash;": "—",
                        "&ndash;": "–"]
        for (entity, replacement) in entities { text = text.replacingOccurrences(of: entity, with: replacement) }
        text = text.replacingOccurrences(of: "&#(\\d+);", with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
    }

    private static func model(_ raw: String, provider: String) -> (String, [String])? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch provider {
        case "anthropic":
            guard let match = capture(value, pattern: #"(?i)\bclaude\s+([a-z][a-z0-9-]*)\s+([0-9]+(?:[.-][0-9]+)*)\b"#),
                  match.count > 2 else { return nil }
            let suffix = match[2].replacingOccurrences(of: ".", with: "-")
            let canonical = "claude-\(match[1].lowercased())-\(suffix)"
            let display = match[0]
            return (canonical, [display, display.lowercased().replacingOccurrences(of: " ", with: "-")])
        case "deepseek":
            guard let match = capture(value, pattern: #"(?i)\bdeepseek[- ](flash|v[0-9]+(?:[.-][a-z0-9]+)*)\b"#),
                  match.count > 1 else { return nil }
            let canonical = "deepseek-\(match[1].lowercased().replacingOccurrences(of: "_", with: "-"))"
            let aliases = canonical == "deepseek-flash" ? [value] + deepSeekFlashAliases : [value]
            return (canonical, aliases)
        case "moonshot":
            guard let match = capture(value, pattern: #"(?i)\b(kimi-[a-z0-9][a-z0-9._-]*)\b"#),
                  match.count > 1 else { return nil }
            return (match[1].lowercased(), [value])
        case "xai":
            guard let match = capture(value, pattern: #"(?i)\b(grok[- ]?[0-9]+(?:\.[0-9]+)?(?:-[a-z0-9-]+)?)\b"#),
                  match.count > 1 else { return nil }
            let canonical = match[1].lowercased().replacingOccurrences(of: " ", with: "-")
            return (canonical, [value])
        default: return nil
        }
    }

    private static func capture(_ text: String, pattern: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let r = Range(match.range(at: index), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func money(_ text: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"(?i)(?:US\s*)?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[r].replacingOccurrences(of: ",", with: ""))
        }
    }

    private static func isFiveMinuteTier(_ header: String) -> Bool {
        let value = header.lowercased().replacingOccurrences(of: "-", with: " ")
        return value.contains("5m") || value.contains("5 min") || value.contains("5 minute")
    }

    private static func parseAnthropic(_ tables: [Table], _ url: String) -> [PriceCandidate] {
        var result: [PriceCandidate] = []
        for table in tables {
            let header = table.rows.first?.map { $0.lowercased() } ?? []
            guard let inputIndex = header.firstIndex(where: {
                $0.contains("input") && !$0.contains("cache") && !$0.contains("cached")
            }), let outputIndex = header.firstIndex(where: {
                $0.contains("output") && !$0.contains("cache")
            }) else { continue }
            let cacheReadIndex = header.firstIndex(where: {
                $0.contains("cache") && ($0.contains("read") || $0.contains("hit"))
            })
            let cacheWriteIndices = header.indices.filter {
                header[$0].contains("cache") && header[$0].contains("write")
            }
            let writeIndex = cacheWriteIndices.first(where: { isFiveMinuteTier(header[$0]) })
            for row in table.rows.dropFirst() {
                let label = row.joined(separator: " ")
                guard let model = model(label, provider: "anthropic"),
                      !label.localizedCaseInsensitiveContains("batch"),
                      !label.localizedCaseInsensitiveContains("long context"),
                      row.indices.contains(inputIndex), row.indices.contains(outputIndex),
                      let input = money(row[inputIndex]).first,
                      let output = money(row[outputIndex]).first else { continue }
                let cacheRead = cacheReadIndex.flatMap { row.indices.contains($0) ? money(row[$0]).first : nil } ?? 0
                let cacheWrite = writeIndex.flatMap { row.indices.contains($0) ? money(row[$0]).first : nil }
                    ?? input * 1.25
                let conditions = ["Standard API rates; uses the 5 minute cache-write tier when listed, otherwise applies the documented 1.25x input rate.",
                                  "Context, batch, residency, and cache TTL modifiers may not be present in source logs."]
                result.append(PriceCandidate(provider: "anthropic", model: model.0,
                    aliases: model.1, rates: PriceRate(input: input, output: output,
                        cacheRead: cacheRead, cacheWrite: cacheWrite), sourceURL: url,
                    conditions: conditions))
            }
        }
        return unique(result)
    }

    private static func parseMoonshot(_ tables: [Table], _ url: String) -> [PriceCandidate] {
        var result: [PriceCandidate] = []
        for table in tables {
            let header = table.rows.first?.map { $0.lowercased() } ?? []
            guard header.contains(where: { $0.contains("model") }),
                  header.contains(where: { $0.contains("output price") }) else { continue }
            for row in table.rows.dropFirst() {
                guard let rawModel = row.first, let model = model(rawModel, provider: "moonshot") else { continue }
                func value(_ headerNeedle: String) -> Double? {
                    guard let index = header.firstIndex(where: { $0.contains(headerNeedle) }),
                          row.indices.contains(index) else { return nil }
                    return money(row[index]).first
                }
                let inputIndex = header.firstIndex(where: {
                    $0.contains("input") && !$0.contains("cache") && !$0.contains("cached")
                })
                let inputMiss = value("cache miss")
                    ?? inputIndex.flatMap { row.indices.contains($0) ? money(row[$0]).first : nil }
                let output = value("output price")
                guard let inputMiss, let output else { continue }
                let cacheRead = value("cache hit") ?? value("cached input") ?? 0
                let cacheWriteIndex = header.indices.first(where: {
                    header[$0].contains("cache") && header[$0].contains("write")
                        && isFiveMinuteTier(header[$0])
                })
                let cacheWrite5m = cacheWriteIndex.flatMap { row.indices.contains($0) ? money(row[$0]).first : nil }
                    ?? 0
                let conditions = cacheWriteIndex == nil
                    ? ["The published model row has no separate cache-write rate.",
                       "A log without cache TTL or service tier is an estimate."]
                    : ["K3 cache-write estimate uses the documented default 5 minute TTL.",
                       "A log without cache TTL or service tier is an estimate."]
                result.append(PriceCandidate(provider: "moonshot", model: model.0,
                    aliases: model.1, rates: PriceRate(input: inputMiss, output: output,
                        cacheRead: cacheRead, cacheWrite: cacheWrite5m), sourceURL: url,
                    conditions: conditions))
            }
        }
        // A page may use merged cells or omit headers in a compact table. Read
        // those rows by the official column order as a conservative fallback.
        if result.isEmpty {
            for table in tables {
                for row in table.rows {
                    guard let rawModel = row.first, let model = model(rawModel, provider: "moonshot") else { continue }
                    let values = money(row.joined(separator: " "))
                    guard values.count >= (model.0 == "kimi-k3" ? 5 : 3) else { continue }
                    let k3 = model.0 == "kimi-k3"
                    result.append(PriceCandidate(provider: "moonshot", model: model.0,
                        aliases: model.1,
                        rates: k3
                            ? PriceRate(input: values[3], output: values[4], cacheRead: values[2], cacheWrite: values[0])
                            : PriceRate(input: values.count > 1 ? values[1] : values[0], output: values.last ?? 0,
                                        cacheRead: values.count > 1 ? values[0] : 0),
                        sourceURL: url,
                        conditions: ["Official tier or cache TTL is not fully identified in source logs; estimate uses the standard row."]))
                }
            }
        }
        return unique(result)
    }

    /// `deepseek-flash` is the API name; logs and relays use the versioned names.
    private static let deepSeekFlashAliases = ["deepseek-v4-flash", "deepseek-v4.1-flash"]

    private static func parseDeepSeek(_ tables: [Table], _ url: String) -> [PriceCandidate] {
        var modelNames: [String] = []
        for table in tables {
            for row in table.rows where row.joined(separator: " ").localizedCaseInsensitiveContains("deepseek") {
                let found = row.compactMap { model($0, provider: "deepseek")?.0 }
                if found.count >= 2 { modelNames = found; break }
            }
            if !modelNames.isEmpty { break }
        }
        if modelNames.isEmpty { modelNames = ["deepseek-flash", "deepseek-v4-pro"] }
        var category = ""
        var standard: [String: [String: Double]] = [:]
        for table in tables where table.text.localizedCaseInsensitiveContains("off-peak")
            && table.text.localizedCaseInsensitiveContains("cache hit") {
            for row in table.rows {
                let line = row.joined(separator: " ")
                if line.localizedCaseInsensitiveContains("cache hit") { category = "cache_read" }
                else if line.localizedCaseInsensitiveContains("cache miss") { category = "input" }
                else if line.localizedCaseInsensitiveContains("output tokens") { category = "output" }
                guard line.localizedCaseInsensitiveContains("off-peak") else { continue }
                let rates = money(line)
                guard rates.count >= modelNames.count else { continue }
                for (index, name) in modelNames.enumerated() where index < rates.count {
                    standard[name, default: [:]][category] = rates[index]
                }
            }
        }
        let result = standard.compactMap { name, rates -> PriceCandidate? in
            guard let input = rates["input"], let output = rates["output"] else { return nil }
            let model = name == "deepseek-v4-flash" ? "deepseek-flash" : name
            let aliases = model == "deepseek-flash" ? deepSeekFlashAliases : []
            return PriceCandidate(provider: "deepseek", model: model, aliases: aliases,
                rates: PriceRate(input: input, output: output,
                                 cacheRead: rates["cache_read"] ?? 0, cacheWrite: input),
                sourceURL: url,
                conditions: ["Estimate uses the documented off-peak API tier.",
                             "Cache-write tokens use the documented cache-miss input rate.",
                             "Peak-hour rates can differ; public holiday and request-tier details are not available in all logs."])
        }
        return unique(result)
    }

    private static func parseXAI(_ tables: [Table], _ url: String) -> [PriceCandidate] {
        var result: [PriceCandidate] = []
        for table in tables where table.text.localizedCaseInsensitiveContains("cached")
            && table.text.localizedCaseInsensitiveContains("output") {
            for row in table.rows {
                let line = row.joined(separator: " ")
                guard let rawModel = row.first,
                      let model = capture(rawModel, pattern: #"(?i)\b(grok-[a-z0-9][a-z0-9._-]*)\b"#),
                      model.count > 1 else { continue }
                let values = money(line)
                guard values.count >= 3 else { continue }
                let canonical = model[1].lowercased()
                result.append(PriceCandidate(provider: "xai", model: canonical,
                    aliases: [], rates: PriceRate(input: values[0], output: values[2],
                        cacheRead: values[1], cacheWrite: values[0]), sourceURL: url,
                    conditions: ["Estimate uses global standard short-context rates.",
                                 "Long-context, regional, priority, and batch modifiers require request details that logs may omit."]))
            }
        }
        return unique(result)
    }

    private static func parseOpenAI(_ tables: [Table], _ url: String) -> [PriceCandidate] {
        var result: [PriceCandidate] = []
        for table in tables {
            for headerIndex in table.rows.indices {
                let header = table.rows[headerIndex].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                // Flagship tables split short and long context; only the short
                // context columns are used because logs rarely carry the tier.
                let shortContext = header.contains("short context input")
                func usable(_ column: String) -> Bool { !column.contains("long context") }
                guard let modelIndex = header.firstIndex(where: { $0 == "model" || $0 == "name" }),
                      let inputIndex = header.indices.first(where: {
                          $0 > modelIndex && (header[$0] == "input" || header[$0] == "short context input")
                      }),
                      let outputIndex = header.indices.first(where: {
                          $0 > inputIndex && header[$0].contains("output") && !header[$0].contains("cost")
                              && usable(header[$0])
                      }) else { continue }
                // Older tables repeat "Input | ... | Output" for long context; a
                // cache column belongs to the short-context group before that.
                let groupEnd = header.indices.first(where: { $0 > inputIndex && header[$0] == "input" })
                    ?? header.count
                let cacheReadIndex = header.indices.first(where: {
                    $0 > inputIndex && $0 < groupEnd && header[$0].contains("cached input")
                        && usable(header[$0])
                })
                // The first write column is the shortest cache TTL tier (5m/30m).
                let cacheWriteIndex = header.indices.first(where: {
                    $0 > inputIndex && usable(header[$0])
                        && $0 < groupEnd
                        && (header[$0].contains("cache write") || (shortContext && header[$0].hasSuffix("write")))
                })
                for row in table.rows.dropFirst(headerIndex + 1) {
                    guard row.indices.contains(modelIndex), row.indices.contains(inputIndex),
                          row.indices.contains(outputIndex) else { continue }
                    var modelID = row[modelIndex]
                        .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]*\)"#,
                                              with: "$1", options: .regularExpression)
                        .replacingOccurrences(of: "`", with: "")
                        .replacingOccurrences(of: #"\s*\([^)]*context[^)]*\)\s*$"#,
                                              with: "", options: [.regularExpression, .caseInsensitive])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    modelID = modelID.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                    guard !modelID.isEmpty,
                          modelID.range(of: #"^[a-z0-9][a-z0-9._-]+$"#,
                                        options: .regularExpression) != nil,
                          let input = money(row[inputIndex]).first,
                          let output = money(row[outputIndex]).first else { continue }
                    let cached = cacheReadIndex.flatMap { row.indices.contains($0) ? money(row[$0]).first : nil } ?? 0
                    let cacheWrite = cacheWriteIndex.flatMap { row.indices.contains($0) ? money(row[$0]).first : nil } ?? 0
                    let conditions = shortContext
                        ? ["Estimate uses the standard short-context API rate and the shortest cache-write TTL tier.",
                           "Long-context, batch, fast-mode, and regional modifiers are not inferred without request details."]
                        : ["Estimate uses the standard short-context API rate.",
                           "Batch, long-context, fast-mode, and regional modifiers are not inferred without request details."]
                    result.append(PriceCandidate(provider: "openai", model: modelID,
                        aliases: [], rates: PriceRate(input: input, output: output,
                            cacheRead: cached, cacheWrite: cacheWrite), sourceURL: url,
                        conditions: conditions))
                }
            }
        }
        return unique(result)
    }

    /// Gemini pricing is a Markdoc page: one `## Name {% id="model" %}` section per
    /// model, with Standard/Batch/Flex/Priority tabs of `* cell` rows split by `---`.
    /// Only the Standard tab's paid-tier column is used. Rates published as
    /// "$x through <date>. $y starting <date>." become dated versions.
    private static func parseGemini(_ source: String, _ url: String) -> [PriceCandidate] {
        let headingRegex = try! NSRegularExpression(
            pattern: #"(?m)^##\s+[^\n]*?\{%\s*id="(gemini-[a-z0-9.-]+)"\s*%\}"#)
        let full = NSRange(source.startIndex..., in: source)
        let headings = headingRegex.matches(in: source, range: full).compactMap { match -> (String.Index, String)? in
            guard let whole = Range(match.range, in: source),
                  let id = Range(match.range(at: 1), in: source) else { return nil }
            return (whole.lowerBound, String(source[id]))
        }
        var result: [PriceCandidate] = []
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].0 : source.endIndex
            var section = String(source[heading.0..<end])
            if let tab = section.range(of: #"{% tab title="Standard" %}"#) {
                section = String(section[tab.upperBound...])
                if let close = section.range(of: "{% /tab %}") { section = String(section[..<close.lowerBound]) }
            } else if let close = section.range(of: "{% /table %}") {
                section = String(section[..<close.lowerBound])
            }
            var fields: [String: GeminiRate] = [:]
            let rows = section.replacingOccurrences(of: #"(?m)^[ \t]*---[ \t]*$"#, with: "\u{1E}",
                                                    options: .regularExpression)
                .components(separatedBy: "\u{1E}")
            for row in rows {
                let cells = row.components(separatedBy: "\n").reduce(into: [String]()) { cells, line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("* ") { cells.append(String(trimmed.dropFirst(2))) }
                    else if !trimmed.isEmpty, !trimmed.hasPrefix("{%"), !cells.isEmpty { cells[cells.count - 1] += " " + trimmed }
                }
                guard cells.count >= 2, let paid = cells.last else { continue }
                let label = cells[0].lowercased()
                let field: String
                if label.hasPrefix("input price") { field = "input" }
                else if label.hasPrefix("output price") { field = "output" }
                else if label.hasPrefix("context caching price") { field = "cache_read" }
                else { continue }
                if let rate = geminiRate(paid) { fields[field] = rate }
            }
            guard let input = fields["input"], let output = fields["output"] else { continue }
            let cache = fields["cache_read"]
            var conditions = ["Estimate uses the Standard paid-tier rate; Batch, Flex, and Priority tiers are not inferred.",
                              "Cache-write tokens use the input rate; context-cache storage is not billed per token."]
            if [input, output].contains(where: \.isTiered) {
                conditions.append("Prompt-length tiers are not in the logs; the estimate uses the first (shortest prompt) tier.")
            }
            let expiry = [input.throughMs, output.throughMs, cache?.throughMs].compactMap { $0 }.min()
            result.append(PriceCandidate(provider: "google", model: heading.1, aliases: [],
                rates: PriceRate(input: input.current, output: output.current,
                                 cacheRead: cache?.current ?? 0, cacheWrite: input.current),
                sourceURL: url, conditions: conditions, effectiveAtMs: nil, expiresAtMs: expiry))
            let dates = Set([input.starting, output.starting, cache?.starting].compactMap { $0?.atMs })
            for date in dates.sorted() {
                func value(_ rate: GeminiRate?) -> Double? {
                    guard let rate else { return nil }
                    if let start = rate.starting, start.atMs <= date { return start.value }
                    return rate.current
                }
                result.append(PriceCandidate(provider: "google", model: heading.1, aliases: [],
                    rates: PriceRate(input: value(input) ?? 0, output: value(output) ?? 0,
                                     cacheRead: value(cache) ?? 0, cacheWrite: value(input) ?? 0),
                    sourceURL: url, conditions: conditions + ["Effective date as published on the official page (00:00 US Pacific)."],
                    effectiveAtMs: date))
            }
        }
        return result
    }

    private struct GeminiRate: Equatable {
        var current: Double
        var throughMs: Int64?
        var starting: (value: Double, atMs: Int64)?
        var isTiered: Bool

        static func == (lhs: GeminiRate, rhs: GeminiRate) -> Bool {
            lhs.current == rhs.current && lhs.throughMs == rhs.throughMs
                && lhs.starting?.value == rhs.starting?.value && lhs.starting?.atMs == rhs.starting?.atMs
                && lhs.isTiered == rhs.isTiered
        }
    }

    private static func geminiRate(_ text: String) -> GeminiRate? {
        // Media models can price output per image or second; that is not a token rate.
        if text.range(of: #"^\s*\$\s*[0-9][0-9,]*(?:\.[0-9]+)?\s+per\s+(image|second|minute|hour|request|character)"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let datePattern = #"([A-Z][a-z]+ [0-9]{1,2}, [0-9]{4})"#
        let through = capture(text, pattern: #"\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s+through\s+"# + datePattern)
        let starting = capture(text, pattern: #"\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s+starting\s+"# + datePattern)
        if let through, through.count > 2, let value = Double(through[1].replacingOccurrences(of: ",", with: "")),
           let lastDay = pacificMidnightMs(through[2]) {
            var rate = GeminiRate(current: value, throughMs: lastDay + 86_400_000 - 1, starting: nil, isTiered: false)
            if let starting, starting.count > 2,
               let next = Double(starting[1].replacingOccurrences(of: ",", with: "")),
               let at = pacificMidnightMs(starting[2]) {
                rate.starting = (next, at)
            }
            return rate
        }
        let values = money(text)
        guard let first = values.first else { return nil }
        return GeminiRate(current: first, throughMs: nil, starting: nil, isTiered: values.count > 1)
    }

    private static func pacificMidnightMs(_ text: String) -> Int64? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    /// MiniMax publishes Standard then Priority tables; `unique` keeps Standard.
    /// Rows above a context threshold ("> 512k") are skipped, and a row with a
    /// permanent discount lists the list price first and the charged price last.
    private static func parseMiniMax(_ tables: [Table], _ url: String) -> [PriceCandidate] {
        var result: [PriceCandidate] = []
        for table in tables {
            guard let header = table.rows.first?.map({ $0.lowercased() }),
                  let inputIndex = header.firstIndex(where: { $0.contains("input") }),
                  let outputIndex = header.firstIndex(where: { $0.contains("output") }) else { continue }
            let cacheIndex = header.firstIndex(where: { $0.contains("cach") && $0.contains("read") })
            for row in table.rows.dropFirst() {
                guard let label = row.first,
                      // Text models only (M series); media tables price per second or image.
                      let match = capture(label, pattern: #"(?i)\b(minimax-m[0-9][a-z0-9.-]*)\b"#),
                      match.count > 1, !label.contains(">"),
                      row.indices.contains(inputIndex), row.indices.contains(outputIndex) else { continue }
                let discounted = label.range(of: #"(?i)[0-9]+%\s*off"#, options: .regularExpression) != nil
                func price(_ index: Int?) -> Double? {
                    guard let index, row.indices.contains(index) else { return nil }
                    let values = money(row[index])
                    return discounted ? values.last : values.first
                }
                guard let input = price(inputIndex), let output = price(outputIndex) else { continue }
                var conditions = ["Estimate uses the Standard service tier; Priority requests are not identified in logs.",
                                  "Cache-write tokens use the input rate."]
                if label.contains("≤") || label.contains("<=") {
                    conditions.append("Uses the shortest input-length tier; longer-context requests are billed higher.")
                }
                if discounted { conditions.append("Uses the published discounted price.") }
                result.append(PriceCandidate(provider: "minimax", model: match[1], aliases: [],
                    rates: PriceRate(input: input, output: output,
                                     cacheRead: price(cacheIndex) ?? 0, cacheWrite: input),
                    sourceURL: url, conditions: conditions))
            }
        }
        return unique(result)
    }

    private static func unique(_ rows: [PriceCandidate]) -> [PriceCandidate] {
        var seen: Set<String> = []
        return rows.filter { seen.insert("\($0.provider):\(PriceTable.modelKey($0.model))").inserted }
    }
}

extension PriceTable {
    static func modelKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
