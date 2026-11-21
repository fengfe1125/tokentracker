import AppKit
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class RefactorUITests: XCTestCase {
    func testRefactoredViewsRenderCleanly() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tt_refactor_ui_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbPath = tmp.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: dbPath)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // 1. 构造用量、活动与两周去重后的周报数据
        let repoA = tmp.appendingPathComponent("TokenTracker").path
        let repoB = tmp.appendingPathComponent("WebDashboard").path
        try FileManager.default.createDirectory(atPath: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repoB, withIntermediateDirectories: true)
        try #"{"scripts":{"dev":"vite --port 5173"}}"#.write(
            toFile: repoB + "/package.json", atomically: true, encoding: .utf8)

        let weekAgo = Date().addingTimeInterval(-8 * 86400)
        let twoWeeksAgo = Date().addingTimeInterval(-15 * 86400)
        let weekAgoMs = Int64(weekAgo.timeIntervalSince1970 * 1000)
        let twoWeeksAgoMs = Int64(twoWeeksAgo.timeIntervalSince1970 * 1000)

        try store.putEvent(tool: "claude", srcKey: "c1", sessionID: "s1", project: repoA,
                           ts: weekAgoMs, model: "claude-sonnet-4-5", input: 420_000, output: 38_000,
                           cacheRead: 1_200_000, cost: 2.15)
        try store.putEvent(tool: "codex", srcKey: "x1", sessionID: "s2", project: repoB,
                           ts: weekAgoMs + 60_000, model: "gpt-5.4", input: 310_000, output: 45_000,
                           cacheRead: 880_000, cost: 1.68)
        try store.putEvent(tool: "claude", srcKey: "c0", sessionID: "s0", project: repoA,
                           ts: twoWeeksAgoMs, model: "claude-sonnet-4-5", input: 250_000, output: 20_000,
                           cacheRead: 600_000, cost: 1.10)
        try store.recordHealth(tool: "claude", outcome: ScanOutcome(added: 2, files: 1),
                               started: nowMs - 1000, finished: nowMs)
        try store.recordHealth(tool: "codex", outcome: ScanOutcome(added: 1, files: 1),
                               started: nowMs - 900, finished: nowMs)

        let r1 = try store.generateWeeklyReport(now: Date(), timeZone: .current, regenerate: true)
        let r2 = try store.generateWeeklyReport(now: Date().addingTimeInterval(-7 * 86400),
                                                timeZone: .current, regenerate: true)
        XCTAssertEqual(try store.weeklyReports().count, 2)
        XCTAssertNotEqual(r1.id, r2.id)

        // 活动事件：已确认工具、已确认 Skill、子 Agent 与少量路径推断 Skill
        for i in 0..<8 {
            try store.recordActivity(agent: "claude", srcKey: "cl-bash-\(i)", rawName: "Bash",
                                     sessionID: "s1", callID: "cb-\(i)",
                                     startedAt: nowMs - Int64((i + 1) * 60_000),
                                     endedAt: nowMs - Int64((i + 1) * 60_000) + 420,
                                     durationMs: 420, status: i == 7 ? "error" : "success",
                                     sourceKind: "claude_jsonl", confidence: "exact")
        }
        for i in 0..<6 {
            try store.recordActivity(agent: "codex", srcKey: "cx-read-\(i)", rawName: "Read",
                                     sessionID: "s2", callID: "cr-\(i)",
                                     startedAt: nowMs - Int64((i + 2) * 45_000),
                                     endedAt: nowMs - Int64((i + 2) * 45_000) + 120,
                                     durationMs: 120, status: "success",
                                     sourceKind: "codex_item_completed", confidence: "exact")
        }
        try store.recordActivity(agent: "antigravity", srcKey: "ag-edit-1", rawName: "edit_file",
                                 sessionID: "s3", startedAt: nowMs - 30_000, endedAt: nowMs - 28_600,
                                 durationMs: 1400, status: "success",
                                 sourceKind: "antigravity_jsonl", confidence: "exact")
        try store.recordActivity(agent: "claude", srcKey: "cl-skill-1", rawName: "Skill",
                                 sessionID: "s1", startedAt: nowMs - 50_000, endedAt: nowMs - 49_800,
                                 durationMs: 200, status: "success", sourceKind: "claude_jsonl",
                                 confidence: "exact", arguments: ["skill": "code-review"], eventKind: .skill)
        try store.recordActivity(agent: "codex", srcKey: "cx-agent-1", rawName: "spawn_agent",
                                 sessionID: "s2", startedAt: nowMs - 40_000, endedAt: nowMs - 30_000,
                                 durationMs: 10_000, status: "success", sourceKind: "codex_item_completed",
                                 confidence: "exact", eventKind: .agent)
        try store.putActivityEvent(ActivityEvent(
            agent: "codex", sessionID: "s2", rawName: "skill_file", canonicalName: "skill.activate",
            startedAt: nowMs - 35_000, endedAt: nowMs - 35_000, durationMs: 0, status: "success",
            sourceKind: "codex_skill_file", confidence: "derived",
            skillName: "tokentracker-release", skillConfidence: "derived",
            srcKey: "cx-skill-derived", eventKind: .skill, eventLayer: .execution))
        try store.conn.commit()

        guard let outDir = ProcessInfo.processInfo.environment["TT_VERIFY_REFACTOR_UI_DIR"],
              !outDir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let prevSettingsEnv = ProcessInfo.processInfo.environment["TOKENTRACKER_SETTINGS"]
        setenv("TOKENTRACKER_SETTINGS", tmp.appendingPathComponent("settings.json").path, 1)
        defer {
            if let prevSettingsEnv { setenv("TOKENTRACKER_SETTINGS", prevSettingsEnv, 1) }
            else { unsetenv("TOKENTRACKER_SETTINGS") }
        }

        _ = NSApplication.shared
        let state = AppState(dbPath: dbPath)
        state.range = "week"
        state.insights.reports = try store.weeklyReports()

        // 注入虚拟端口快照验证 PortsView 排版
        let p1 = ListeningPort(
            port: 5173, pids: [4100], process: "node", uid: Int(getuid()), user: "dev",
            cwd: repoB, executable: "/opt/homebrew/bin/node",
            commandLine: "/opt/homebrew/bin/node \(repoB)/node_modules/.bin/vite --port 5173",
            uptime: 4320, memoryBytes: 148 * 1024 * 1024, addresses: ["127.0.0.1", "::1"],
            serviceLabel: "Vite", projectID: "directory:\(repoB)", projectName: "WebDashboard")
        let p2 = ListeningPort(
            port: 8000, pids: [4200], process: "python3", uid: Int(getuid()), user: "dev",
            cwd: repoA, executable: "/usr/bin/python3",
            commandLine: "python3 -m uvicorn api.main:app --host 0.0.0.0 --port 8000",
            uptime: 910, memoryBytes: 86 * 1024 * 1024, addresses: ["*"],
            serviceLabel: "Uvicorn", projectID: "directory:\(repoA)", projectName: "TokenTracker")
        let p3 = ListeningPort(
            port: 5000, pids: [667], process: "ControlCenter", uid: Int(getuid()), user: "dev",
            cwd: "/", executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            uptime: 259_200, addresses: ["*"])
        state.ports.loadPreviewSnapshot(
            ports: [p3, p1, p2],
            projects: [
                PortsModel.Project(id: "directory:\(repoB)", name: "WebDashboard", root: repoB,
                                   detected: StartCommand(command: "npm run dev", file: "package.json", target: "dev"),
                                   manual: nil, ports: [p1]),
                PortsModel.Project(id: "directory:\(repoA)", name: "TokenTracker", root: repoA,
                                   detected: nil, manual: "uv run uvicorn api.main:app", ports: [p2]),
            ])
        state.updateSetting(key: "menubar_ports", value: [5173])
        state.ports.selectedPort = 5173

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
        window.setContentSize(NSSize(width: 1120, height: 740))

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

        // 1. 周报页
        state.selection = .reports
        try snap("01_reports")

        // 2. 活动页（默认已确认视图）
        state.selection = .activity
        state.refreshActivity()
        pump(0.6)
        try snap("02_activity")

        // 3. 端口页（含选中详情、框架名、状态栏固定图标、开发项目）
        state.selection = .ports
        // onAppear 会触发一次真实后台扫描，立即重新注入虚拟快照保证截图稳定
        pump(0.25)
        state.ports.loadPreviewSnapshot(
            ports: [p3, p1, p2],
            projects: [
                PortsModel.Project(id: "directory:\(repoB)", name: "WebDashboard", root: repoB,
                                   detected: StartCommand(command: "npm run dev", file: "package.json", target: "dev"),
                                   manual: nil, ports: [p1]),
                PortsModel.Project(id: "directory:\(repoA)", name: "TokenTracker", root: repoA,
                                   detected: nil, manual: "uv run uvicorn api.main:app", ports: [p2]),
            ])
        state.ports.selectedPort = 5173
        try snap("03_ports")

        // 4. 设置页 5 个分类
        state.selection = .settings
        for (idx, tab) in SettingsTab.allCases.enumerated() {
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
            try snap("04_settings_\(idx + 1)_\(tab.rawValue)")
        }

        // 5. 深色模式抽检
        window.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set(SettingsTab.appearance.rawValue, forKey: SettingsTab.storageKey)
        try snap("05_settings_appearance_dark")
    }
}
