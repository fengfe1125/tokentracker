import Foundation
import TokenTrackerCore

enum HeatmapPeriod: String, CaseIterable, Sendable {
    case day, week, month, year, custom, all
    var title: L10n.Template {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        case .year: "年"
        case .custom: "自选"
        case .all: "全部"
        }
    }
}

struct HeatmapRequest: Equatable, Sendable {
    var period: HeatmapPeriod = .year
    var anchor = Date()
    var start = Calendar.current.dateInterval(of: .month, for: Date())!.start
    var end = Date()
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
            UsageHeatmap.Day(date: formatter.date(from: values[0].day)!, end: nil,
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
        let end: Date?
        let tokens: Int64
        let estimatedTokens: Int64
        let agents: [(tool: String, tokens: Int64)]
        var id: Date { date }
    }
    enum Unit: Equatable, Sendable { case hour, day, month, year(Int) }
    let id = UUID()
    let start: Date
    let end: Date // exclusive, always a local calendar boundary
    let unit: Unit
    let columns: Int
    let rowCount: Int
    let cells: [Day?] // row-major, except year/calendar grid is column-major
    let columnMajor: Bool
    let totalTokens: Int64
    let activeDays: Int
    let peakTokens: Int64
    let excludedTokens: Int64
    let hourlyExcludedTokens: Int64
    let year: Int
    var weeks: [[Day?]] { stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) } }

    static func agents(_ values: [(String, Int64)]) -> [(tool: String, tokens: Int64)] {
        var totals: [String: Int64] = [:]
        for (tool, tokens) in values { totals[tool, default: 0] += tokens }
        return totals.map { (tool: $0.key, tokens: $0.value) }.sorted {
            $0.tokens == $1.tokens ? $0.tool < $1.tool : $0.tokens > $1.tokens
        }
    }

    init(rows: [UsageStore.DailyRow], year: Int, now: Date = Date(), calendar: Calendar = .current) {
        self.init(dataset: HeatmapDataset(rows: rows, calendar: calendar),
                  request: HeatmapRequest(period: .year,
                    anchor: calendar.date(from: DateComponents(year: year, month: 1, day: 1))!),
                  now: now, calendar: calendar)
    }

    init(dataset: HeatmapDataset, request: HeatmapRequest, hours: [UsageStore.DailyRow] = [],
         now: Date = Date(), calendar input: Calendar = .current) {
        var calendar = input
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let anchor = min(request.anchor, now)
        let lower: Date, upper: Date
        switch request.period {
        case .day:
            lower = calendar.startOfDay(for: anchor)
            upper = calendar.date(byAdding: .day, value: 1, to: lower)!
        case .week, .month, .year:
            let component: Calendar.Component = request.period == .week ? .weekOfYear : request.period == .month ? .month : .year
            let interval = calendar.dateInterval(of: component, for: anchor)!
            lower = interval.start; upper = interval.end
        case .custom:
            lower = calendar.startOfDay(for: min(request.start, request.end))
            upper = min(tomorrow, calendar.date(byAdding: .day, value: 1,
                to: calendar.startOfDay(for: max(request.start, request.end)))!)
        case .all:
            lower = min(dataset.days.keys.min() ?? today, today)
            upper = tomorrow
        }
        let resolvedEnd = max(upper, calendar.date(byAdding: .day, value: 1, to: lower)!)
        start = lower; end = resolvedEnd
        year = calendar.component(.year, from: lower)
        excludedTokens = dataset.excludedTokens
        let dayCount = calendar.dateComponents([.day], from: start, to: end).day ?? 1
        if request.period == .day { unit = .hour }
        else if dayCount <= 370 { unit = .day }
        else {
            let lastDate = end.addingTimeInterval(-1)
            let monthStart = calendar.dateInterval(of: .month, for: start)!.start
            let months = (calendar.dateComponents([.month], from: monthStart, to: lastDate).month ?? 0) + 1
            if months <= 372 { unit = .month }
            else {
                let years = calendar.component(.year, from: lastDate) - calendar.component(.year, from: start) + 1
                unit = .year(max(1, Int(ceil(Double(years) / 372))))
            }
        }
        let included = dataset.days.values.filter { $0.date >= lower && $0.date < min(resolvedEnd, tomorrow) }
        activeDays = included.filter { $0.tokens > 0 }.count
        var buckets: [Day] = []
        if unit == .hour {
            let grouped = Dictionary(grouping: hours, by: \.day)
            var hour = start
            while hour < end {
                let next = calendar.date(byAdding: .hour, value: 1, to: hour)!
                if hour <= now {
                    let values = grouped[String(Int64(hour.timeIntervalSince1970 * 1000))] ?? []
                    buckets.append(Day(date: hour, end: next, tokens: values.reduce(0) { $0 + $1.stats.tokens },
                        estimatedTokens: values.reduce(0) { $0 + $1.stats.estimatedTokens },
                        agents: Self.agents(values.map { ($0.tool, $0.stats.tokens) })))
                } else { buckets.append(Day(date: hour, end: next, tokens: -1, estimatedTokens: 0, agents: [])) }
                hour = next
            }
        } else if unit == .day {
            var date = start
            while date < end {
                buckets.append(dataset.days[date] ?? Day(date: date, end: nil,
                    tokens: date > today ? -1 : 0, estimatedTokens: 0, agents: []))
                date = calendar.date(byAdding: .day, value: 1, to: date)!
            }
        } else {
            let component: Calendar.Component = unit == .month ? .month : .year
            let step: Int = if case .year(let size) = unit { size } else { 1 }
            var date = calendar.dateInterval(of: component, for: start)!.start
            while date < end {
                let next = min(end, calendar.date(byAdding: component, value: step, to: date)!)
                let values = included.filter { $0.date >= date && $0.date < next }
                buckets.append(Day(date: max(date, start), end: next, tokens: values.reduce(0) { $0 + $1.tokens },
                    estimatedTokens: values.reduce(0) { $0 + $1.estimatedTokens },
                    agents: Self.agents(values.flatMap { $0.agents.map { ($0.tool, $0.tokens) } })))
                date = next
            }
        }
        totalTokens = buckets.reduce(0) { $0 + max(0, $1.tokens) }
        peakTokens = buckets.map(\.tokens).max() ?? 0
        hourlyExcludedTokens = unit == .hour ? max(0, included.reduce(0) { $0 + $1.tokens } - totalTokens) : 0
        var result: [Day?] = buckets.map { $0.tokens < 0 ? nil : $0 }
        columnMajor = unit == .day && dayCount > 31
        if unit == .hour { columns = 12; rowCount = Int(ceil(Double(result.count) / 12)) }
        else if unit == .day {
            let offset = (calendar.component(.weekday, from: start) + 5) % 7
            result.insert(contentsOf: repeatElement(nil, count: offset), at: 0)
            if columnMajor { rowCount = 7; columns = Int(ceil(Double(result.count) / 7)) }
            else { columns = 7; rowCount = Int(ceil(Double(result.count) / 7)) }
        } else { columns = 12; rowCount = Int(ceil(Double(result.count) / 12)) }
        result.append(contentsOf: repeatElement(nil, count: columns * rowCount - result.count))
        cells = result
    }

    func level(for tokens: Int64) -> Int {
        guard tokens > 0, peakTokens > 0 else { return 0 }
        return min(4, max(1, Int(ceil(sqrt(Double(tokens) / Double(peakTokens)) * 4))))
    }
}
