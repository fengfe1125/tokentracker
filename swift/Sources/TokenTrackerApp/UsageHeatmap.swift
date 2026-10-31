import Foundation
import TokenTrackerCore

/// Mirrors the overview range keys and UsageStore.rangeBounds day boundaries.
struct HeatmapRequest: Equatable, Sendable {
    var range = "week"
}

/// Parsed once per database revision; pointer movement never touches rows or dates.
struct HeatmapDataset: Sendable {
    var days: [Date: UsageHeatmap.Day]
    let excludedTokens: Int64

    init(rows: [UsageStore.DailyRow], excludedTokens: Int64 = 0, calendar: Calendar = .current) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var grouped: [Date: [UsageStore.DailyRow]] = [:]
        for row in rows {
            if let date = formatter.date(from: row.day) { grouped[date, default: []].append(row) }
        }
        days = grouped.mapValues { values in
            UsageHeatmap.Day(date: formatter.date(from: values[0].day)!,
                tokens: values.reduce(0) { $0 + $1.stats.tokens },
                estimatedTokens: values.reduce(0) { $0 + $1.stats.estimatedTokens },
                agents: UsageHeatmap.agents(values.map { ($0.tool, $0.stats.tokens) }))
        }
        self.excludedTokens = excludedTokens
    }
}

struct UsageHeatmap: Sendable {
    struct Day: Identifiable, Sendable {
        let date: Date
        let tokens: Int64
        let estimatedTokens: Int64
        let agents: [(tool: String, tokens: Int64)]
        var id: Date { date }
    }
    /// One calendar-year block of week columns; multi-year ranges stack blocks vertically.
    struct Band: Equatable, Sendable {
        let year: Int
        let firstColumn: Int
        let columns: Int
    }
    let id = UUID()
    let start: Date
    let end: Date // exclusive, always a local calendar boundary
    let bands: [Band]
    let cells: [Day?] // column-major weeks, Monday first; bands are concatenated
    let totalTokens: Int64
    let activeDays: Int
    let peakTokens: Int64
    let excludedTokens: Int64
    var columns: Int { bands.map(\.columns).max() ?? 0 }
    var weeks: [[Day?]] { stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) } }

    static func agents(_ values: [(String, Int64)]) -> [(tool: String, tokens: Int64)] {
        var totals: [String: Int64] = [:]
        for (tool, tokens) in values { totals[tool, default: 0] += tokens }
        return totals.map { (tool: $0.key, tokens: $0.value) }.sorted {
            $0.tokens == $1.tokens ? $0.tool < $1.tool : $0.tokens > $1.tokens
        }
    }

    /// A full calendar year; days after `now` stay blank.
    init(rows: [UsageStore.DailyRow], year: Int, now: Date = Date(), calendar: Calendar = .current) {
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        self.init(dataset: HeatmapDataset(rows: rows, calendar: calendar),
                  lower: first, upper: calendar.date(byAdding: .year, value: 1, to: first)!,
                  now: now, calendar: calendar)
    }

    init(dataset: HeatmapDataset, request: HeatmapRequest, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let lower: Date, upper: Date
        switch request.range {
        case "day":
            lower = today; upper = tomorrow
        case "week":
            lower = calendar.date(byAdding: .day, value: -6, to: today)!; upper = tomorrow
        case "month":
            lower = calendar.dateInterval(of: .month, for: today)!.start; upper = tomorrow
        default:
            // Whole calendar years, like the annual view, from the first dated usage.
            let first = min(dataset.days.keys.min() ?? today, today)
            lower = calendar.dateInterval(of: .year, for: first)!.start
            upper = calendar.dateInterval(of: .year, for: today)!.end
        }
        self.init(dataset: dataset, lower: lower, upper: upper, now: now, calendar: calendar)
    }

    private init(dataset: HeatmapDataset, lower: Date, upper: Date, now: Date, calendar input: Calendar) {
        var calendar = input
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: now)
        start = lower; end = upper
        excludedTokens = dataset.excludedTokens
        let included = dataset.days.values.filter { $0.date >= lower && $0.date < upper && $0.date <= today }
        activeDays = included.filter { $0.tokens > 0 }.count
        totalTokens = included.reduce(0) { $0 + $1.tokens }
        peakTokens = included.map(\.tokens).max() ?? 0
        // Short ranges stay one block even across New Year; longer ones split per calendar year.
        let dayCount = calendar.dateComponents([.day], from: lower, to: upper).day ?? 1
        var blocks: [(Date, Date)] = []
        if dayCount <= 31 { blocks = [(lower, upper)] }
        else {
            var date = lower
            while date < upper {
                let next = min(upper, calendar.dateInterval(of: .year, for: date)!.end)
                blocks.append((date, next)); date = next
            }
        }
        var result: [Day?] = [], bands: [Band] = []
        for (blockStart, blockEnd) in blocks {
            let firstColumn = result.count / 7
            result += repeatElement(nil, count: (calendar.component(.weekday, from: blockStart) + 5) % 7)
            var date = blockStart
            while date < blockEnd {
                result.append(date > today ? nil : dataset.days[date]
                    ?? Day(date: date, tokens: 0, estimatedTokens: 0, agents: []))
                date = calendar.date(byAdding: .day, value: 1, to: date)!
            }
            result += repeatElement(nil, count: (7 - result.count % 7) % 7)
            bands.append(Band(year: calendar.component(.year, from: blockStart),
                              firstColumn: firstColumn, columns: result.count / 7 - firstColumn))
        }
        self.bands = bands
        cells = result
    }

    func level(for tokens: Int64) -> Int {
        guard tokens > 0, peakTokens > 0 else { return 0 }
        return min(4, max(1, Int(ceil(sqrt(Double(tokens) / Double(peakTokens)) * 4))))
    }
}
