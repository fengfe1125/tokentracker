import Combine
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class ActivityPageStateTests: XCTestCase {
    func testIdenticalSnapshotDoesNotPublishAgain() {
        let state = ActivityPageState()
        var publications = 0
        let cancellable = state.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { cancellable.cancel() }

        let request = try! XCTUnwrap(state.beginRefresh())
        XCTAssertNil(state.finish(request, snapshot: .empty))
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(state.isLoading)
    }

    func testStaleResultIsDiscardedAndPendingRefreshIsCoalesced() throws {
        let state = ActivityPageState()
        let first = try XCTUnwrap(state.beginRefresh())

        state.range = "day"
        XCTAssertNil(state.beginRefresh())
        XCTAssertNil(state.beginRefresh())

        let stale = ActivityDashboardSnapshot(exactRows: [summary("stale")])
        let next = try XCTUnwrap(state.finish(first, snapshot: stale))
        XCTAssertEqual(state.snapshot, .empty)
        XCTAssertEqual(next.filter.range, "day")
        XCTAssertTrue(state.isLoading)

        let fresh = ActivityDashboardSnapshot(exactRows: [summary("fresh")])
        XCTAssertNil(state.finish(next, snapshot: fresh))
        XCTAssertEqual(state.snapshot, fresh)
        XCTAssertFalse(state.isLoading)
    }

    func testFailedRefreshStillRunsOnlyOnePendingRequest() throws {
        let state = ActivityPageState()
        let first = try XCTUnwrap(state.beginRefresh())
        XCTAssertNil(state.beginRefresh())
        XCTAssertNil(state.beginRefresh())

        let next = try XCTUnwrap(state.finish(first, snapshot: nil))
        XCTAssertNil(state.finish(next, snapshot: nil))
        XCTAssertFalse(state.isLoading)
    }

    private func summary(_ name: String) -> UsageStore.ActivitySummaryRow {
        UsageStore.ActivitySummaryRow(name: name, calls: 1, sessions: 1,
            success: 1, errors: 0, denied: 0, unknown: 0,
            exact: 1, derived: 0, lastUsed: 1)
    }
}
