//
//  Formatting.swift
//  TokenTrackerApp
//
//  界面格式化助手（对齐 app/web/app.js 的 fmtT / fmtCost）。
//

import Foundation
import TokenTrackerCore

enum UIFormat {
    static func tokens(_ n: Int64, yi: Bool) -> String { compact(n, yi: yi) }

    /// 主面板的紧凑数：中文开启「亿」时按量级用 万 / 亿（200 万不再显示成 0.02亿），
    /// 其余沿用 K / M / B。状态栏标题仍走 MenuBarFmt。
    static func compact(_ n: Int64, yi: Bool) -> String {
        guard yi, !L10n.isEnglish else { return MenuBarFmt.fmtTokens(Double(n), yi: false) }
        let v = Double(max(n, 0))
        if v >= 1e8 { return String(format: "%.2f亿", v / 1e8) }
        if v >= 1e7 { return String(format: "%.0f万", v / 1e4) }
        if v >= 1e4 { return String(format: "%.1f万", v / 1e4) }
        return String(max(n, 0))
    }

    /// 占比：小于 0.1% 的非零值显示为 "<0.1%"，避免看成 0。
    static func share(_ part: Int64, of total: Int64) -> String {
        guard total > 0, part > 0 else { return "0%" }
        let pct = Double(part) / Double(total) * 100
        return pct < 0.1 ? "<0.1%" : String(format: "%.1f%%", pct)
    }

    /// $%.2f；≥1000 → $%.2fK
    static func cost(_ v: Double) -> String {
        v >= 1000
            ? String(format: "$%.2fK", v / 1000)
            : String(format: "$%.2f", v)
    }

    /// 精确成本：$%.4f；≥1000 仍走 $%.2fK
    static func costPrecise(_ v: Double) -> String {
        v >= 1000
            ? String(format: "$%.2fK", v / 1000)
            : String(format: "$%.4f", v)
    }

    /// cc-switch 风格的「万」换算：≥1万 → "x.xx 万"，否则原样数字
    static func wan(_ n: Int64) -> String {
        if L10n.isEnglish { return "≈ " + tokens(n, yi: false) }
        let v = Double(n)
        if v >= 10_000 {
            return String(format: L10n.text("≈ %.2f 万"), v / 10_000)
        }
        return "≈ \(n)"
    }

    /// 概览卡副标签：开启「亿」时只转换真正达到 1 亿的数值；
    /// 较小数值继续用「万」，避免 465 万显示成精度不足的 0.05 亿。
    static func overviewTokens(_ n: Int64, yi: Bool) -> String {
        if L10n.isEnglish { return "≈ " + tokens(n, yi: false) }
        if yi && n >= 100_000_000 {
            return String(format: L10n.text("≈ %.2f 亿"), Double(n) / 100_000_000)
        }
        return wan(n)
    }

    /// "2026-08-25 14:00" 本地时间
    static func dateTime(ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.locale = L10n.locale
        fmt.setLocalizedDateFormatFromTemplate("yyyyMMMdHHmm")
        return fmt.string(from: date)
    }

    /// 本地今日 "yyyy-MM-dd"（会话表里当天的行省略日期，只留时刻）
    static var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    /// 汇总费用：无记录显示 “—”，全部未计价显示「未计价」，否则两位小数。
    static func costLabel(_ totals: UsageTotals) -> String {
        if totals.records == 0 { return "—" }
        if totals.unpriced == totals.records { return L10n.text("未计价") }
        return cost(totals.cost)
    }

    /// 带正负号的紧凑 Token 变化量。
    static func signedCompact(_ delta: Int64, yi: Bool) -> String {
        (delta > 0 ? "+" : delta < 0 ? "−" : "") + compact(abs(delta), yi: yi)
    }

    static func percent(_ v: Double?) -> String {
        v.map { String(format: "%.1f%%", $0) } ?? "—"
    }
}

extension UIFormat {
    static func quotaLabel(_ label: String) -> String {
        // Only built-in labels are localized; custom quota labels stay unchanged.
        let builtins: Set<String> = ["5 小时", "周 (7天)", "月度", "5h", "7d"]
        return builtins.contains(label) ? L10n.label(label) : label
    }
    static func quotaEntry(_ entry: MenuBarQuotaEntry) -> MenuBarQuotaEntry {
        var entry = entry
        entry.windows = entry.windows.map {
            var window = $0
            window.label = quotaLabel(window.label)
            return window
        }
        return entry
    }
}
