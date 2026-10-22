import Foundation
import TokenTrackerCore

/// App refresh boundary: menu bar entries come only from the active account's
/// official snapshot; history samples are optional.
enum QuotaRefresh {
    static let menuBarProviders: [SubscriptionProvider] = [.claude, .kimi, .go, .codex]

    /// One entry per menu bar provider. Without a single active account, or
    /// without official data, the entry has no windows (shown as unavailable).
    static func menuEntries(_ cards: [SubscriptionCard]) -> [MenuBarQuotaEntry] {
        menuBarProviders.map { provider in
            let id = provider.menuBarID ?? provider.rawValue
            guard let card = SubscriptionService.menuBarCard(cards, provider: provider),
                  card.snapshot.status == .current || card.snapshot.status == .stale else {
                return MenuBarQuotaEntry(id: id, name: provider.displayName, windows: [])
            }
            let stale = card.snapshot.status == .stale
            return MenuBarQuotaEntry(
                id: id, name: provider.displayName,
                windows: card.snapshot.windows.map {
                    MenuBarQuotaWindow(pct: $0.usedPercent, source: "official", stale: stale, label: windowLabel($0))
                },
                sampledAt: card.snapshot.sampledAt?.timeIntervalSince1970, via: "official")
        }
    }

    /// Built-in labels stay compatible with UIFormat.quotaLabel localization.
    static func windowLabel(_ window: SubscriptionWindow) -> String {
        if let name = window.name { return name }
        switch window.duration {
        case 18_000: return "5 小时"
        case 604_800: return "周 (7天)"
        case 2_592_000, 2_678_400: return "月度"
        case let seconds?: return seconds % 86_400 == 0 ? "\(seconds / 86_400)d" : "\(seconds / 3600)h"
        case nil: return window.id
        }
    }

    /// Records fresh official percentages of active accounts. A long scan owns the
    /// write transaction; history must never stall or suppress display values.
    static func record(store: UsageStore, cards: [SubscriptionCard]) throws {
        let previousTimeout = try store.conn.scalarInt("PRAGMA busy_timeout")
        try store.conn.execute("PRAGMA busy_timeout=50")
        defer { _ = try? store.conn.execute("PRAGMA busy_timeout=\(previousTimeout)") }
        for provider in menuBarProviders {
            guard let card = SubscriptionService.menuBarCard(cards, provider: provider),
                  card.snapshot.status == .current, let sampled = card.snapshot.sampledAt else { continue }
            let account = String(card.account.id.split(separator: ":").last ?? "")
            for window in card.snapshot.windows {
                guard let pct = window.usedPercent else { continue }
                let reset = window.resetsAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
                let identity = provider.rawValue + ":" + account + ":" + window.id
                do {
                    try store.recordQuota(QuotaSample(identity: identity, at: Int64(sampled.timeIntervalSince1970 * 1000),
                                                      pct: pct, resetsAt: reset))
                } catch {
                    // Retry with the next normal refresh after the writer releases.
                    return
                }
            }
        }
    }
}
