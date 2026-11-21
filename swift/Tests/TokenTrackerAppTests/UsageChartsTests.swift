import AppKit
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

final class UsageChartsTests: XCTestCase {
    private func makeTotals(input: Int64 = 0, output: Int64 = 0,
                            cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
                            records: Int64 = 1, sessions: Int64 = 1,
                            unpriced: Int64 = 0, cost: Double = 0) -> UsageTotals {
        var t = UsageTotals()
        t.input = input
        t.output = output
        t.cacheRead = cacheRead
        t.cacheWrite = cacheWrite
        t.records = records
        t.sessions = sessions
        t.unpriced = unpriced
        t.cost = cost
        return t
    }

    private func makeStats(tool: String, input: Int64 = 0, output: Int64 = 0,
                           cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
                           events: Int64 = 1, unpriced: Int64 = 0,
                           cost: Double = 0) -> UsageStore.ToolStats {
        var s = UsageStore.ToolStats()
        s.tool = tool
        s.input = input
        s.output = output
        s.cacheRead = cacheRead
        s.cacheWrite = cacheWrite
        s.tokens = input + output + cacheRead + cacheWrite
        s.events = events
        s.unpriced = unpriced
        s.cost = cost
        return s
    }

    func testProjectDonutRollsOtherOnlyWhenMoreThanOneTailItem() {
        let six = (1...6).map { idx in
            ProjectSummary(id: "p\(idx)", name: "Proj \(idx)",
                           totals: makeTotals(input: Int64(700 - idx * 100), cost: Double(7 - idx)),
                           lastActivity: nil)
        }
        let sixData = UsageChartBuilder.projectDonut(projects: six, metric: .tokens, maxSlices: 5)
        XCTAssertEqual(sixData.slices.count, 6)
        XCTAssertFalse(sixData.slices.contains { $0.isOther })

        let seven = six + [
            ProjectSummary(id: "p7", name: "Proj 7", totals: makeTotals(input: 50, cost: 0.2), lastActivity: nil)
        ]
        let sevenData = UsageChartBuilder.projectDonut(projects: seven, metric: .tokens, maxSlices: 5)
        XCTAssertEqual(sevenData.slices.count, 6)
        XCTAssertTrue(sevenData.slices.last?.isOther == true)
        XCTAssertEqual(sevenData.slices.last?.colorIndex, -1)
        XCTAssertNil(sevenData.slices.last?.targetID)
        XCTAssertEqual(sevenData.slices.last?.tokens, 150)
    }

    func testProjectDonutCostExcludesUnpricedWithoutFabricatingZero() {
        let projects = [
            ProjectSummary(id: "p1", name: "Alpha",
                           totals: makeTotals(input: 1000, records: 2, unpriced: 0, cost: 3.0),
                           lastActivity: nil),
            ProjectSummary(id: "p2", name: "UnpricedProj",
                           totals: makeTotals(input: 5000, records: 3, unpriced: 3, cost: 0),
                           lastActivity: nil),
            ProjectSummary(id: "unassigned", name: "未归属",
                           totals: makeTotals(input: 500, records: 1, unpriced: 0, cost: 1.0),
                           lastActivity: nil),
        ]
        let costData = UsageChartBuilder.projectDonut(projects: projects, metric: .cost)
        XCTAssertEqual(costData.unpricedItemCount, 1)
        XCTAssertEqual(costData.slices.map(\.id), ["p1", "unassigned"])
        XCTAssertEqual(costData.slices[0].share, 0.75, accuracy: 0.001)
        XCTAssertEqual(costData.slices[1].colorIndex, -1) // unassigned is neutral gray

        let allUnpriced = [projects[1]]
        let emptyCost = UsageChartBuilder.projectDonut(projects: allUnpriced, metric: .cost)
        XCTAssertTrue(emptyCost.slices.isEmpty)
        XCTAssertEqual(emptyCost.unpricedItemCount, 1)
    }

    func testCacheHitItemsExcludeZeroInputSideAndSortByRate() {
        let rows = [
            UsageStore.ModelRow(tool: "claude", model: "claude-sonnet-4-5",
                                stats: makeStats(tool: "claude", input: 100, output: 50, cacheRead: 900, cost: 1.2)),
            UsageStore.ModelRow(tool: "codex", model: "gpt-5.4",
                                stats: makeStats(tool: "codex", input: 500, output: 100, cacheRead: 500, cost: 1.0)),
            UsageStore.ModelRow(tool: "kimi", model: "output-only",
                                stats: makeStats(tool: "kimi", input: 0, output: 800, cacheRead: 0, unpriced: 1, cost: 0)),
        ]
        let items = UsageChartBuilder.cacheHitItems(rows: rows)
        XCTAssertEqual(items.map(\.label), ["claude-sonnet-4-5", "gpt-5.4"])
        XCTAssertEqual(items[0].hitRate, 90.0, accuracy: 0.01)
        XCTAssertEqual(items[1].hitRate, 50.0, accuracy: 0.01)
    }

    func testDonutPolarHitTestMatchesClockwiseFromTop() {
        let slices = [
            UsageDonutSlice(id: "right", label: "Right", subtitle: nil, value: 50, share: 0.5,
                            tokens: 50, costText: "$1.00", colorIndex: 0, isOther: false, targetID: "right"),
            UsageDonutSlice(id: "left", label: "Left", subtitle: nil, value: 50, share: 0.5,
                            tokens: 50, costText: "$1.00", colorIndex: 1, isOther: false, targetID: "left"),
        ]
        let size = CGSize(width: 160, height: 160) // center (80,80), R=80, inner=44.8
        // 3 o'clock (right half) -> first slice
        XCTAssertEqual(UsageChartBuilder.sliceID(at: CGPoint(x: 140, y: 80), in: size, slices: slices), "right")
        // 9 o'clock (left half) -> second slice
        XCTAssertEqual(UsageChartBuilder.sliceID(at: CGPoint(x: 20, y: 80), in: size, slices: slices), "left")
        // Center hole -> nil
        XCTAssertNil(UsageChartBuilder.sliceID(at: CGPoint(x: 80, y: 80), in: size, slices: slices))
        // Outside circle -> nil
        XCTAssertNil(UsageChartBuilder.sliceID(at: CGPoint(x: 2, y: 2), in: size, slices: slices))
    }

    @MainActor
    func testUsageVisualizationsRenderCleanly() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tt_usage_charts_ui_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbPath = tmp.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: dbPath)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let repoA = tmp.appendingPathComponent("TokenTracker").path
        let repoB = tmp.appendingPathComponent("WebDashboard").path
        let repoC = tmp.appendingPathComponent("MobileClient").path
        for repo in [repoA, repoB, repoC] {
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        }

        // 构造 3 个项目、4 个模型（含 1 个未计价模型）和 5 个会话，验证正常与边界渲染
        try store.putEvent(tool: "claude", srcKey: "c1", sessionID: "sess-tt-1", project: repoA,
                           ts: nowMs - 3_600_000, model: "claude-opus-4-6",
                           input: 180_000, output: 52_000, cacheRead: 1_450_000, cacheWrite: 210_000, cost: 4.82)
        try store.recordProjectPath(tool: "claude", srcKey: "c1", path: repoA)
        try store.putEvent(tool: "codex", srcKey: "x1", sessionID: "sess-tt-2", project: repoA,
                           ts: nowMs - 7_200_000, model: "gpt-5.4",
                           input: 140_000, output: 36_000, cacheRead: 760_000, cacheWrite: 60_000, cost: 1.94)
        try store.recordProjectPath(tool: "codex", srcKey: "x1", path: repoA)
        try store.putEvent(tool: "claude", srcKey: "c2", sessionID: "sess-web-1", project: repoB,
                           ts: nowMs - 14_400_000, model: "claude-sonnet-4-5",
                           input: 260_000, output: 44_000, cacheRead: 980_000, cacheWrite: 120_000, cost: 2.36)
        try store.recordProjectPath(tool: "claude", srcKey: "c2", path: repoB)
        try store.putEvent(tool: "antigravity", srcKey: "a1", sessionID: "sess-mob-1", project: repoC,
                           ts: nowMs - 21_600_000, model: "gemini-3-pro-preview",
                           input: 220_000, output: 68_000, cacheRead: 340_000, cacheWrite: 40_000, cost: nil)
        try store.recordProjectPath(tool: "antigravity", srcKey: "a1", path: repoC)
        try store.putEvent(tool: "opencode", srcKey: "o1", sessionID: "sess-web-2", project: repoB,
                           ts: nowMs - 86_400_000, model: "deepseek-r1",
                           input: 95_000, output: 28_000, cacheRead: 150_000, cacheWrite: 15_000, cost: 0.42)
        try store.recordProjectPath(tool: "opencode", srcKey: "o1", path: repoB)
        try store.conn.commit()

        guard let outDir = ProcessInfo.processInfo.environment["TT_VERIFY_USAGE_UI_DIR"],
              !outDir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let prevSettings = ProcessInfo.processInfo.environment["TOKENTRACKER_SETTINGS"]
        let prevCollapsed = UserDefaults.standard.object(forKey: "tt.sessions.summaryCollapsed")
        setenv("TOKENTRACKER_SETTINGS", tmp.appendingPathComponent("settings.json").path, 1)
        UserDefaults.standard.set(false, forKey: "tt.sessions.summaryCollapsed")
        defer {
            if let prevSettings { setenv("TOKENTRACKER_SETTINGS", prevSettings, 1) }
            else { unsetenv("TOKENTRACKER_SETTINGS") }
            if let prevCollapsed { UserDefaults.standard.set(prevCollapsed, forKey: "tt.sessions.summaryCollapsed") }
            else { UserDefaults.standard.removeObject(forKey: "tt.sessions.summaryCollapsed") }
        }

        _ = NSApplication.shared
        let state = AppState(dbPath: dbPath)
        state.range = "week"
        state.selection = .usage
        state.usageTab = .projects

        let hosting = NSHostingController(rootView: RootView(state: state).appLanguage())
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "TokenTracker"
        window.titleVisibility = .hidden
        window.styleMask.formUnion([.miniaturizable, .resizable, .fullSizeContentView])
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1120, height: 1020))
        defer { window.orderOut(nil) }

        func pump(_ seconds: TimeInterval = 0.55) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        func snap(_ name: String) throws {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            pump(0.55)
            guard let frameView = window.contentView?.superview else { return }
            frameView.layoutSubtreeIfNeeded()
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
            }
        }

        window.orderFrontRegardless()
        state.refreshVisibleData()
        pump(0.8)

        // 1. 用量 → 项目（浅色完整展开）
        try snap("01_usage_projects_light")

        // 2. 用量 → 模型（浅色完整展开，含缓存命中率对比）
        state.usageTab = .models
        state.refreshVisibleData()
        pump(0.6)
        try snap("02_usage_models_light")

        // 3. 用量 → 会话（浅色，未选中行时底部显示分布可视化）
        window.setContentSize(NSSize(width: 1120, height: 740))
        state.usageTab = .sessions
        state.selectedSessionID = nil
        state.refreshVisibleData()
        pump(0.6)
        try snap("03_usage_sessions_light")

        // 4. 用量 → 会话（深色）
        window.appearance = NSAppearance(named: .darkAqua)
        pump(0.4)
        try snap("04_usage_sessions_dark")

        // 5. 用量 → 项目（深色）
        window.setContentSize(NSSize(width: 1120, height: 1020))
        state.usageTab = .projects
        state.refreshVisibleData()
        pump(0.5)
        try snap("05_usage_projects_dark")

        // 6. 用量 → 模型（深色）
        state.usageTab = .models
        pump(0.5)
        try snap("06_usage_models_dark")

        // 7. 窄窗口响应式（浅色）
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 840, height: 860))
        state.usageTab = .projects
        pump(0.5)
        try snap("07_usage_projects_narrow")
    }
}
