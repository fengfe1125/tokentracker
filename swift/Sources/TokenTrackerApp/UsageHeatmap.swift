import Foundation
import TokenTrackerCore

/// Mirrors the overview range keys and UsageStore.rangeBounds day boundaries.
struct HeatmapRequest: Equatable, Hashable, Sendable {
    var range = "week"
    /// nil = 全部 Agent；否则只统计这个工具
    var tool: String?
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
    /// Cell granularity: `.hour` for today / last 7 days, `.day` for this month / all history.
    enum Unit: Equatable, Sendable { case hour, day }
    /// Visual layout:
    /// - `.hourly`: row-major, one row per local day, 24 hour columns.
    /// - `.monthCalendar`: row-major calendar grid (Monday first), 7 weekday columns, one cell per day of the month.
    /// - `.yearly`: column-major weeks (Monday first), one stacked band per calendar year.
    enum Style: Equatable, Sendable { case hourly, monthCalendar, yearly }
    struct Band: Equatable, Sendable {
        let year: Int
        let firstColumn: Int
        let columns: Int
    }
    struct MonthWeek: Equatable, Sendable {
        let row: Int
        let startDay: Int
        let endDay: Int
        let elapsedDays: Int
        let activeDays: Int
        let tokens: Int64
    }
    let id = UUID()
    let unit: Unit
    let style: Style
    /// Selected range, end exclusive.
    let start: Date
    let end: Date
    let today: Date
    let now: Date
    let bands: [Band]           // .yearly only
    let rowDays: [Date]         // .hourly only: the local day of each row
    let monthLeadingBlanks: Int // .monthCalendar only
    let monthDaysCount: Int     // .monthCalendar only
    let monthWeeks: [MonthWeek] // .monthCalendar only
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
    var columns: Int {
        switch style {
        case .hourly: 24
        case .monthCalendar: 7
        case .yearly: bands.map(\.columns).max() ?? 0
        }
    }
    var monthRowCount: Int { style == .monthCalendar ? max(1, cells.count / 7) : 0 }
    var weeks: [[Day?]] { stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) } }

    func monthDayNumber(at index: Int) -> Int? {
        guard style == .monthCalendar, monthDaysCount > 0 else { return nil }
        let dayNumber = index - monthLeadingBlanks + 1
        return (1...monthDaysCount).contains(dayNumber) ? dayNumber : nil
    }

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
        self.init(dataset: HeatmapDataset(rows: rows, calendar: calendar), style: .yearly,
                  lower: first, upper: calendar.date(byAdding: .year, value: 1, to: first)!,
                  hours: [], now: now, calendar: calendar)
    }

    /// Today and last 7 days use hour cells; this month uses a monthly calendar grid; all history uses the annual day grid.
    init(dataset: HeatmapDataset, request: HeatmapRequest, hours: [UsageStore.DailyRow] = [],
         now: Date = Date(), calendar: Calendar = .current) {
        let (lower, upper) = Self.bounds(request.range, dataset: dataset, now: now, calendar: calendar)
        let style: Style = switch request.range {
        case "all": .yearly
        case "month": .monthCalendar
        default: .hourly
        }
        self.init(dataset: dataset, style: style,
                  lower: lower, upper: upper, hours: hours, now: now, calendar: calendar)
    }

    private init(dataset: HeatmapDataset, style: Style, lower: Date, upper: Date,
                 hours: [UsageStore.DailyRow], now: Date, calendar input: Calendar) {
        var calendar = input
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        self.style = style
        self.unit = style == .hourly ? .hour : .day
        start = lower; end = upper; self.today = today; self.now = now
        excludedTokens = dataset.excludedTokens
        let included = dataset.days.values.filter { $0.date >= lower && $0.date < upper && $0.date <= today }
        let dayTotal = included.reduce(0) { $0 + $1.tokens }
        activeDays = included.filter { $0.tokens > 0 }.count
        rangeDays = calendar.dateComponents([.day], from: lower, to: min(upper, tomorrow)).day ?? 0
        var result: [Day?] = []
        switch style {
        case .hourly:
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
            monthLeadingBlanks = 0; monthDaysCount = 0; monthWeeks = []
            elapsedHours = hourCount
        case .monthCalendar:
            // Full calendar month aligned to Monday–Sunday weeks; remaining days after today stay nil (pale placeholders).
            let monthStart = calendar.dateInterval(of: .month, for: lower)!.start
            let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)!.count
            let leading = (calendar.component(.weekday, from: monthStart) + 5) % 7
            let rowCount = (leading + daysInMonth + 6) / 7
            let elapsedEnd = min(upper, tomorrow)
            result.reserveCapacity(rowCount * 7)
            result += repeatElement(nil, count: leading)
            for offset in 0..<daysInMonth {
                let date = calendar.date(byAdding: .day, value: offset, to: monthStart)!
                if date >= lower && date < elapsedEnd {
                    result.append(dataset.days[date] ?? Day(date: date, tokens: 0, estimatedTokens: 0, agents: []))
                } else {
                    result.append(nil)
                }
            }
            result += repeatElement(nil, count: rowCount * 7 - result.count)
            var weeksSummary: [MonthWeek] = []
            weeksSummary.reserveCapacity(rowCount)
            for row in 0..<rowCount {
                var firstDay = Int.max, lastDay = 0, elapsed = 0, active = 0
                var weekTokens: Int64 = 0
                for col in 0..<7 {
                    let index = row * 7 + col
                    let dayNumber = index - leading + 1
                    guard (1...daysInMonth).contains(dayNumber) else { continue }
                    firstDay = min(firstDay, dayNumber)
                    lastDay = max(lastDay, dayNumber)
                    if let day = result[index] {
                        elapsed += 1
                        if day.tokens > 0 { active += 1 }
                        weekTokens += day.tokens
                    }
                }
                weeksSummary.append(MonthWeek(row: row, startDay: firstDay == Int.max ? 0 : firstDay,
                                              endDay: lastDay, elapsedDays: elapsed,
                                              activeDays: active, tokens: weekTokens))
            }
            rowDays = []; bands = []
            monthLeadingBlanks = leading; monthDaysCount = daysInMonth; monthWeeks = weeksSummary
            elapsedHours = 0
        case .yearly:
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
            monthLeadingBlanks = 0; monthDaysCount = 0; monthWeeks = []
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
