import Foundation
import TokenTrackerCore

/// App refresh boundary: official display values and optional historical samples.
enum QuotaRefresh {
    static func load(store: UsageStore, config: QuotasConfig, results: [String: OfficialResult],
                     accountID: String, publish: ([MenuBarQuotaEntry]) -> Void) throws {
        let quotas = try QuotaEstimator.compute(store: store, config: config, nowMs: store.nowMs()) { results[$0] }
        publish(quotas.map { result in
            var entry = MenuBarQuotaEntry(result: result)
            let provider = config.entries.first { $0.id == result.id }?.official
            entry.sampledAt = provider.flatMap { results[$0]?.sampledAt }
            return entry
        })

        // A long scan owns the write transaction. History is optional and must
        // neither suppress official values nor stall the next quota refresh.
        let previousTimeout = try store.conn.scalarInt("PRAGMA busy_timeout")
        try store.conn.execute("PRAGMA busy_timeout=50")
        defer { _ = try? store.conn.execute("PRAGMA busy_timeout=\(previousTimeout)") }
        for (provider, result) in results where result.error == nil && result.staleMin == nil {
            guard let sampled = result.sampledAt else { continue }
            for (window, value) in result.windows ?? [:] {
                if let pct = value.pct {
                    let reset = value.resetsAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                        .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
                    let identity = provider + ":" + (provider == "codex" ? accountID : "current") + ":" + window
                    do {
                        try store.recordQuota(QuotaSample(identity: identity, at: Int64(sampled * 1000), pct: pct, resetsAt: reset))
                    } catch {
                        // Retry with the next normal refresh after the writer releases.
                        return
                    }
                }
            }
        }
    }
}
