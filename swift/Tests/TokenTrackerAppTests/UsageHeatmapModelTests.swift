import Combine
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class UsageHeatmapModelTests: XCTestCase {
    func testCacheReuseDatabaseInvalidationAndLatestRangeWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.db").path
        let writer = try UsageStore(path: path)
        let now = Date()
        try writer.putEvent(tool: "codex", srcKey: "a", ts: Int64(now.timeIntervalSince1970 * 1000), input: 10)
        let model = UsageHeatmapModel(path: path)
        func refresh() async {
            let done = expectation(description: "heatmap loaded")
            let sub = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
            model.refresh()
            await fulfillment(of: [done], timeout: 5)
            sub.cancel()
        }
        await refresh()
        XCTAssertEqual(model.chart?.totalTokens, 10)
        let id = model.chart?.id
        await refresh()
        XCTAssertEqual(model.chart?.id, id, "An unchanged database and range must reuse the compiled chart")
        try writer.putEvent(tool: "new-agent", srcKey: "b", ts: Int64(now.timeIntervalSince1970 * 1000), input: 20)
        await refresh()
        XCTAssertEqual(model.chart?.totalTokens, 30)
        XCTAssertNotEqual(model.chart?.id, id)
        model.request.range = "all"
        await refresh()
        XCTAssertEqual(model.loadedRequest?.range, "all")
        model.request.range = "day"
        model.refresh()
        model.request.range = "month"
        await refresh()
        XCTAssertEqual(model.loadedRequest?.range, "month")
        XCTAssertEqual(model.chart?.totalTokens, 30)
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.failed)
    }

    func testAgentFilterNarrowsDaysHoursAndTotalsAndSwitchesBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.db").path
        let writer = try UsageStore(path: path)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try writer.putEvent(tool: "codex", srcKey: "a", ts: now, input: 10)
        try writer.putEvent(tool: "dsh", srcKey: "b", ts: now, input: 20)
        let model = UsageHeatmapModel(path: path)
        func refresh() async {
            let done = expectation(description: "heatmap loaded")
            let sub = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
            model.refresh()
            await fulfillment(of: [done], timeout: 5)
            sub.cancel()
        }
        for range in ["week", "all"] {
            model.request = HeatmapRequest(range: range)
            await refresh()
            XCTAssertEqual(model.chart?.totalTokens, 30, range)
            model.request = HeatmapRequest(range: range, tool: "dsh")
            await refresh()
            XCTAssertEqual(model.chart?.totalTokens, 20, range)
            XCTAssertEqual(model.loadedRequest?.tool, "dsh")
            // 没有用量的 Agent 是空图，不是全部 Agent 的回退
            model.request = HeatmapRequest(range: range, tool: "pi")
            await refresh()
            XCTAssertEqual(model.chart?.totalTokens, 0, range)
        }
        model.request = HeatmapRequest(range: "week")
        await refresh()
        XCTAssertEqual(model.chart?.totalTokens, 30)
    }

    func testWeekLoadPrewarmsDaySwitchAndInvalidatesBothAfterDatabaseWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.db").path
        let writer = try UsageStore(path: path)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        try writer.putEvent(tool: "codex", srcKey: "today", ts: Int64(now.timeIntervalSince1970 * 1000), input: 10)
        try writer.putEvent(tool: "dsh", srcKey: "yesterday", ts: Int64(yesterday.timeIntervalSince1970 * 1000), input: 20)

        let model = UsageHeatmapModel(path: path)
        func refresh() async {
            let done = expectation(description: "heatmap loaded")
            let sub = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
            model.refresh()
            await fulfillment(of: [done], timeout: 5)
            sub.cancel()
        }

        // 默认「近 7 天」连续刷新两次（模拟启动 + onAppear），「今天」仍应留在主线程缓存中。
        model.request = HeatmapRequest(range: "week")
        model.refresh()
        await refresh()
        XCTAssertEqual(model.chart?.totalTokens, 30)
        let weekID = try XCTUnwrap(model.chart?.id)

        XCTAssertTrue(model.applyCachedIfAvailable(for: HeatmapRequest(range: "day")))
        XCTAssertEqual(model.loadedRequest?.range, "day")
        XCTAssertEqual(model.chart?.totalTokens, 10)
        let dayID = try XCTUnwrap(model.chart?.id)

        model.request = HeatmapRequest(range: "day")
        await refresh()
        XCTAssertEqual(model.chart?.id, dayID, "Warm day switch must reuse the prewarmed chart when DB is unchanged")

        // 「本月」同样在加载「近 7 天」时顺手预编译（零额外 SQL），直接同帧命中缓存。
        XCTAssertTrue(model.applyCachedIfAvailable(for: HeatmapRequest(range: "month")))
        XCTAssertEqual(model.loadedRequest?.range, "month")
        XCTAssertEqual(model.chart?.style, .monthCalendar)
        let monthID = try XCTUnwrap(model.chart?.id)

        model.request = HeatmapRequest(range: "month")
        await refresh()
        XCTAssertEqual(model.chart?.id, monthID, "Warm month switch must reuse the prewarmed chart when DB is unchanged")

        // 切回「近 7 天」也直接复用缓存实例。
        XCTAssertTrue(model.applyCachedIfAvailable(for: HeatmapRequest(range: "week")))
        XCTAssertEqual(model.chart?.id, weekID)
        model.request = HeatmapRequest(range: "week")
        await refresh()
        XCTAssertEqual(model.chart?.id, weekID)

        // 数据库有新写入后，各范围都必须重新计算而不是停留旧快照。
        try writer.putEvent(tool: "claude", srcKey: "today-2", ts: Int64(now.timeIntervalSince1970 * 1000), input: 5)
        await refresh()
        XCTAssertEqual(model.chart?.totalTokens, 35)
        XCTAssertNotEqual(model.chart?.id, weekID)

        model.request = HeatmapRequest(range: "day")
        await refresh()
        XCTAssertEqual(model.chart?.totalTokens, 15)
        XCTAssertNotEqual(model.chart?.id, dayID)

        model.request = HeatmapRequest(range: "month")
        await refresh()
        XCTAssertNotEqual(model.chart?.id, monthID)
    }
}
