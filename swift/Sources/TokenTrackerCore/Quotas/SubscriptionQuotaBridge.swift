//
//  SubscriptionQuotaBridge.swift
//  TokenTrackerCore
//
//  QuotaEstimator 的官方数据来源：TokenTracker 账号库的订阅快照（与 App 状态栏同源）。
//  不读取 Claude Code / Codex / Kimi 等工具自己的登录态，也不刷新或回写它们。
//

import Foundation

public enum SubscriptionQuotaBridge {
    /// QuotasConfig.official → 订阅供应商。
    static let providers: [String: SubscriptionProvider] = [
        "claude-oauth": .claude, "kimi": .kimi, "codex": .codex, "go": .go,
    ]

    /// 订阅窗口时长 → 配额窗口键；不认识的窗口不参与固定窗口比对。
    static func windowKey(_ window: SubscriptionWindow) -> String? {
        switch window.duration {
        case 18_000: return "5h"
        case 604_800: return "7d"
        case 2_592_000, 2_678_400: return "month"
        default: return nil
        }
    }

    /// 选中供应商唯一的当前账号（与状态栏同口径）。没有账号或无法确定时返回 nil，
    /// 由调用方降级为本地估算。
    public static func officialResult(_ official: String, cards: [SubscriptionCard],
                                      now: Date = Date()) -> OfficialResult? {
        guard let provider = providers[official],
              let card = SubscriptionService.menuBarCard(cards, provider: provider) else { return nil }
        let snapshot = card.snapshot
        guard snapshot.status == .current || snapshot.status == .stale else {
            return OfficialResult(error: snapshot.problem?.rawValue ?? snapshot.status.rawValue,
                                  detail: snapshot.status.rawValue)
        }
        var windows: [String: OfficialWindow] = [:]
        let iso = ISO8601DateFormatter()
        for window in snapshot.windows {
            guard let key = windowKey(window), windows[key] == nil else { continue }
            windows[key] = OfficialWindow(
                pct: window.usedPercent,
                used: window.used.map { NSDecimalNumber(decimal: $0).doubleValue },
                limit: window.limit.map { NSDecimalNumber(decimal: $0).doubleValue },
                resetsAt: window.resetsAt.map { iso.string(from: $0) },
                unit: window.unit)
        }
        var staleMin: Int?
        if snapshot.status == .stale, let sampled = snapshot.sampledAt {
            staleMin = max(1, Int(now.timeIntervalSince(sampled) / 60))
        }
        return OfficialResult(windows: windows, sampledAt: snapshot.sampledAt?.timeIntervalSince1970,
                              staleMin: staleMin, plan: snapshot.plan.isEmpty ? nil : snapshot.plan,
                              via: "subscription")
    }
}
