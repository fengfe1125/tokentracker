//
//  QuotaEstimator.swift
//  TokenTrackerCore
//
//  移植自 tokentracker/quotas.py：固定窗口（5 小时 / 7 天 / 月度），
//  官方数据优先、本地估算兜底。官方抓取在 Phase 3（billing.py 移植），
//  这里只留 officialProvider 注入缝。
//

import Foundation

// ------------------------------------------------------------ 配置模型 ----

public struct QuotaWindowConfig: Codable, Equatable, Sendable {
    public var label: String?
    public var limitTokens: Int64?
    public var limitUSD: Double?

    enum CodingKeys: String, CodingKey {
        case label
        case limitTokens = "limit_tokens"
        case limitUSD = "limit_usd"
    }
}

public struct QuotaEntryConfig: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var plan: String?
    public var tool: String
    public var modelPrefix: String?
    public var official: String?
    public var includeCache: Bool?
    public var windows: [String: QuotaWindowConfig]

    enum CodingKeys: String, CodingKey {
        case id, name, plan, tool, official, windows
        case modelPrefix = "model_prefix"
        case includeCache = "include_cache"
    }
}

public struct QuotasConfig: Codable, Equatable, Sendable {
    public var entries: [QuotaEntryConfig]

    /// 与 Python DEFAULT_QUOTAS 一致的内置配置。
    public static let `default` = QuotasConfig(entries: [
        QuotaEntryConfig(id: "claude", name: "Claude Code", plan: "Pro/Max",
                         tool: "claude", modelPrefix: nil, official: "claude-oauth",
                         includeCache: nil, windows: [
                            "5h": QuotaWindowConfig(label: "5 小时", limitTokens: 100_000_000, limitUSD: nil),
                            "7d": QuotaWindowConfig(label: "周 (7天)", limitTokens: 400_000_000, limitUSD: nil),
                         ]),
        QuotaEntryConfig(id: "kimi", name: "Kimi", plan: "Kimi for Coding",
                         tool: "kimi", modelPrefix: nil, official: "kimi",
                         includeCache: nil, windows: [
                            "5h": QuotaWindowConfig(label: "5 小时", limitTokens: 50_000_000, limitUSD: nil),
                            "7d": QuotaWindowConfig(label: "周 (7天)", limitTokens: 200_000_000, limitUSD: nil),
                            "month": QuotaWindowConfig(label: "月度", limitTokens: 800_000_000, limitUSD: nil),
                         ]),
        QuotaEntryConfig(id: "go", name: "OpenCode Go", plan: "GO 订阅 ($12/5h, $30/周, $60/月)",
                         tool: "dsh", modelPrefix: "deepseek", official: "go",
                         includeCache: nil, windows: [
                            "5h": QuotaWindowConfig(label: "5 小时", limitTokens: nil, limitUSD: 12),
                            "7d": QuotaWindowConfig(label: "周 (7天)", limitTokens: nil, limitUSD: 30),
                            "month": QuotaWindowConfig(label: "月度", limitTokens: nil, limitUSD: 60),
                         ]),
        QuotaEntryConfig(id: "codex", name: "Codex", plan: "ChatGPT 订阅",
                         tool: "codex", modelPrefix: nil, official: "codex",
                         includeCache: nil, windows: [
                            "5h": QuotaWindowConfig(label: "5 小时", limitTokens: 100_000_000, limitUSD: nil),
                            "7d": QuotaWindowConfig(label: "周 (7天)", limitTokens: 500_000_000, limitUSD: nil),
                         ]),
    ])

    public static func load(from path: String) -> QuotasConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(QuotasConfig.self, from: data)
        else { return .default }
        return config
    }
}

// ---------------------------------------------------------- 官方结果模型 ----

/// 官方窗口数据（billing.py 移植后由各 provider 填充）。
public struct OfficialWindow: Equatable, Sendable {
    public var pct: Double?
    public var used: Double?
    public var limit: Double?
    public var resetsAt: String?
    public var unit: String?

    public init(pct: Double?, used: Double? = nil, limit: Double? = nil,
                resetsAt: String? = nil, unit: String? = nil) {
        self.pct = pct
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
        self.unit = unit
    }
}

/// 官方一次抓取的完整结果（含降级/过期元信息）。
public struct OfficialResult: Equatable, Sendable {
    public var windows: [String: OfficialWindow]?
    public var sampledAt: Double?
    public var staleMin: Int?
    public var error: String?
    public var detail: String?
    public var plan: String?
    public var via: String?

    public init(windows: [String: OfficialWindow]? = nil, sampledAt: Double? = nil, staleMin: Int? = nil,
                error: String? = nil, detail: String? = nil,
                plan: String? = nil, via: String? = nil) {
        self.windows = windows
        self.sampledAt = sampledAt
        self.staleMin = staleMin
        self.error = error
        self.detail = detail
        self.plan = plan
        self.via = via
    }
}

// ------------------------------------------------------------ 计算输出 ----

public struct QuotaWindowResult: Equatable, Sendable {
    public var key: String
    public var label: String
    public var unit: String
    public var pct: Double?
    public var used: Double?
    public var limit: Double?
    public var resetsAt: String?
    public var source: String          // "official" | "local"
    public var stale: Bool
    public var unallocated: Double?
}

public struct QuotaEntryResult: Equatable, Sendable {
    public var id: String
    public var name: String
    public var plan: String
    public var source: String          // "official" | "local"
    public var via: String?
    public var note: String
    public var windows: [QuotaWindowResult]
}

public enum QuotaEstimator {
    static let windowOrder = ["5h", "7d", "month"]
    static let windowOfficialKey = ["5h": "5h", "7d": "7d", "month": "month"]

    /// 窗口起点（月度=本月 1 日 00:00 本地；其余滑动窗口）。
    public static func windowStart(_ key: String, nowMs: Int64) -> Int64 {
        switch key {
        case "5h": return nowMs - 5 * 3600 * 1000
        case "7d": return nowMs - 7 * 24 * 3600 * 1000
        case "month":
            let now = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
            var cal = Calendar.current
            cal.timeZone = .current
            var c = cal.dateComponents([.year, .month], from: now)
            c.day = 1
            let start = cal.date(from: c) ?? now
            return Int64(start.timeIntervalSince1970 * 1000)
        default: return nowMs - 24 * 3600 * 1000
        }
    }

    /// compute()：officialProvider 返回 nil 表示该来源无官方数据（降级本地）。
    public static func compute(store: UsageStore, config: QuotasConfig,
                               nowMs: Int64,
                               officialProvider: (String) -> OfficialResult? = { _ in nil }) throws
        -> [QuotaEntryResult] {
        var entries: [QuotaEntryResult] = []
        for entry in config.entries {
            let official = entry.official.flatMap { officialProvider($0) }
            var windows: [QuotaWindowResult] = []
            var anyOfficial = false
            for key in windowOrder {
                guard let lim = entry.windows[key] else { continue }
                let isUSD = lim.limitUSD != nil
                let unit = isUSD ? "usd" : "tokens"
                // Python: tokens 缺省 0、usd 缺省 None
                let limit: Double? = isUSD ? lim.limitUSD : Double(lim.limitTokens ?? 0)
                let start = windowStart(key, nowMs: nowMs)
                let used = try store.windowUsage(startMs: start, tool: entry.tool,
                                                 modelPrefix: entry.modelPrefix,
                                                 includeCache: entry.includeCache ?? false,
                                                 usd: isUSD)
                // 官方覆盖
                let ow = official?.windows?[windowOfficialKey[key] ?? key]
                if let ow, let pct = ow.pct {
                    anyOfficial = true
                    windows.append(QuotaWindowResult(
                        key: key, label: lim.label ?? key,
                        unit: ow.unit ?? "pct", pct: roundHalfEven(pct, 1),
                        used: ow.used, limit: ow.limit, resetsAt: ow.resetsAt,
                        source: "official", stale: (official?.staleMin ?? 0) > 0,
                        unallocated: nil))
                    continue
                }
                let limitValue = limit ?? 0
                let pct: Double? = limitValue != 0
                    ? used / limitValue * 100
                    : (used == 0 ? 0 : nil)
                let unallocated = try store.windowUnallocated(
                    startMs: start, tool: entry.tool, modelPrefix: entry.modelPrefix,
                    includeCache: entry.includeCache ?? false, usd: isUSD)
                windows.append(QuotaWindowResult(
                    key: key, label: lim.label ?? key, unit: unit,
                    pct: pct.map { roundHalfEven($0, 1) },
                    used: isUSD ? roundHalfEven(used, 2) : Double(Int64(used)),
                    limit: limit,
                    resetsAt: nil, source: "local", stale: false,
                    unallocated: isUSD ? roundHalfEven(unallocated, 2) : Double(Int64(unallocated))))
            }
            var note = ""
            if let official, (official.staleMin ?? 0) > 0 {
                note = "官方接口暂时不可用（\(official.detail ?? official.error ?? "限流")），"
                    + "显示 \(official.staleMin ?? 0) 分钟前的官方数据"
            } else if let official, official.error != nil {
                note = official.detail ?? official.error ?? ""
            }
            var plan = entry.plan ?? ""
            if let officialPlan = official?.plan, !officialPlan.isEmpty {
                // 官方 plan 与配置重复时只保留信息量更大的一边
                plan = plan.isEmpty || plan.lowercased().contains(officialPlan.lowercased())
                    ? plan
                    : "\(officialPlan) · \(plan)".trimmingCharacters(
                        in: CharacterSet(charactersIn: " ·"))
            }
            entries.append(QuotaEntryResult(
                id: entry.id, name: entry.name, plan: plan,
                source: anyOfficial ? "official" : "local",
                via: anyOfficial ? official?.via : nil,
                note: note, windows: windows))
        }
        return entries
    }
}
