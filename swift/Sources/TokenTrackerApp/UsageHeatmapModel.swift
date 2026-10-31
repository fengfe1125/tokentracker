import Combine
import Foundation
import TokenTrackerCore

/// The connection and cache are confined to the heatmap queue, separate from overview queries.
private final class HeatmapLoader: @unchecked Sendable {
    let path: String
    private var store: UsageStore?
    private var version: Int64?
    private var zone: String?
    private var dataset: HeatmapDataset?
    private var cachedRequest: HeatmapRequest?
    private var cachedDay: Date?
    private var cachedChart: UsageHeatmap?
    init(path: String) { self.path = path }

    func load(_ request: HeatmapRequest, now: Date, cancellation: ExportCancellation) throws -> UsageHeatmap {
        try cancellation.check()
        if store == nil { store = try UsageStore(path: path) }
        let store = store!
        try store.conn.execute("BEGIN")
        defer { try? store.conn.rollback() }
        // Establish a read snapshot before checking the persistent connection's revision.
        _ = try store.conn.queryOne("SELECT id FROM usage_events LIMIT 1")
        let current = try store.conn.scalarInt("PRAGMA data_version")
        let calendar = Calendar.current
        let changed = current != version || zone != calendar.timeZone.identifier || dataset == nil
        if changed {
            let rows = try store.daily(rangeKey: "all")
            let total = try store.stats(rangeKey: "all").total.tokens
            dataset = HeatmapDataset(rows: rows,
                    excludedTokens: max(0, total - rows.reduce(0) { $0 + $1.stats.tokens }), calendar: calendar)
            version = current; zone = calendar.timeZone.identifier
            cachedChart = nil
        }
        try cancellation.check()
        let day = calendar.startOfDay(for: now)
        if cachedRequest == request, cachedDay == day, let cachedChart { return cachedChart }
        let chart = UsageHeatmap(dataset: dataset!, request: request, now: now)
        try cancellation.check()
        cachedRequest = request; cachedDay = day; cachedChart = chart
        return chart
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
    init(path: String) { loader = HeatmapLoader(path: path) }

    func refresh() {
        generation += 1
        let generation = generation, request = request, loader = loader
        cancellation?.cancel()
        let cancellation = ExportCancellation()
        self.cancellation = cancellation
        loading = true; failed = false
        queue.async { [weak self] in
            do {
                let chart = try loader.load(request, now: Date(), cancellation: cancellation)
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    if self.chart?.id != chart.id { self.chart = chart }
                    self.loadedRequest = request
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
