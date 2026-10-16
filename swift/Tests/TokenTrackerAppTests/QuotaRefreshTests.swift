import XCTest
@testable import TokenTrackerApp
import TokenTrackerCore

final class QuotaRefreshTests: XCTestCase {
    func testOfficialQuotaPublishesWhileScannerOwnsWriteTransaction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: path)
        let writer = try UsageStore(path: path)
        try store.conn.execute("PRAGMA busy_timeout=0")
        try writer.conn.beginImmediate()
        defer { try? writer.conn.rollback() }
        var published: [MenuBarQuotaEntry] = []
        let result = OfficialResult(windows: ["5h": OfficialWindow(pct: 48), "7d": OfficialWindow(pct: 7)],
                                    sampledAt: Double(store.nowMs()) / 1000)
        let started = Date()
        // A sample write failure must not suppress successfully fetched display values.
        try? QuotaRefresh.load(store: store, config: .default, results: ["codex": result],
                              accountID: "test-account") { published = $0 }
        XCTAssertEqual(published.first { $0.id == "codex" }?.windows.first?.pct, 48)
        XCTAssertEqual(published.first { $0.id == "codex" }?.windows.first?.source, "official")
        XCTAssertEqual(published.first { $0.id == "codex" }?.sampledAt, result.sampledAt)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(try store.conn.scalarInt("PRAGMA busy_timeout"), 0)
        XCTAssertEqual(try store.conn.scalarInt("SELECT COUNT(*) FROM quota_samples"), 0)
        try writer.conn.rollback()
        try QuotaRefresh.load(store: store, config: .default, results: ["codex": result],
                              accountID: "test-account") { published = $0 }
        XCTAssertEqual(try store.conn.scalarInt("SELECT COUNT(*) FROM quota_samples WHERE identity LIKE 'codex:test-account:%'"), 2)
    }
}
