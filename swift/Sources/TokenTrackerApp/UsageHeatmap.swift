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
    /// `.hour`: row-major, one row per local day, 24 hour columns.
    /// `.day`: column-major weeks (Monday first), one stacked band per calendar year.
    enum Unit: Equatable, Sendable { case hour, day }
    struct Band: Equatable, Sendable {
        let year: Int
        let firstColumn: Int
        let columns: Int
    }
    let id = UUID()
    let unit: Unit
    /// Selected range, end exclusive.
    let start: Date
    let end: Date
    let today: Date
    let now: Date
    let bands: [Band]   // .day only
    let rowDays: [Date] // .hour only: the local day of each row
    let cells: [Day?]
    let totalTokens: Int64
    let activeDays: Int
    let activeHours: Int
    let elapsedHours: Int
    let rangeDays: Int
    let peak: Day?
    let peakTokens: Int64
    let excludedTokens: Int64
    /// Tokens in range that can be dated to a day but not to an hour (hour grid only).
    let hourlyExcludedTokens: Int64
    var columns: Int { unit == .hour ? 24 : bands.map(\.columns).max() ?? 0 }
    var weeks: [[Day?]] { stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) } }

    static func agents(_ values: [(String, Int64)]) -> [(tool: String, tokens: Int64)] {
        var totals: [String: Int64] = [:]
        for (tool, tokens) in values { totals[tool, default: 0] += tokens }
        return totals.map { (tool: $0.key, tokens: $0.value) }.sorted {
            $0.tokens == $1.tokens ? $0.tool < $1.tool : $0.tokens > $1.tokens
        }
    }

    /// The overview range's local day bounds; `all` starts at the first dated usage.
    static func bounds(_ range: String, dataset: HeatmapDataset, now: Date, calendar: Calendar) -> (Date, Date) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch range {
        case "day": return (today, tomorrow)
        case "week": return (calendar.date(byAdding: .day, value: -6, to: today)!, tomorrow)
        case "month": return (calendar.dateInterval(of: .month, for: today)!.start, tomorrow)
        default: return (min(dataset.days.keys.min() ?? today, today), tomorrow)
        }
    }

    /// A full calendar year of days; days after `now` stay blank.
    init(rows: [UsageStore.DailyRow], year: Int, now: Date = Date(), calendar: Calendar = .current) {
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        self.init(dataset: HeatmapDataset(rows: rows, calendar: calendar), unit: .day,
                  lower: first, upper: calendar.date(byAdding: .year, value: 1, to: first)!,
                  hours: [], now: now, calendar: calendar)
    }

    /// Today, last 7 days and this month use hour cells; all history uses the annual day grid.
    init(dataset: HeatmapDataset, request: HeatmapRequest, hours: [UsageStore.DailyRow] = [],
         now: Date = Date(), calendar: Calendar = .current) {
        let (lower, upper) = Self.bounds(request.range, dataset: dataset, now: now, calendar: calendar)
        self.init(dataset: dataset, unit: request.range == "all" ? .day : .hour,
                  lower: lower, upper: upper, hours: hours, now: now, calendar: calendar)
    }

    private init(dataset: HeatmapDataset, unit: Unit, lower: Date, upper: Date,
                 hours: [UsageStore.DailyRow], now: Date, calendar input: Calendar) {
        var calendar = input
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        self.unit = unit
        start = lower; end = upper; self.today = today; self.now = now
        excludedTokens = dataset.excludedTokens
        let included = dataset.days.values.filter { $0.date >= lower && $0.date < upper && $0.date <= today }
        let dayTotal = included.reduce(0) { $0 + $1.tokens }
        activeDays = included.filter { $0.tokens > 0 }.count
        rangeDays = calendar.dateComponents([.day], from: lower, to: min(upper, tomorrow)).day ?? 0
        var result: [Day?] = []
        if unit == .hour {
            // Repeated DST hours share a column; a skipped hour leaves its column blank.
            let grouped = Dictionary(grouping: hours, by: \.day)
            var days: [Date] = [], date = lower
            while date < upper { days.append(date); date = calendar.date(byAdding: .day, value: 1, to: date)! }
            var hourCount = 0
            for day in days {
                var row: [[UsageStore.DailyRow]?] = Array(repeating: nil, count: 24)
                var starts: [Date?] = Array(repeating: nil, count: 24)
                let next = calendar.date(byAdding: .day, value: 1, to: day)!
                var hour = day
                while hour < next {
                    if hour <= now {
                        let column = calendar.component(.hour, from: hour)
                        row[column] = (row[column] ?? []) + (grouped[String(Int64(hour.timeIntervalSince1970 * 1000))] ?? [])
                        starts[column] = starts[column] ?? hour
                        hourCount += 1
                    }
                    hour = calendar.date(byAdding: .hour, value: 1, to: hour)!
                }
                for column in 0..<24 {
                    guard let values = row[column], let start = starts[column] else { result.append(nil); continue }
                    result.append(Day(date: start, tokens: values.reduce(0) { $0 + $1.stats.tokens },
                        estimatedTokens: values.reduce(0) { $0 + $1.stats.estimatedTokens },
                        agents: Self.agents(values.map { ($0.tool, $0.stats.tokens) })))
                }
            }
            rowDays = days; bands = []
            elapsedHours = hourCount
        } else {
            // Whole calendar years from the range start, ending at today: no future placeholders.
            let firstYear = calendar.component(.year, from: lower)
            let lastYear = calendar.component(.year, from: min(upper, tomorrow).addingTimeInterval(-1))
            var bands: [Band] = []
            for year in firstYear...max(firstYear, lastYear) {
                let blockStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
                let blockEnd = min(tomorrow, calendar.date(byAdding: .year, value: 1, to: blockStart)!)
                let firstColumn = result.count / 7
                result += repeatElement(nil, count: (calendar.component(.weekday, from: blockStart) + 5) % 7)
                var date = blockStart
                while date < blockEnd {
                    result.append(dataset.days[date] ?? Day(date: date, tokens: 0, estimatedTokens: 0, agents: []))
                    date = calendar.date(byAdding: .day, value: 1, to: date)!
                }
                result += repeatElement(nil, count: (7 - result.count % 7) % 7)
                bands.append(Band(year: year, firstColumn: firstColumn, columns: result.count / 7 - firstColumn))
            }
            self.bands = bands; rowDays = []
            elapsedHours = 0
        }
        cells = result
        let counted = result.compactMap { $0 }.filter { $0.date >= lower && $0.date < upper }
        totalTokens = counted.reduce(0) { $0 + $1.tokens }
        activeHours = unit == .hour ? counted.filter { $0.tokens > 0 }.count : 0
        peak = counted.filter { $0.tokens > 0 }.max { $0.tokens == $1.tokens ? $0.date > $1.date : $0.tokens < $1.tokens }
        peakTokens = result.compactMap { $0?.tokens }.max() ?? 0
        hourlyExcludedTokens = unit == .hour ? max(0, dayTotal - totalTokens) : 0
    }

    func contains(_ day: Day) -> Bool { day.date >= start && day.date < end }

    func level(for tokens: Int64) -> Int {
        guard tokens > 0, peakTokens > 0 else { return 0 }
        return min(4, max(1, Int(ceil(sqrt(Double(tokens) / Double(peakTokens)) * 4))))
    }
}
