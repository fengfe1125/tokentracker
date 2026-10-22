import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

final class QuotaRefreshTests: XCTestCase {
    private func card(_ provider: SubscriptionProvider, token: String, active: Bool,
                      status: SubscriptionStatus, windows: [SubscriptionWindow]) -> SubscriptionCard {
        SubscriptionCard(account: SubscriptionAccount(provider: provider, source: SubscriptionSource(tool: "Test", location: "fixture"),
                                                      isActive: active,
                                                      credential: SubscriptionCredential(kind: .oauth, token: token)),
                         snapshot: SubscriptionSnapshot(status: status, windows: windows,
                                                        sampledAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private let windows = [SubscriptionWindow(id: "primary_window", duration: 18_000, usedPercent: 48),
                           SubscriptionWindow(id: "secondary_window", duration: 604_800, usedPercent: 7)]

    func testMenuBarUsesActiveOfficialAccountOnlyWithoutLocalEstimates() {
        let entries = QuotaRefresh.menuEntries([
            card(.codex, token: "active", active: true, status: .current, windows: windows),
            card(.claude, token: "other", active: false, status: .current, windows: windows),
        ])
        XCTAssertEqual(entries.map(\.id), ["claude", "kimi", "go", "codex"])
        let codex = entries.first { $0.id == "codex" }
        XCTAssertEqual(codex?.windows.map(\.pct), [48, 7])
        XCTAssertEqual(codex?.windows.map(\.label), ["5 小时", "周 (7天)"])
        XCTAssertEqual(codex?.windows.first?.source, "official")
        XCTAssertEqual(codex?.sampledAt, 1_800_000_000)
        // 非当前登录账号、无数据账号不填充圆环，也没有本地估算。
        XCTAssertEqual(entries.first { $0.id == "claude" }?.windows.count, 0)
        XCTAssertEqual(entries.first { $0.id == "go" }?.windows.count, 0)
    }

    func testStaleOfficialDataIsMarkedAndFailuresShowNothing() {
        let stale = QuotaRefresh.menuEntries([card(.kimi, token: "k", active: true, status: .stale, windows: windows)])
        XCTAssertEqual(stale.first { $0.id == "kimi" }?.windows.first?.stale, true)
        let failed = QuotaRefresh.menuEntries([card(.kimi, token: "k", active: true, status: .expired, windows: [])])
        XCTAssertEqual(failed.first { $0.id == "kimi" }?.windows.count, 0)
    }

    func testHistorySamplesNeverWaitForScannerWriteTransaction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: path)
        let writer = try UsageStore(path: path)
        try store.conn.execute("PRAGMA busy_timeout=0")
        try writer.conn.beginImmediate()
        let cards = [card(.codex, token: "active", active: true, status: .current, windows: windows)]
        let started = Date()
        try QuotaRefresh.record(store: store, cards: cards)
        XCTAssertEqual(try store.conn.scalarInt("SELECT COUNT(*) FROM quota_samples"), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(try store.conn.scalarInt("PRAGMA busy_timeout"), 0)
        try writer.conn.rollback()
        try QuotaRefresh.record(store: store, cards: cards)
        XCTAssertEqual(try store.conn.scalarInt("SELECT COUNT(*) FROM quota_samples WHERE identity LIKE 'codex:%'"), 2)
    }
}
