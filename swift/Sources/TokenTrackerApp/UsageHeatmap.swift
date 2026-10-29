import Foundation
import TokenTrackerCore

/// Consumes the existing local-day buckets, including their time-quality rules.
struct UsageHeatmap {
    struct Day: Identifiable {
        let date: Date
        let tokens: Int64
        let estimatedTokens: Int64
        let agents: [(tool: String, tokens: Int64)]
        var id: Date { date }
    }

    let year: Int
    let weeks: [[Day?]]
    let totalTokens: Int64
    let activeDays: Int
    let peakTokens: Int64

    static func years(rows: [UsageStore.DailyRow], now: Date = Date(), calendar: Calendar = .current) -> [Int] {
        let current = calendar.component(.year, from: now)
        return Set(rows.compactMap { Int($0.day.prefix(4)) }.filter { $0 <= current } + [current]).sorted(by: >)
    }

    init(rows: [UsageStore.DailyRow], year: Int, now: Date = Date(), calendar input: Calendar = .current) {
        var calendar = input
        calendar.firstWeekday = 2 // Monday, consistent across languages.
        self.year = year
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: rows, by: \.day)
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 1, to: first)!
        let today = calendar.startOfDay(for: now)
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        var cells = [Day?](repeating: nil, count: offset)
        var date = first
        var total: Int64 = 0
        var active = 0
        var peak: Int64 = 0
        while date < end {
            if date <= today {
                let values = grouped[formatter.string(from: date)] ?? []
                let tokens = values.reduce(Int64(0)) { $0 + $1.stats.tokens }
                var agentTokens: [String: Int64] = [:]
                for row in values { agentTokens[row.tool, default: 0] += row.stats.tokens }
                let byAgent: [(tool: String, tokens: Int64)] = agentTokens.map { (tool: $0.key, tokens: $0.value) }
                    .sorted { lhs, rhs in
                        if lhs.tokens == rhs.tokens { return lhs.tool < rhs.tool }
                        return lhs.tokens > rhs.tokens
                    }
                cells.append(Day(date: date, tokens: tokens,
                    estimatedTokens: values.reduce(0) { $0 + $1.stats.estimatedTokens }, agents: byAgent))
                total += tokens
                if tokens > 0 { active += 1 }
                peak = max(peak, tokens)
            } else {
                cells.append(nil) // Future dates are not recorded zeroes.
            }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        while !cells.count.isMultiple(of: 7) { cells.append(nil) }
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        totalTokens = total
        activeDays = active
        peakTokens = peak
    }

    func level(for tokens: Int64) -> Int {
        guard tokens > 0, peakTokens > 0 else { return 0 }
        // Square-root scaling keeps small days visible without flattening typical days.
        return min(4, max(1, Int(ceil(sqrt(Double(tokens) / Double(peakTokens)) * 4))))
    }
}
