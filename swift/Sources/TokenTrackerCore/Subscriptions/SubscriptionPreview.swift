//
//  SubscriptionPreview.swift
//  TokenTrackerCore
//
//  TT_UI_PREVIEW 使用的虚构卡片：覆盖两行/三行配额、余额、长账号名、
//  过期与各类错误状态。不含任何真实账号或凭据。
//

import Foundation

extension SubscriptionCard {
    public static func previewCards(now: Date = Date()) -> [SubscriptionCard] {
        func account(_ provider: SubscriptionProvider, _ label: String, _ tool: String, _ location: String,
                     active: Bool = false, plan: String = "") -> SubscriptionAccount {
            var a = SubscriptionAccount(provider: provider, label: label, planHint: plan,
                                        source: SubscriptionSource(tool: tool, location: location), isActive: active,
                                        credential: provider == .deepseek
                                            ? SubscriptionCredential(kind: .apiKey, token: "sk-preview-fixture-0042")
                                            : SubscriptionCredential(kind: .oauth, token: "preview-" + label))
            a.id = provider.rawValue + ":preview-" + String(subscriptionHash(provider.rawValue + label).prefix(8))
            return a
        }
        func window(_ id: String, _ duration: Int?, _ pct: Double?, name: String? = nil, hours: Double) -> SubscriptionWindow {
            SubscriptionWindow(id: id, name: name, duration: duration, usedPercent: pct,
                               resetsAt: now.addingTimeInterval(hours * 3600))
        }
        let sampled = now.addingTimeInterval(-90)
        return [
            SubscriptionCard(account: account(.claude, "preview.user@example.com", "Claude Code", "钥匙串", active: true),
                             snapshot: SubscriptionSnapshot(status: .current, windows: [
                                window("five_hour", 18_000, 42, hours: 2.5), window("seven_day", 604_800, 18, hours: 96),
                                window("seven_day_opus", 604_800, 0, name: "Opus", hours: 96)],
                                plan: "Max", sampledAt: sampled)),
            SubscriptionCard(account: account(.codex, "a.very.long.preview.account.name@subdomain.example.org", "Codex",
                                              "~/.codex/auth.json", active: true),
                             snapshot: SubscriptionSnapshot(status: .current, windows: [
                                window("primary_window", 18_000, 7, hours: 4), window("secondary_window", 604_800, 63, hours: 30)],
                                plan: "Plus", sampledAt: sampled)),
            SubscriptionCard(account: account(.kimi, "", "Kimi Code", "~/.kimi-code", active: true),
                             snapshot: SubscriptionSnapshot(status: .stale, windows: [
                                window("limit-0", 18_000, 91, hours: 1), window("usage", 604_800, 55, hours: 50)],
                                plan: "中级版", sampledAt: now.addingTimeInterval(-3 * 3600), problem: .rateLimited, httpStatus: 429)),
            SubscriptionCard(account: account(.deepseek, "", "DSH", "~/.dsh/.credentials.yaml"),
                             snapshot: SubscriptionSnapshot(status: .current, balances: [
                                SubscriptionBalance(currency: "CNY", total: Decimal(string: "110.00"),
                                                    granted: Decimal(string: "10.00"), toppedUp: Decimal(string: "100.00"))],
                                sampledAt: sampled)),
            SubscriptionCard(account: account(.copilot, "", "OpenCode", "~/.local/share/opencode/auth.json"),
                             snapshot: .failure(.expired, .unauthorized, http: 401)),
            SubscriptionCard(account: account(.gemini, "preview@example.com", "Gemini CLI", "~/.gemini/oauth_creds.json"),
                             snapshot: .failure(.expired, .credentialExpired)),
            SubscriptionCard(account: account(.grok, "preview-grok", "Magpie", "~/.config/magpie/plugin-auth.json"),
                             snapshot: SubscriptionSnapshot(status: .current, windows: [
                                window("credits", 604_800, 0, hours: 120)], sampledAt: sampled, privateAPI: true)),
            SubscriptionCard(account: account(.zenFree, "", "Magpie", "~/.config/magpie/plugin-auth.json"),
                             snapshot: .failure(.unsupported, .freeModel)),
        ]
    }
}
