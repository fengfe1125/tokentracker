import Foundation
import CryptoKit

public enum SubscriptionStatus: String, Codable, Sendable {
    case loading, current, stale, signedOut, expired, forbidden, failed, unsupported
}

public struct SubscriptionAccount: Identifiable, Sendable, Equatable {
    public let provider: String
    public let identity: String
    public var label: String
    public var plan: String
    public var sources: [String]
    public var active: Bool
    // In memory only. Never Codable, logged, or placed in display/cache records.
    let credential: [String: String]
    public var id: String { provider + ":" + identity }
    var fingerprint: String {
        subscriptionHash(credential.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "\u{0}"))
    }
    public var displayLabel: String {
        if let at = label.firstIndex(of: "@") {
            return String(label[..<at].prefix(3)) + "…" + String(label[at...])
        }
        return label.isEmpty ? String(identity.prefix(8)) : label
    }
    public var providerName: String { Self.names[provider] ?? provider }
    public static let names = ["claude": "Claude Code", "codex": "Codex", "kimi": "Kimi",
        "go": "OpenCode Go", "deepseek": "DeepSeek", "copilot": "GitHub Copilot", "gemini": "Gemini",
        "minimax": "MiniMax", "grok": "Grok", "workbuddy": "WorkBuddy", "workbuddy-ai": "WorkBuddy AI",
        "zcode": "ZCode", "opencode-zen-free": "OpenCode Zen Free"]
}

public struct SubscriptionWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double?
    public var used: Decimal?
    public var limit: Decimal?
    public var unit: String?
    public var resetsAt: Date?
}

public struct SubscriptionBalance: Codable, Equatable, Sendable, Identifiable {
    public var currency: String
    public var total: Decimal?
    public var granted: Decimal?
    public var toppedUp: Decimal?
    public var id: String { currency }
}

/// Safe to persist: no tokens, raw account IDs, emails or credential paths.
public struct SubscriptionSnapshot: Codable, Equatable, Sendable {
    public var status: SubscriptionStatus
    public var windows: [SubscriptionWindow] = []
    public var balances: [SubscriptionBalance] = []
    public var plan: String = ""
    public var sampledAt: Date?
    public var message: String = ""
    public var retryAt: Date?
    public var privateAPI: Bool = false
}

public struct SubscriptionCard: Identifiable, Sendable, Equatable {
    public var account: SubscriptionAccount
    public var snapshot: SubscriptionSnapshot
    public var id: String { account.id }
}

func subscriptionHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func subscriptionDecimal(_ value: Any?) -> Decimal? {
    let text: String
    if let s = value as? String { text = s }
    else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { text = n.stringValue }
    else { return nil }
    guard text.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
    return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
}

func subscriptionDate(_ value: Any?) -> Date? {
    if let n = value as? NSNumber {
        let t = n.doubleValue
        return t > 0 ? Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t) : nil
    }
    guard let s = value as? String else { return nil }
    let f = ISO8601DateFormatter()
    if let date = f.date(from: s) { return date }
    f.formatOptions.insert(.withFractionalSeconds)
    return f.date(from: s)
}

extension SubscriptionStatus { public var label: String { switch self { case .loading: return "读取中"; case .current: return "官方最新"; case .stale: return "官方过期"; case .signedOut: return "未登录"; case .expired: return "凭据失效"; case .forbidden: return "无权限"; case .failed: return "读取失败"; case .unsupported: return "暂不支持" } } }
