import AppKit
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class AntigravityUITests: XCTestCase {
    func testAntigravityDisplayMetadataAndSessionFiltering() throws {
        XCTAssertEqual(toolDisplayName("antigravity"), "Antigravity")
        XCTAssertNotNil(MenuBarFmt.toolHex["antigravity"])
        XCTAssertTrue(SidebarLayout().agents.contains("antigravity"))
        XCTAssertTrue(ScannerRegistry.all.contains("antigravity"))

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tt_ag_ui_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let repoDir = tmp.appendingPathComponent("DemoProject").path
        try FileManager.default.createDirectory(atPath: repoDir, withIntermediateDirectories: true)
        let transcript = tmp.appendingPathComponent("brain/conv-ui/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let lines = [
            "{\"step_index\":0,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"created_at\":\"\(nowISO)\",\"content\":\"<USER_REQUEST>\\n实现 Antigravity 用量与会话记录\\n</USER_REQUEST>\"}",
            "{\"step_index\":1,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"created_at\":\"\(nowISO)\",\"model\":\"gemini-4-neon-xhigh\",\"input_tokens\":12500,\"cache_read_tokens\":38000,\"output_tokens\":920,\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"swift test\"}}]}",
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcript, atomically: true, encoding: .utf8)

        let mapPath = tmp.appendingPathComponent("workspaces.json").path
        XCTAssertTrue(AntigravityWorkspaceMap.record(conversationID: "conv-ui",
                                                     workspace: repoDir,
                                                     path: mapPath))

        let dbPath = tmp.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: dbPath)
        let scanner = AntigravityScanner(roots: [tmp.appendingPathComponent("brain").path],
                                         workspaceMapPath: mapPath)
        let outcome = try scanner.scan(store, .default, full: false)
        XCTAssertEqual(outcome.added, 1)

        var roots = ScanRoots(environment: [:])
        roots.antigravityRoots = [tmp.appendingPathComponent("brain").path]
        roots.antigravityWorkspaceMap = mapPath
        let rows = try store.sessions(rangeKey: "all", tool: "antigravity", roots: roots)
        XCTAssertEqual(rows.count, 1)
        let rowModel = SessionRowModel(row: rows[0])
        XCTAssertEqual(rowModel.toolName, "Antigravity")
        XCTAssertEqual(rowModel.title, "实现 Antigravity 用量与会话记录")
        XCTAssertEqual(rowModel.folderShort, "DemoProject")
        XCTAssertTrue(rowModel.isUnpriced)
        XCTAssertEqual(rowModel.costLabel, L10n.text("未计价"))
        XCTAssertTrue(rowModel.fileExists)
        XCTAssertTrue(rowModel.workspaceExists)

        guard let outDir = ProcessInfo.processInfo.environment["TT_VERIFY_ANTIGRAVITY_UI_DIR"],
              !outDir.isEmpty else { return }

        _ = NSApplication.shared
        let state = AppState(dbPath: dbPath)
        state.range = "all"
        state.sessionRows = rows
        let (statRows, statTotal, statSummary) = try store.stats(rangeKey: "all")
        state.statRows = statRows
        state.statTotal = statTotal
        state.statSummary = statSummary
        state.dailyRows = try store.daily(rangeKey: "all")
        state.modelRows = try store.models(rangeKey: "all")

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
        window.setContentSize(NSSize(width: 1120, height: 720))

        func pump(_ seconds: TimeInterval = 0.45) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        func snap(_ name: String) throws {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            pump(0.45)
            guard let frameView = window.contentView?.superview else { return }
            frameView.layoutSubtreeIfNeeded()
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
            }
        }

        let prevTab = UserDefaults.standard.string(forKey: SettingsTab.storageKey)
        defer {
            if let prevTab { UserDefaults.standard.set(prevTab, forKey: SettingsTab.storageKey) }
            window.orderOut(nil)
        }
        window.orderFrontRegardless()
        pump(0.4)

        // 1. Settings -> 提醒与集成（Antigravity 任务提醒 Hooks 与工作区映射区块）
        UserDefaults.standard.set(SettingsTab.integrations.rawValue, forKey: SettingsTab.storageKey)
        state.selection = .settings
        try snap("ag_settings_integrations")

        // 2. Settings -> 外观与状态栏（状态栏与刘海圆环包含 Antigravity）
        state.subscriptionCards = SubscriptionCard.previewCards()
        state.quotaEntries = QuotaRefresh.menuEntries(state.subscriptionCards)
        let prevNotchEnabled = NotchHUDPreferences.shared.enabled
        NotchHUDPreferences.shared.enabled = true
        defer { NotchHUDPreferences.shared.enabled = prevNotchEnabled }
        UserDefaults.standard.set(SettingsTab.appearance.rawValue, forKey: SettingsTab.storageKey)
        state.selection = .settings
        try snap("ag_settings_appearance")

        // 3. 账号页（Antigravity 自动读取本机登录、多池配额圆环、菜单栏绑定）
        state.selection = .accounts
        state.accountFocus = state.subscriptionCards.first { $0.account.provider == .antigravity }?.id
        try snap("ag_accounts")

        // 4. 用量 -> 会话记录（显示 Antigravity 会话、项目目录、未计价、记录文件按钮）
        state.selection = .usage
        state.usageTab = .sessions
        state.agentFilter = "antigravity"
        state.sessionRows = rows
        try snap("ag_sessions")

        // 5. 会话详情（显示 Antigravity 详情、模型分解未计价、工具摘要）
        state.selectedSessionID = rowModel.id
        state.showSessionDetail()
        try snap("ag_session_detail")
    }
}
