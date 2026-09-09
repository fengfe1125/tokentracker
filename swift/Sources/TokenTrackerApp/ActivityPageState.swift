import Combine
import Foundation
import TokenTrackerCore

struct ActivityFilter: Equatable, Sendable {
    var range: String
    var agent: String?
    var confidence: String
}

struct ActivityRefreshRequest: Equatable, Sendable {
    let generation: Int
    let filter: ActivityFilter
}

struct ActivityDashboardSnapshot: Equatable, Sendable {
    var exactRows: [UsageStore.ActivitySummaryRow] = []
    var derivedRows: [UsageStore.ActivitySummaryRow] = []
    var toolRows: [UsageStore.ActivitySummaryRow] = []
    var skillRows: [UsageStore.ActivitySummaryRow] = []
    var exactSkillRows: [UsageStore.ActivitySummaryRow] = []
    var timelineRows: [ActivityEvent] = []
    var matrixRows: [String: [UsageStore.ActivitySummaryRow]] = [:]
    var lastScan: ScanSchedulerStatus.Last?

    static let empty = ActivityDashboardSnapshot()
}

/// Activity 页面专用状态：隔离全局轮询，并把一次查询结果原子发布。
@MainActor
final class ActivityPageState: ObservableObject {
    @Published var range = "week"
    @Published var agent: String?
    @Published var confidence = "exact"
    @Published private(set) var snapshot = ActivityDashboardSnapshot.empty
    private(set) var isLoading = false

    private var generation = 0
    private var refreshInFlight = false
    private var pendingRefresh = false

    var filter: ActivityFilter {
        ActivityFilter(range: range, agent: agent, confidence: confidence)
    }

    /// 相同时间到达的扫描、轮询和筛选刷新只保留最后一次。
    func beginRefresh() -> ActivityRefreshRequest? {
        generation += 1
        if refreshInFlight {
            pendingRefresh = true
            return nil
        }
        refreshInFlight = true
        isLoading = true
        return ActivityRefreshRequest(generation: generation, filter: filter)
    }

    /// 返回非 nil 表示有一个合并后的刷新需要继续执行。
    func finish(_ request: ActivityRefreshRequest,
                snapshot newSnapshot: ActivityDashboardSnapshot?) -> ActivityRefreshRequest? {
        if request.generation == generation, request.filter == filter,
           let newSnapshot, newSnapshot != snapshot {
            snapshot = newSnapshot
        }

        refreshInFlight = false
        if pendingRefresh {
            pendingRefresh = false
            refreshInFlight = true
            return ActivityRefreshRequest(generation: generation, filter: filter)
        }
        isLoading = false
        return nil
    }
}
