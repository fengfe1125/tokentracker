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
    /// 其余沿用 K / M / B。与状态栏共用 MenuBarFmt.fmtTokens。
    static func compact(_ n: Int64, yi: Bool) -> String {
        MenuBarFmt.fmtTokens(Double(max(n, 0)), yi: yi && !L10n.isEnglish)
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
        return CachedFormatters.shared.localizedTemplate("yyyyMMMdHHmm", date: date, locale: L10n.locale)
    }

    /// 本地今日 "yyyy-MM-dd"（会话表里当天的行省略日期，只留时刻）
    static var todayString: String {
        CachedFormatters.shared.todayString()
    }

    /// 固定紧凑的本地日期时间 "yyyy-MM-dd HH:mm"（会话记录与详情统一使用）
    static func sessionDateTime(ms: Int64?, timeZone: TimeZone = .current) -> String {
        guard let ms, ms > 0 else { return "—" }
        return CachedFormatters.shared.sessionDateTime(
            date: Date(timeIntervalSince1970: TimeInterval(ms) / 1000),
            timeZone: timeZone
        )
    }

    /// 紧凑缩写日期（项目列表行复用，避免每行新建 Date.FormatStyle / DateFormatter）。
    static func abbreviatedDate(ms: Int64, locale: Locale = L10n.locale) -> String {
        CachedFormatters.shared.abbreviatedDate(
            date: Date(timeIntervalSince1970: TimeInterval(ms) / 1000),
            locale: locale
        )
    }

    /// 本地化模板格式化（周报、活动详情、区间标签共用，复用缓存 DateFormatter）。
    static func localizedDate(_ date: Date, template: String,
                              locale: Locale = L10n.locale,
                              timeZone: TimeZone = .current) -> String {
        CachedFormatters.shared.localizedTemplate(template, date: date, locale: locale, timeZone: timeZone)
    }

    /// 复用的 Decimal / 货币 / 相对时间格式化（订阅卡片共用）。
    static func decimal(_ value: Decimal, locale: Locale = L10n.locale) -> String {
        CachedFormatters.shared.decimal(value, locale: locale)
    }

    static func currency(_ value: Decimal, code: String, locale: Locale = L10n.locale) -> String {
        CachedFormatters.shared.currency(value, code: code, locale: locale)
    }

    static func relativeShort(_ date: Date, relativeTo now: Date, locale: Locale = L10n.locale) -> String {
        CachedFormatters.shared.relativeShort(date, relativeTo: now, locale: locale)
    }

    /// 会话时间范围：同分钟只显示单时间点；同日省略结束日期；跨日完整展示起止。
    static func sessionTimeRange(firstMs: Int64?, lastMs: Int64?,
                                 fallbackLastSeen: String? = nil,
                                 timeZone: TimeZone = .current) -> String {
        let validFirst = firstMs.flatMap { $0 > 0 ? $0 : nil }
        let validLast = lastMs.flatMap { $0 > 0 ? $0 : nil }
        if let first = validFirst, let last = validLast {
            let start = sessionDateTime(ms: first, timeZone: timeZone)
            let end = sessionDateTime(ms: last, timeZone: timeZone)
            if start == end { return end }
            if start.prefix(10) == end.prefix(10) {
                return "\(start) → \(end.suffix(5))"
            }
            return "\(start) → \(end)"
        }
        if let single = validLast ?? validFirst {
            return sessionDateTime(ms: single, timeZone: timeZone)
        }
        if let fallbackLastSeen, !fallbackLastSeen.isEmpty {
            return fallbackLastSeen.count >= 16 ? String(fallbackLastSeen.prefix(16)) : fallbackLastSeen
        }
        return "—"
    }

    /// 会话成本分解行：输入 / 输出 / 缓存 / 写入
    static func sessionTokenBreakdown(_ stats: UsageStore.ToolStats, yi: Bool) -> String {
        L10n.text("输入 \(tokens(stats.input, yi: yi)) · 输出 \(tokens(stats.output, yi: yi)) · 缓存 \(tokens(stats.cacheRead, yi: yi)) · 写入 \(tokens(stats.cacheWrite, yi: yi))")
    }

    /// 会话费用：无事件显示 “—”，全部未计价显示「未计价」，否则两位小数。
    static func sessionCost(_ stats: UsageStore.ToolStats) -> String {
        if stats.events == 0 { return "—" }
        if stats.unpriced == stats.events { return L10n.text("未计价") }
        return cost(stats.cost)
    }

    static func sessionPartialUnpricedNote(_ stats: UsageStore.ToolStats) -> String? {
        guard stats.unpriced > 0, stats.unpriced < stats.events else { return nil }
        return L10n.text("含 \(stats.unpriced) 条未计价")
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
        // Only built-in labels (including segments inside compound "Group · Span" labels) are localized;
        // custom quota labels stay unchanged.
        let builtins: Set<String> = ["5 小时", "每日", "周 (7天)", "月度", "5h", "7d"]
        if builtins.contains(label) { return L10n.label(label) }
        guard label.contains(" · ") else { return label }
        return label.components(separatedBy: " · ")
            .map { builtins.contains($0) ? L10n.label($0) : $0 }
            .joined(separator: " · ")
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

/// 线程安全的格式化器缓存：避免表格与长列表滚动时每行重复初始化 DateFormatter / NumberFormatter。
final class CachedFormatters: @unchecked Sendable {
    static let shared = CachedFormatters()

    private let lock = NSLock()
    private var templateDates: [String: DateFormatter] = [:]
    private var sessionDates: [String: DateFormatter] = [:]
    private var abbreviatedDates: [String: DateFormatter] = [:]
    private var decimalNumbers: [String: NumberFormatter] = [:]
    private var currencyNumbers: [String: NumberFormatter] = [:]
    private var relativeDates: [String: RelativeDateTimeFormatter] = [:]

    private var cachedTodayValue = ""
    private var cachedTodayStart: TimeInterval = 0
    private var cachedTodayEnd: TimeInterval = 0
    private var cachedTodayTZKey = ""

    private init() {}

    private func tzKey(_ tz: TimeZone, at date: Date) -> String {
        "\(tz.identifier)|\(tz.secondsFromGMT(for: date))"
    }

    func todayString(now: Date = Date(), calendar: Calendar = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        let ts = now.timeIntervalSince1970
        let tz = tzKey(calendar.timeZone, at: now)
        if tz == cachedTodayTZKey, ts >= cachedTodayStart, ts < cachedTodayEnd, !cachedTodayValue.isEmpty {
            return cachedTodayValue
        }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        let formatted = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 1, comps.day ?? 1)
        cachedTodayValue = formatted
        cachedTodayStart = start.timeIntervalSince1970
        cachedTodayEnd = end.timeIntervalSince1970
        cachedTodayTZKey = tz
        return formatted
    }

    func sessionDateTime(date: Date, timeZone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = tzKey(timeZone, at: date)
        let fmt: DateFormatter
        if let existing = sessionDates[key] {
            fmt = existing
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US_POSIX")
            created.timeZone = timeZone
            created.dateFormat = "yyyy-MM-dd HH:mm"
            sessionDates[key] = created
            fmt = created
        }
        return fmt.string(from: date)
    }

    func localizedTemplate(_ template: String, date: Date, locale: Locale, timeZone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = "\(template)|\(locale.identifier)|\(tzKey(timeZone, at: date))"
        let fmt: DateFormatter
        if let existing = templateDates[key] {
            fmt = existing
        } else {
            let created = DateFormatter()
            created.locale = locale
            created.timeZone = timeZone
            created.setLocalizedDateFormatFromTemplate(template)
            templateDates[key] = created
            fmt = created
        }
        return fmt.string(from: date)
    }

    func abbreviatedDate(date: Date, locale: Locale, timeZone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = "\(locale.identifier)|\(tzKey(timeZone, at: date))"
        let fmt: DateFormatter
        if let existing = abbreviatedDates[key] {
            fmt = existing
        } else {
            let created = DateFormatter()
            created.locale = locale
            created.timeZone = timeZone
            created.dateStyle = .medium
            created.timeStyle = .none
            abbreviatedDates[key] = created
            fmt = created
        }
        return fmt.string(from: date)
    }

    func decimal(_ value: Decimal, locale: Locale) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = locale.identifier
        let fmt: NumberFormatter
        if let existing = decimalNumbers[key] {
            fmt = existing
        } else {
            let created = NumberFormatter()
            created.locale = locale
            created.numberStyle = .decimal
            created.maximumFractionDigits = 2
            decimalNumbers[key] = created
            fmt = created
        }
        return fmt.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    func currency(_ value: Decimal, code: String, locale: Locale) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = "\(locale.identifier)|\(code)"
        let fmt: NumberFormatter
        if let existing = currencyNumbers[key] {
            fmt = existing
        } else {
            let created = NumberFormatter()
            created.locale = locale
            created.numberStyle = .currency
            created.currencyCode = code
            created.minimumFractionDigits = 2
            created.maximumFractionDigits = 2
            currencyNumbers[key] = created
            fmt = created
        }
        return fmt.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(code)"
    }

    func relativeShort(_ date: Date, relativeTo now: Date, locale: Locale) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = locale.identifier
        let fmt: RelativeDateTimeFormatter
        if let existing = relativeDates[key] {
            fmt = existing
        } else {
            let created = RelativeDateTimeFormatter()
            created.locale = locale
            created.unitsStyle = .short
            relativeDates[key] = created
            fmt = created
        }
        return fmt.localizedString(for: date, relativeTo: now)
    }
}
