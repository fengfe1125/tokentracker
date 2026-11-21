import Combine
import Foundation
import TokenTrackerCore

private struct HeatmapLoadResult {
    let chart: UsageHeatmap
    let version: Int64
    let zone: String
    let hour: Date
    let warmed: [HeatmapRequest: UsageHeatmap]
}

/// The connection and cache are confined to the heatmap queue, separate from overview queries.
private final class HeatmapLoader: @unchecked Sendable {
    let path: String
    private var store: UsageStore?
    private var version: Int64?
    private var zone: String?
    private var dataset: HeatmapDataset?
    private var datasetTool: String?
    private var allRows: [UsageStore.DailyRow] = []
    private var hourRows: [Date: [UsageStore.DailyRow]] = [:]
    private var cachedHour: Date?
    private var cachedCharts: [HeatmapRequest: UsageHeatmap] = [:]
    init(path: String) { self.path = path }

    static func rows(_ rows: [UsageStore.DailyRow], tool: String?) -> [UsageStore.DailyRow] {
        guard let tool else { return rows }
        return rows.filter { $0.tool == tool }
    }

    func load(_ request: HeatmapRequest, now: Date, cancellation: ExportCancellation) throws -> HeatmapLoadResult {
        try cancellation.check()
        if store == nil { store = try UsageStore(path: path) }
        let store = store!
        try store.conn.execute("BEGIN")
        defer { try? store.conn.rollback() }
        // Establish a read snapshot before checking the persistent connection's revision.
        _ = try store.conn.queryOne("SELECT id FROM usage_events LIMIT 1")
        let current = try store.conn.scalarInt("PRAGMA data_version")
        let calendar = Calendar.current
        let zoneID = calendar.timeZone.identifier
        let hour = calendar.dateInterval(of: .hour, for: now)!.start
        let changed = current != version || zone != zoneID || dataset == nil
        if changed {
            allRows = try store.daily(rangeKey: "all")
            version = current; zone = zoneID
            hourRows.removeAll(); cachedCharts.removeAll(); cachedHour = nil
        }
        if cachedHour != hour {
            cachedCharts.removeAll()
            cachedHour = hour
        }
        if let hit = cachedCharts[request] {
            return HeatmapLoadResult(chart: hit, version: current, zone: zoneID, hour: hour, warmed: cachedCharts)
        }
        // 日桶按工具分行，筛选 Agent 只是换一份子集；库没变时不重新查询全量
        if changed || datasetTool != request.tool {
            let rows = Self.rows(allRows, tool: request.tool)
            let total = try store.stats(rangeKey: "all", tool: request.tool).total.tokens
            dataset = HeatmapDataset(rows: rows,
                    excludedTokens: max(0, total - rows.reduce(0) { $0 + $1.stats.tokens }), calendar: calendar)
            datasetTool = request.tool
        }
        try cancellation.check()
        var rows: [UsageStore.DailyRow] = []
        if request.range != "all" {
            let (lower, upper) = UsageHeatmap.bounds(request.range, dataset: dataset!, now: now, calendar: calendar)
            var missingStart: Date?
            var date = lower
            func flushMissing(upTo endDate: Date) throws {
                guard let start = missingStart else { return }
                missingStart = nil
                try cancellation.check()
                let fetched = try store.heatmapHours(from: start, to: endDate, calendar: calendar)
                var byDay: [Date: [UsageStore.DailyRow]] = [:]
                for row in fetched {
                    if let ms = Int64(row.day) {
                        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(ms) / 1000))
                        byDay[dayStart, default: []].append(row)
                    }
                }
                var cursor = start
                while cursor < endDate {
                    hourRows[cursor] = byDay[cursor] ?? []
                    cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
                }
                rows += fetched
            }
            while date < upper {
                let next = calendar.date(byAdding: .day, value: 1, to: date)!
                if let cached = hourRows[date] {
                    try flushMissing(upTo: date)
                    rows += cached
                } else if missingStart == nil {
                    missingStart = date
                }
                date = next
            }
            try flushMissing(upTo: upper)
            if hourRows.count > 62 { hourRows.removeAll() }
        }
        let chart = UsageHeatmap(dataset: dataset!, request: request,
                                 hours: Self.rows(rows, tool: request.tool), now: now)
        try cancellation.check()
        cachedCharts[request] = chart
        // 默认加载「近 7 天」时今天的小时桶已在内存中，顺手预编译「今天」热力图（零额外 SQL），
        // 首次从「近 7 天」切到「今天」即可同帧切换。
        if request.range == "week" {
            let dayRequest = HeatmapRequest(range: "day", tool: request.tool)
            if cachedCharts[dayRequest] == nil,
               let todayHours = hourRows[calendar.startOfDay(for: now)] {
                cachedCharts[dayRequest] = UsageHeatmap(dataset: dataset!, request: dayRequest,
                                                        hours: Self.rows(todayHours, tool: request.tool), now: now)
            }
        }
        return HeatmapLoadResult(chart: chart, version: current, zone: zoneID, hour: hour, warmed: cachedCharts)
    }
}

@MainActor
final class UsageHeatmapModel: ObservableObject {
    /// Set by AppState from the overview range before each refresh.
    @Published var request = HeatmapRequest()
    @Published private(set) var chart: UsageHeatmap?
    @Published private(set) var loadedRequest: HeatmapRequest?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private let queue = DispatchQueue(label: "tokentracker.heatmap", qos: .userInitiated)
    private let loader: HeatmapLoader
    private var generation = 0
    private var cancellation: ExportCancellation?
    private var cachedVersion: Int64?
    private var cachedZone: String?
    private var cachedHour: Date?
    private var cachedCharts: [HeatmapRequest: UsageHeatmap] = [:]
    init(path: String) { loader = HeatmapLoader(path: path) }

    /// 命中当前小时的主线程热力图缓存时立即切换展示，随后仍由后台按 PRAGMA data_version 校验更新。
    @discardableResult
    func applyCachedIfAvailable(for target: HeatmapRequest) -> Bool {
        let calendar = Calendar.current
        let zone = calendar.timeZone.identifier
        let hour = calendar.dateInterval(of: .hour, for: Date())?.start
        guard cachedZone == zone, cachedHour == hour, let hit = cachedCharts[target] else { return false }
        if chart?.id != hit.id { chart = hit }
        if loadedRequest != target { loadedRequest = target }
        return true
    }

    func refresh() {
        generation += 1
        let generation = generation, request = request, loader = loader
        cancellation?.cancel()
        let cancellation = ExportCancellation()
        self.cancellation = cancellation
        loading = true; failed = false
        queue.async { [weak self] in
            do {
                let result = try loader.load(request, now: Date(), cancellation: cancellation)
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    if self.cachedVersion != result.version || self.cachedZone != result.zone || self.cachedHour != result.hour {
                        self.cachedCharts.removeAll()
                        self.cachedVersion = result.version
                        self.cachedZone = result.zone
                        self.cachedHour = result.hour
                    }
                    for (key, value) in result.warmed { self.cachedCharts[key] = value }
                    if self.chart?.id != result.chart.id { self.chart = result.chart }
                    if self.loadedRequest != request { self.loadedRequest = request }
                    self.loading = false
                }
            } catch is CancellationError { } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    self.loading = false; self.failed = true
                }
            }
        }
    }
}
