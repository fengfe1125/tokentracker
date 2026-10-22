//
//  SubscriptionModels.swift
//  TokenTrackerCore
//
//  订阅配额与余额的独立模型：账号、额度窗口、余额、查询状态。
//  与菜单栏展示模型分离，保留账号、余额和重置时间。凭据只在内存中，
//  从不进入 Codable 快照、缓存或日志。
//

import Foundation
import CryptoKit

// ------------------------------------------------------------ 供应商 ----

/// 固定顺序（allCases 的顺序即卡片顺序）。
public enum SubscriptionProvider: String, CaseIterable, Codable, Sendable {
    case claude, codex, kimi, go, deepseek, copilot, gemini, minimax, grok
    case workbuddy, workbuddyAI = "workbuddy-ai", zcode, zenFree = "opencode-zen-free"

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        case .go: return "OpenCode Go"
        case .deepseek: return "DeepSeek"
        case .copilot: return "GitHub Copilot"
        case .gemini: return "Gemini"
        case .minimax: return "MiniMax"
        case .grok: return "Grok"
        case .workbuddy: return "WorkBuddy"
        case .workbuddyAI: return "WorkBuddy AI"
        case .zcode: return "ZCode"
        case .zenFree: return "OpenCode Zen Free"
        }
    }

    /// 菜单栏圆环使用的 id（与 settings.menubar_provider 兼容）。
    public var menuBarID: String? {
        switch self {
        case .claude, .codex, .kimi, .go: return rawValue
        default: return nil
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? Int.max }
}

// ---------------------------------------------------------------- 来源 ----

/// 已发现的配置来源（展示用；路径以 ~ 缩写，不含凭据）。
public struct SubscriptionSource: Hashable, Comparable, Sendable {
    public var tool: String       // "Claude Code"、"Magpie"、"OpenCode" …
    public var location: String   // "~/.codex/auth.json"、"钥匙串"、"DEEPSEEK_API_KEY" …

    public init(tool: String, location: String) {
        self.tool = tool
        self.location = location
    }

    public static func < (a: Self, b: Self) -> Bool { (a.tool, a.location) < (b.tool, b.location) }
}

// ---------------------------------------------------------------- 凭据 ----

/// 内存中的凭据。不是 Codable，不进入快照、缓存和诊断。
struct SubscriptionCredential: Equatable, Sendable {
    enum Kind: Sendable { case oauth, apiKey }
    var kind: Kind
    var token: String
    var expiresAt: Date?
    /// 供应商专用字段（Codex 账号 ID、WorkBuddy uid/domain、ZCode 状态、MiniMax 区域…）
    var extra: [String: String] = [:]

    var fingerprint: String {
        subscriptionHash(([token] + extra.keys.sorted().map { $0 + "=" + extra[$0]! }).joined(separator: "\u{0}"))
    }
}

// ---------------------------------------------------------------- 账号 ----

public struct SubscriptionAccount: Identifiable, Equatable, Sendable {
    public let provider: SubscriptionProvider
    /// 稳定 id：有供应商账号 ID 时由其派生，否则由凭据派生（哈希，不可逆）。
    public internal(set) var id: String
    /// 账号名或邮箱（仅展示）。
    public internal(set) var label: String
    public internal(set) var planHint: String
    public internal(set) var sources: [SubscriptionSource]
    /// 来自该供应商自家工具的当前登录（菜单栏只绑定这一类账号）。
    public internal(set) var isActive: Bool
    /// 发现阶段即知的问题（如只发现 API Key、免费模型）。
    public internal(set) var discoveryProblem: SubscriptionProblem?

    var credential: SubscriptionCredential?
    /// 供应商账号 ID（去重依据）；仅内存。
    var providerAccountID: String?

    init(provider: SubscriptionProvider, label: String = "", planHint: String = "",
         source: SubscriptionSource, isActive: Bool = false,
         credential: SubscriptionCredential?, providerAccountID: String? = nil,
         discoveryProblem: SubscriptionProblem? = nil) {
        self.provider = provider
        self.label = label
        self.planHint = planHint
        self.sources = [source]
        self.isActive = isActive
        self.credential = credential
        self.providerAccountID = providerAccountID.flatMap { $0.isEmpty ? nil : $0 }
        self.discoveryProblem = discoveryProblem
        self.id = ""
        self.id = Self.makeID(provider: provider, accountID: self.providerAccountID,
                              credential: credential, source: source)
    }

    static func makeID(provider: SubscriptionProvider, accountID: String?,
                       credential: SubscriptionCredential?, source: SubscriptionSource) -> String {
        let basis = accountID.map { "account:" + $0 }
            ?? credential.map { "credential:" + $0.token }
            ?? "source:" + source.tool + ":" + source.location
        return provider.rawValue + ":" + String(subscriptionHash(provider.rawValue + "|" + basis).prefix(16))
    }

    /// 供应商账号身份的哈希（与查询后返回的 accountKey 同一口径）。
    var accountKey: String? {
        providerAccountID.map { subscriptionHash(provider.rawValue + "|" + $0) }
    }

    /// API Key 的尾号（仅后 4 位，用于区分多把 Key）；OAuth 账号为空。
    public var keyHint: String {
        guard let credential, credential.kind == .apiKey, credential.token.count >= 12 else { return "" }
        return "····" + String(credential.token.suffix(4))
    }

    /// 邮箱缩写：abc…@example.com；无标签时返回空串（界面另行处理）。
    public var shortLabel: String {
        guard let at = label.firstIndex(of: "@") else { return label }
        let name = label[..<at]
        return (name.count > 3 ? String(name.prefix(3)) + "…" : String(name)) + String(label[at...])
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.label == b.label && a.planHint == b.planHint && a.sources == b.sources
            && a.isActive == b.isActive && a.discoveryProblem == b.discoveryProblem
            && a.credential?.fingerprint == b.credential?.fingerprint
    }
}

// ---------------------------------------------------------- 窗口与余额 ----

public struct SubscriptionWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// 供应商给出的名称（模型名、套餐包名等）；nil 时按 duration 命名。
    public var name: String?
    /// 窗口长度（秒），未知为 nil。
    public var duration: Int?
    /// 已用百分比；官方未给出时为 nil（显示 “—”）。
    public var usedPercent: Double?
    public var used: Decimal?
    public var limit: Decimal?
    public var unit: String?
    public var resetsAt: Date?

    public init(id: String, name: String? = nil, duration: Int? = nil, usedPercent: Double?,
                used: Decimal? = nil, limit: Decimal? = nil, unit: String? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.name = name
        self.duration = duration
        self.usedPercent = usedPercent
        self.used = used
        self.limit = limit
        self.unit = unit
        self.resetsAt = resetsAt
    }
}

public struct SubscriptionBalance: Codable, Equatable, Identifiable, Sendable {
    public var currency: String
    public var total: Decimal?
    public var granted: Decimal?
    public var toppedUp: Decimal?
    public var id: String { currency }

    public init(currency: String, total: Decimal?, granted: Decimal?, toppedUp: Decimal?) {
        self.currency = currency
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
    }
}

// ---------------------------------------------------------------- 状态 ----

public enum SubscriptionStatus: String, Codable, Sendable {
    case loading        // 加载中
    case current        // 最新官方数据
    case stale          // 过期官方数据（24 小时内）
    case signedOut      // 未登录 / 未找到凭据
    case expired        // 凭据失效
    case forbidden      // 权限不足
    case failed         // 请求失败
    case unsupported    // 暂不支持
}

/// 错误类别（界面据此本地化；诊断只记录类别）。
public enum SubscriptionProblem: String, Codable, Sendable {
    case noCredential
    case credentialExpired
    case unauthorized
    case forbidden
    case rateLimited
    case timeout
    case network
    case httpStatus
    case malformed
    case noWindows
    case untrustedEndpoint
    case apiKeyOnly          // 只发现 API Key，无法读取订阅配额
    case freeModel           // 免费模型，没有账号额度
    case relayEndpoint       // Key 配置给第三方中转，不发往官方
    case enterpriseUnsupported
    case noSubscription      // 官方明确返回：账号没有有效订阅
    case balanceUnavailable  // 余额不足以调用 API（DeepSeek is_available=false）
}

/// 一次查询结果。可安全持久化：不含令牌、原始账号 ID、邮箱或路径。
public struct SubscriptionSnapshot: Codable, Equatable, Sendable {
    public var status: SubscriptionStatus
    public var windows: [SubscriptionWindow] = []
    public var balances: [SubscriptionBalance] = []
    public var plan: String = ""
    public var sampledAt: Date?
    public var problem: SubscriptionProblem?
    public var httpStatus: Int?
    public var retryAt: Date?
    /// 依赖非公开接口：接口变化时降为不可用。
    public var privateAPI: Bool = false
    /// 供应商账号 ID 的哈希（查询后得到，用于跨来源去重）。
    public var accountKey: String?

    public init(status: SubscriptionStatus, windows: [SubscriptionWindow] = [],
                balances: [SubscriptionBalance] = [], plan: String = "", sampledAt: Date? = nil,
                problem: SubscriptionProblem? = nil, httpStatus: Int? = nil, retryAt: Date? = nil,
                privateAPI: Bool = false, accountKey: String? = nil) {
        self.status = status
        self.windows = windows
        self.balances = balances
        self.plan = plan
        self.sampledAt = sampledAt
        self.problem = problem
        self.httpStatus = httpStatus
        self.retryAt = retryAt
        self.privateAPI = privateAPI
        self.accountKey = accountKey
    }

    static func failure(_ status: SubscriptionStatus, _ problem: SubscriptionProblem,
                        http: Int? = nil, retryAt: Date? = nil) -> Self {
        SubscriptionSnapshot(status: status, problem: problem, httpStatus: http, retryAt: retryAt)
    }
}

public struct SubscriptionCard: Identifiable, Equatable, Sendable {
    public var account: SubscriptionAccount
    public var snapshot: SubscriptionSnapshot
    public var id: String { account.id }

    public init(account: SubscriptionAccount, snapshot: SubscriptionSnapshot) {
        self.account = account
        self.snapshot = snapshot
    }

    /// 固定排序：供应商 → 当前登录优先 → 标签 → id。
    static func ordered(_ a: Self, _ b: Self) -> Bool {
        if a.account.provider != b.account.provider { return a.account.provider.order < b.account.provider.order }
        if a.account.isActive != b.account.isActive { return a.account.isActive }
        if a.account.label != b.account.label { return a.account.label < b.account.label }
        return a.account.id < b.account.id
    }
}

// ---------------------------------------------------------------- 工具 ----

func subscriptionHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// 金额/数量按 Decimal 解析；非数字（含布尔）返回 nil，绝不当作 0。
func subscriptionDecimal(_ value: Any?) -> Decimal? {
    let text: String
    if let s = value as? String {
        text = s.trimmingCharacters(in: .whitespaces)
    } else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
        guard n.doubleValue.isFinite else { return nil }
        text = n.stringValue
    } else {
        return nil
    }
    guard text.range(of: #"^-?\d+(\.\d+)?([eE][-+]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
    return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
}

func subscriptionNumber(_ value: Any?) -> Double? {
    BillingNet.pct(value)
}

/// 秒或毫秒时间戳、ISO 8601 字符串 → Date。
func subscriptionDate(_ value: Any?) -> Date? {
    if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
        let t = n.doubleValue
        guard t.isFinite, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t)
    }
    guard let s = value as? String, !s.isEmpty else { return nil }
    if let t = Double(s) { return subscriptionDate(NSNumber(value: t)) }
    let f = ISO8601DateFormatter()
    if let date = f.date(from: s) { return date }
    f.formatOptions.insert(.withFractionalSeconds)
    return f.date(from: s)
}

/// JWT 载荷（不验签，只用于读取 exp、账号 ID 等公开声明）。
func subscriptionJWTClaims(_ token: String) -> [String: Any] {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return [:] }
    var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    guard let data = Data(base64Encoded: s) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}
