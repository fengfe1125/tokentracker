//
//  Formatting.swift
//  TokenTrackerApp
//
//  界面格式化助手（对齐 app/web/app.js 的 fmtT / fmtCost）。
//

import Foundation
import TokenTrackerCore

enum UIFormat {
    static func tokens(_ n: Int64, yi: Bool) -> String {
        MenuBarFmt.fmtTokens(Double(n), yi: yi && !L10n.isEnglish)
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
