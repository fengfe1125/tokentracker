//
//  PublicStatsBuilder.swift
//  TokenTrackerCore
//
//  SQL → 纯函数 → 载荷。日序列与总量复用既有的 daily(rangeKey:) / stats(rangeKey:)，
//  所以口径与 App 里看到的数字天然一致。
//

import Foundation

public enum PublicStatsBuilder {

    /// 本地日历上的日期游标。日期加减全部走 Calendar，绝不 ts ± 86_400_000。
    struct DayAxis {
        let calendar: Calendar
        let formatter: DateFormatter

        init(timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            self.calendar = calendar
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            self.formatter = formatter
        }

        func day(ms: Int64) -> String {
            formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        }

        func shift(_ day: String, _ delta: Int) -> String? {
            guard let date = formatter.date(from: day),
                  let moved = calendar.date(byAdding: .day, value: delta, to: date)
            else { return nil }
            return formatter.string(from: moved)
        }

        /// [from, to] 闭区间的全部自然日。to 早于 from 时返回空。
        func days(from: String, to: String) -> [String] {
            var result: [String] = []
            var cursor: String? = from
            while let day = cursor, day <= to, result.count <= 1024 {
                result.append(day)
                cursor = shift(day, 1)
            }
            return result
        }
    }

    static func round(_ value: Double, _ places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    /// 组装公开载荷。
    /// - Parameters:
    ///   - days: 热力图窗口的最大天数；实际范围会裁到首个活跃日，不会凭空补零。
    ///   - nowMs: 注入时钟，测试冻结。
    ///
    /// 分桶时区**不可选**，恒为进程当前时区：daily() 走 SQLite 的 'localtime'，
    /// 日期字符串已经在系统时区下切好了。若这里允许传别的时区，轴和 SQL 会静默错位。
    /// 载荷里钉死 tz，浏览器只渲染预分桶的日期字符串，绝不重新从时间戳推导。
    public static func build(store: UsageStore,
                             days: Int = 365,
                             nowMs: Int64? = nil,
                             appVersion: String = TokenTrackerCore.version) throws
        -> PublicStatsPayload {

        let now = nowMs ?? store.nowMs()
        let timeZone = TimeZone.current
        let axis = DayAxis(timeZone: timeZone)
        let today = axis.day(ms: now)

        // ---- 日序列：与热力图同一份数据，天然排除未定位与跨日的观察区间 ----
        var tokensByDay: [String: Int64] = [:]
        var costByDay: [String: Double] = [:]
        for row in try store.daily(rangeKey: "all") {
            tokensByDay[row.day, default: 0] += row.stats.tokens
            costByDay[row.day, default: 0] += row.stats.cost
        }
        let datedTokens = tokensByDay.values.reduce(0, +)
        let datedCost = costByDay.values.reduce(0, +)
        let activeDays = tokensByDay.filter { $0.value > 0 }.keys

        // ---- 窗口：完整的 days 天，不裁到首个活跃日 ----
        // 前面大片空格是 GitHub 贡献图的惯例，也是用户给的参考图的样子；
        // 更重要的是列数稳定，格子才能是小方块而不是被拉成 100px 的巨块。
        let from = axis.shift(today, -(max(days, 1) - 1)) ?? today
        let axisDays = axis.days(from: from, to: today)
        let window = axisDays.isEmpty ? [today] : axisDays
        let series = window.map { (day: $0, tokens: tokensByDay[$0] ?? 0) }
        let windowTokens = series.reduce(0) { $0 + $1.tokens }

        // ---- 总量：含未定位历史，与 App 的「全部」口径一致 ----
        let (toolRows, total, _) = try store.stats(rangeKey: "all")
        let undatedTokens = max(total.tokens - datedTokens, 0)
        let undatedCost = max(total.cost - datedCost, 0)

        // ---- 最长连续段：只认 exact，见 burstEvents() 的注释 ----
        let burst = PublicMetrics.longestBurst(try store.burstEvents())
        let snapshotOnly = try store.eventQualityByTool()
            .filter { $0.events > 0 && $0.exact == 0 }
            .map(\.tool)
            .sorted()

        let streaks = PublicMetrics.streaks(activeDays: Set(activeDays),
                                            today: today, timeZone: timeZone)
        let known = Set(ScannerRegistry.all)
        let agents = toolRows
            .filter { $0.tokens > 0 && known.contains($0.tool) }
            .sorted { $0.tokens > $1.tokens }
            .map { PublicStatsPayload.Agent(id: $0.tool, tokens: $0.tokens,
                                            costUsd: round($0.cost, 2)) }

        // 取整到小时：分钟级的发布时间连续几个月就是一条作息信号。
        let hourly = (now / 3_600_000) * 3_600_000
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

        return PublicStatsPayload(
            v: TokenTrackerCore.publicStatsFormatVersion,
            generatedAt: iso.string(from: Date(timeIntervalSince1970: TimeInterval(hourly) / 1000)),
            tz: timeZone.identifier,
            tzOffsetMinutes: timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(now) / 1000)) / 60,
            appVersion: appVersion,
            range: .init(from: window.first ?? today, to: window.last ?? today, days: window.count),
            totals: .init(tokens: total.tokens,
                          tokensDated: datedTokens,
                          tokensUndated: undatedTokens,
                          costUsd: round(total.cost, 2),
                          costUsdUndated: round(undatedCost, 2),
                          activeDays: activeDays.count),
            daily: .init(start: window.first ?? today,
                         tokens: series.map(\.tokens),
                         windowTokens: windowTokens),
            peak: PublicMetrics.peakDay(series).map { .init(day: $0.day, tokens: $0.tokens) },
            streak: .init(current: streaks.current, longest: streaks.longest, asOf: today),
            longestBurst: burst.map {
                .init(seconds: $0.seconds,
                      day: axis.day(ms: $0.startMs),
                      agent: $0.tool,
                      gapMinutes: Int(PublicMetrics.defaultGapMs / 60_000),
                      basis: "exact")
            },
            agents: agents,
            caveats: .init(undatedShare: total.tokens > 0
                            ? round(Double(undatedTokens) / Double(total.tokens), 4) : 0,
                           snapshotOnlyAgents: snapshotOnly))
    }
}
