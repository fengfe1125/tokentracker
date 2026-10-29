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
        model.request.period = .all
        model.request.period = .day
        model.request.period = .month
        await refresh()
        XCTAssertEqual(model.loadedRequest?.period, .month)
        XCTAssertEqual(model.chart?.totalTokens, 30)
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.failed)
    }
}
