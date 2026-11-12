import XCTest
@testable import TokenTrackerApp

final class SidebarPreferencesTests: XCTestCase {
    @MainActor
    func testVisibilityAndOrderingPersistAndReset() async throws {
        let name = "tt.sidebar.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = SidebarPreferences(defaults: defaults)
        let original = prefs.layout
        prefs.setVisible("usage", in: .navigation, visible: false)
        prefs.setVisible("dsh", in: .agents, visible: false)
        prefs.move("accounts", in: .navigation, by: -1)
        prefs.move("dsh", in: .agents, by: -1)
        let reloaded = SidebarPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.layout, prefs.layout)
        XCTAssertFalse(reloaded.isVisible("usage", in: .navigation))
        XCTAssertFalse(reloaded.isVisible("dsh", in: .agents))
        XCTAssertEqual(reloaded.order(.navigation)[3], "accounts")
        XCTAssertEqual(reloaded.order(.agents)[2], "dsh")
        reloaded.setVisible("settings", in: .navigation, visible: false)
        XCTAssertFalse(reloaded.layout.hiddenNavigation.contains("settings"))
        reloaded.reset()
        XCTAssertEqual(SidebarPreferences(defaults: defaults).layout, original)
    }

    @MainActor
    func testDragAcrossMultipleRowsPreservesOtherItemsAndVisibility() async throws {
        let name = "tt.sidebar.drag.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = SidebarPreferences(defaults: defaults)
        prefs.setVisible("usage", in: .navigation, visible: false)
        prefs.move(in: .navigation, from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(prefs.order(.navigation), ["usage", "activity", "reports", "overview", "accounts"])
        prefs.move(in: .navigation, from: IndexSet(integer: 4), to: 0)
        XCTAssertEqual(prefs.order(.navigation), ["accounts", "usage", "activity", "reports", "overview"])
        let before = prefs.layout
        prefs.move(in: .navigation, from: IndexSet(integer: 99), to: 0)
        prefs.move(in: .navigation, from: [], to: 0)
        XCTAssertEqual(prefs.layout, before)
        XCTAssertEqual(SidebarPreferences(defaults: defaults).layout, before)
        XCTAssertFalse(prefs.isVisible("usage", in: .navigation))
    }

    func testSavedLayoutDropsUnknownDuplicatesAndAddsNewItems() {
        var layout = SidebarLayout()
        layout.navigation = ["activity", "unknown", "activity"]
        layout.agents = ["dsh", "removed", "dsh"]
        layout.hiddenAgents = ["dsh", "removed"]
        let normalized = layout.normalized()
        XCTAssertEqual(normalized.navigation.first, "activity")
        XCTAssertEqual(normalized.agents.first, "dsh")
        XCTAssertEqual(Set(normalized.navigation), Set(SidebarLayout().navigation))
        XCTAssertEqual(normalized.agents.count, SidebarLayout().agents.count)
        XCTAssertEqual(normalized.hiddenAgents, ["dsh"])
    }

    func testLayoutSavedBeforeNavigationWasMergedKeepsSurvivingOrderAndAddsNewEntries() {
        // v0.5.9 的入口：项目 / 会话并入「用量」，订阅并入「账号」
        var layout = SidebarLayout()
        layout.navigation = ["reports", "projects", "subscriptions", "overview", "sessions", "activity"]
        layout.hiddenNavigation = ["projects", "reports"]
        let normalized = layout.normalized()
        XCTAssertEqual(normalized.navigation, ["reports", "usage", "accounts", "overview", "activity"])
        XCTAssertEqual(normalized.hiddenNavigation, ["reports"])
    }
}
