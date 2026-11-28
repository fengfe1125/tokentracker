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
        let agWindows = [
            SubscriptionWindow(id: "gemini", name: "Gemini", usedPercent: 62),
            SubscriptionWindow(id: "claude-gpt", name: "Claude / GPT", usedPercent: 95),
        ]
        let entries = QuotaRefresh.menuEntries([
            card(.codex, token: "active", active: true, status: .current, windows: windows),
            card(.claude, token: "other", active: false, status: .current, windows: windows),
            card(.antigravity, token: "ag-active", active: true, status: .current, windows: agWindows),
        ])
        XCTAssertEqual(entries.map(\.id), ["claude", "kimi", "go", "codex", "antigravity"])
        let codex = entries.first { $0.id == "codex" }
        XCTAssertEqual(codex?.windows.map(\.pct), [48, 7])
        XCTAssertEqual(codex?.windows.map(\.label), ["5 小时", "周 (7天)"])
        XCTAssertEqual(codex?.windows.first?.source, "official")
        XCTAssertEqual(codex?.sampledAt, 1_800_000_000)
        let ag = entries.first { $0.id == "antigravity" }
        XCTAssertEqual(ag?.name, "Antigravity")
        XCTAssertEqual(ag?.windows.map(\.label), ["Gemini", "Claude / GPT"])
        XCTAssertEqual(ag?.windows.map(\.pct), [62, 95])
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

    func testAntigravityFourWindowsGroupingLabelsLocalizationAndHistory() throws {
        let agWindows = [
            SubscriptionWindow(id: "gemini-5h", name: "Gemini", duration: 18_000, usedPercent: 54),
            SubscriptionWindow(id: "gemini-weekly", name: "Gemini", duration: 604_800, usedPercent: 15),
            SubscriptionWindow(id: "3p-5h", name: "Claude / GPT", duration: 18_000, usedPercent: 0),
            SubscriptionWindow(id: "3p-weekly", name: "Claude / GPT", duration: 604_800, usedPercent: 0),
        ]
        let agCard = card(.antigravity, token: "ag-4", active: true, status: .current, windows: agWindows)
        let entries = QuotaRefresh.menuEntries([agCard])
        let ag = try XCTUnwrap(entries.first { $0.id == "antigravity" })
        XCTAssertEqual(ag.windows.map(\.label), [
            "Gemini · 5 小时", "Gemini · 周 (7天)",
            "Claude / GPT · 5 小时", "Claude / GPT · 周 (7天)",
        ])
        XCTAssertEqual(ag.windows.map(\.pct), [54, 15, 0, 0])

        let previous = L10n.language
        defer { L10n.setLanguage(previous) }
        L10n.setLanguage("en")
        let localized = UIFormat.quotaEntry(ag)
        XCTAssertEqual(localized.windows.map(\.label), [
            "Gemini · 5 hours", "Gemini · Week (7 days)",
            "Claude / GPT · 5 hours", "Claude / GPT · Week (7 days)",
        ])
        L10n.setLanguage("zh-Hans")
        let groups = try XCTUnwrap(SubscriptionWindowGroup.groups(from: agWindows))
        XCTAssertEqual(groups.map(\.title), ["Gemini", "Claude / GPT"])
        XCTAssertEqual(groups[0].windows.map(SubscriptionText.windowInGroup), ["5 小时", "周 (7天)"])
        XCTAssertEqual(groups[1].windows.map(SubscriptionText.windowInGroup), ["5 小时", "周 (7天)"])
        XCTAssertNil(SubscriptionWindowGroup.groups(from: windows), "Codex 无同名多周期窗口时保持平铺")
        XCTAssertNil(SubscriptionWindowGroup.groups(from: [
            SubscriptionWindow(id: "gemini", name: "Gemini", usedPercent: 54),
            SubscriptionWindow(id: "claude-gpt", name: "Claude / GPT", usedPercent: 0),
        ]), "旧版 2 项池快照保持平铺")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try UsageStore(path: dir.appendingPathComponent("usage.db").path)
        try QuotaRefresh.record(store: store, cards: [agCard])
        XCTAssertEqual(try store.conn.scalarInt("SELECT COUNT(*) FROM quota_samples WHERE identity LIKE 'antigravity:%'"), 4)
    }
}
