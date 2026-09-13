//
//  MenuBarFormatter.swift
//  TokenTrackerCore
//
//  移植自 app/menubar_fmt.py：状态栏标题分段合成（纯逻辑，无 AppKit）。
//  role 保持 Python 的字符串值，由 AppKit 层映射为颜色（StatusItemController）。
//

import Foundation

public enum MenuBarFmt {
    public static let providerGlyph = ["claude": "C", "codex": "X", "kimi": "K", "go": "G"]
    public static let defaultProvider = "claude"   // "off" = 仅今日用量

    // 配额紧急度阈值（百分比）
    public static let warnPct = 50.0
    public static let critPct = 80.0

    // 工具标识色（菜单圆点用）
    public static let toolHex = [
        "claude": "#d97757", "codex": "#5b8def", "opencode": "#34b3a0",
        "dsh": "#b98ae0", "hermes": "#e0a13e", "kimi": "#e06a9a",
        "pi": "#7fb069", "go": "#8b7bd8",
    ]

    // 动画参数
    public static let spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    public static let flashDur = 0.6
    public static let pulsePeriod = 2.0
    public static let pulseMin = 0.45

    public static let ringPt = 14.0
    public static let ringGlyphs = ["○", "◔", "◑", "◕", "●"]
}

// ------------------------------------------------------------ 数据模型 ----

public struct MenuBarToday: Equatable, Sendable {
    public var tokens: Int64
    public var cost: Double
    public var unpriced: Bool
    public init(tokens: Int64, cost: Double, unpriced: Bool = false) {
        self.tokens = tokens
        self.cost = cost
        self.unpriced = unpriced
    }
}

public struct MenuBarQuotaWindow: Equatable, Sendable {
    public var pct: Double?
    public var source: String    // "official" | "local"
    public var stale: Bool
    public var label: String

    public init(pct: Double?, source: String, stale: Bool, label: String) {
        self.pct = pct
        self.source = source
        self.stale = stale
        self.label = label
    }
}

public struct MenuBarQuotaEntry: Equatable, Sendable {
    public var id: String
    public var name: String
    public var windows: [MenuBarQuotaWindow]

    public init(id: String, name: String, windows: [MenuBarQuotaWindow]) {
        self.id = id
        self.name = name
        self.windows = windows
    }
}

/// 段落：role 值与 Python 一致（bolt/tokens/dim/glyph/marker/cost/ink/
/// quota_ok/quota_warn/quota_crit/quota_none/dot_<id>）。
public struct MenuBarSegment: Equatable {
    public var text: String
    public var role: String
    public init(_ text: String, _ role: String) {
        self.text = text
        self.role = role
    }
}

extension MenuBarQuotaEntry {
    /// 从配额计算结果转换（丢弃额度数值，只留展示需要的最紧窗口字段）。
    public init(result: QuotaEntryResult) {
        self.init(id: result.id, name: result.name,
                  windows: result.windows.map {
                    MenuBarQuotaWindow(pct: $0.pct, source: $0.source,
                                       stale: $0.stale, label: $0.label)
                  })
    }
}

// ------------------------------------------------------------ 纯函数 ----

extension MenuBarFmt {
    public static func hexRGB(_ value: String) -> (Double, Double, Double) {
        let v = value.hasPrefix("#") ? String(value.dropFirst()) : value
        func part(_ range: Range<String.Index>) -> Double {
            Double(Int(v[range], radix: 16) ?? 0) / 255
        }
        guard v.count >= 6 else { return (0, 0, 0) }
        let i = v.startIndex
        return (part(i..<v.index(i, offsetBy: 2)),
                part(v.index(i, offsetBy: 2)..<v.index(i, offsetBy: 4)),
                part(v.index(i, offsetBy: 4)..<v.index(i, offsetBy: 6)))
    }

    /// 配额紧急度 → 段落 role。
    public static func quotaUrgency(_ pct: Double?) -> String {
        let p = pct ?? 0
        if p >= critPct { return "quota_crit" }
        if p >= warnPct { return "quota_warn" }
        return "quota_ok"
    }

    /// 官方过期 ~ / 本地估算 ≈ / 官方新鲜无标记。
    public static func quotaMarker(_ window: MenuBarQuotaWindow) -> String {
        if window.source == "official" {
            return window.stale ? "~" : ""
        }
        return "≈"
    }

    public static func fmtTokens(_ n: Double, yi: Bool = false) -> String {
        let n = max(n, 0)
        if yi && n >= 1e6 { return String(format: "%.2f亿", n / 1e8) }
        if n >= 1e9 { return String(format: "%.2fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.2fM", n / 1e6) }
        if n >= 1e4 { return String(format: "%.1fK", n / 1e3) }
        if n >= 1e3 { return String(format: "%.2fK", n / 1e3) }
        return String(Int(n))
    }

    /// entry 里 pct 最高的窗口（最紧的那个）。
    public static func bestWindow(_ entry: MenuBarQuotaEntry?) -> MenuBarQuotaWindow? {
        var best: MenuBarQuotaWindow?
        for w in entry?.windows ?? [] {
            guard w.pct != nil else { continue }
            if best == nil || (w.pct ?? 0) > (best?.pct ?? 0) { best = w }
        }
        return best
    }

    public static func fmtQuota(_ window: MenuBarQuotaWindow) -> String {
        let marker = quotaMarker(window)
        return String(format: "%@%.0f%%", marker, window.pct ?? 0)
    }

    public static func fmtTitle(today: MenuBarToday?, entries: [MenuBarQuotaEntry]?,
                                provider: String?, compact: Bool = false,
                                yi: Bool = false, ring: Bool = false) -> String {
        fmtSegments(today: today, entries: entries, provider: provider,
                    compact: compact, yi: yi, ring: ring).map(\.text).joined()
    }

    /// 状态栏标题分段。语义与 Python fmt_segments 一致（见 menubar_fmt.py docstring）。
    public static func fmtSegments(today: MenuBarToday?, entries: [MenuBarQuotaEntry]?,
                                   provider: String?, compact: Bool = false,
                                   yi: Bool = false, ring: Bool = false) -> [MenuBarSegment] {
        let sep = compact ? "" : " "
        let lead = ring ? "" : sep     // 圆环模式下图标与标题的间距由 AppKit 排版负责
        var segs: [MenuBarSegment] = ring ? [] : [MenuBarSegment("⚡", "bolt")]
        if let today {
            segs.append(MenuBarSegment(lead + fmtTokens(Double(today.tokens), yi: yi), "tokens"))
        } else {
            segs.append(MenuBarSegment(lead + "—", "dim"))
        }
        guard let provider, provider != "off" else { return segs }
        let entry = (entries ?? []).first { $0.id == provider }
        guard let best = bestWindow(entry), best.pct != nil else { return segs }
        let glyph = providerGlyph[provider]
            ?? String((entry?.name.isEmpty == false ? entry?.name : nil) ?? "?").prefix(1).description
        segs.append(MenuBarSegment(compact ? "·" : " · ", "dim"))
        segs.append(MenuBarSegment(glyph, "glyph"))
        let marker = quotaMarker(best)
        if ring {
            if !marker.isEmpty {
                segs.append(MenuBarSegment(marker, "marker"))
            }
            return segs
        }
        if !marker.isEmpty {
            segs.append(MenuBarSegment("\(sep)\(marker)", "marker"))
            segs.append(MenuBarSegment(String(format: "%.0f%%", best.pct ?? 0),
                                       quotaUrgency(best.pct)))
        } else {
            segs.append(MenuBarSegment(String(format: "%@%.0f%%", sep, best.pct ?? 0),
                                       quotaUrgency(best.pct)))
        }
        return segs
    }

    // ------------------------------------------------------------ 配额圆环 ----

    /// 状态栏配额圆参数：pct=nil → 灰色空心圆（无配额数据 / 仅今日用量）。
    public static func ringSpec(entries: [MenuBarQuotaEntry]?, provider: String?)
        -> (pct: Double?, role: String) {
        if let provider, provider != "off" {
            let entry = (entries ?? []).first { $0.id == provider }
            if let best = bestWindow(entry), let pct = best.pct {
                let clamped = max(0, min(100, pct))
                return (clamped, quotaUrgency(clamped))
            }
        }
        return (nil, "quota_none")
    }

    /// 圆环的纯文本近似字符（菜单「当前：」预览用）。
    public static func ringGlyph(_ spec: (pct: Double?, role: String)) -> String {
        guard let pct = spec.pct else { return ringGlyphs[0] }
        let idx = Int(roundHalfEven(pct / 100 * Double(ringGlyphs.count - 1), 0))
        return ringGlyphs[max(0, min(ringGlyphs.count - 1, idx))]
    }

    public static func todayLineSegments(_ today: MenuBarToday?, yi: Bool = false) -> [MenuBarSegment] {
        guard let today else {
            return [MenuBarSegment("今日暂无数据（点「立即扫描」）", "dim")]
        }
        return [MenuBarSegment("今日 ", "dim"),
                MenuBarSegment(fmtTokens(Double(today.tokens), yi: yi), "tokens"),
                MenuBarSegment(" tokens", "dim"), MenuBarSegment(" · ", "dim"),
                MenuBarSegment(today.unpriced ? "未计价" : String(format: "≈$%.2f", today.cost), "cost")]
    }

    /// 菜单配额行分段：●(工具色点) 名称 · 窗口 label pct(紧急度色)。
    public static func quotaLineSegments(_ entry: MenuBarQuotaEntry) -> [MenuBarSegment] {
        let name = entry.name.isEmpty ? "?" : entry.name
        guard let best = bestWindow(entry) else {
            return [MenuBarSegment(name, "ink")]
        }
        return [MenuBarSegment("● ", "dot_\(entry.id)"), MenuBarSegment(name, "ink"),
                MenuBarSegment(" · \(best.label) ", "dim"),
                MenuBarSegment(fmtQuota(best), quotaUrgency(best.pct))]
    }

    // ------------------------------------------------------------ 动画曲线 ----

    public static func spinnerFrame(_ index: Int) -> String {
        let chars = Array(spinner)
        return String(chars[((index % chars.count) + chars.count) % chars.count])
    }

    /// 数值刷新闪光：0 = 全品牌橙，1 = 完全回到主色；超出时长钳制为 1。
    public static func flashAlpha(_ elapsed: Double, dur: Double = flashDur) -> Double {
        if elapsed <= 0 { return 0 }
        return min(1, elapsed / dur)
    }

    /// 配额告急脉冲透明度：[pulseMin, 1] 正弦低幅波动。
    public static func pulseAlpha(_ elapsed: Double, period: Double = pulsePeriod) -> Double {
        pulseMin + (1 - pulseMin) * (0.5 + 0.5 * sin(2 * .pi * elapsed / period))
    }
}
