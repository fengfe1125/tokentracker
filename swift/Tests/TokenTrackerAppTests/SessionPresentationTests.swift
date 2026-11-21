import AppKit
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

final class SessionPresentationTests: XCTestCase {
    private var previousLanguage = "en"

    override func setUp() {
        super.setUp()
        previousLanguage = L10n.language
        L10n.setLanguage("zh-Hans")
    }

    override func tearDown() {
        L10n.setLanguage(previousLanguage)
        super.tearDown()
    }

    func testSessionTokenBreakdownAndCostFormatting() {
        var stats = UsageStore.ToolStats()
        stats.input = 696
        stats.output = 484_000
        stats.cacheRead = 104_000_000
        stats.cacheWrite = 1_537_000
        stats.tokens = stats.input + stats.output + stats.cacheRead + stats.cacheWrite
        stats.events = 10
        stats.unpriced = 0
        stats.cost = 42.72

        XCTAssertEqual(
            UIFormat.sessionTokenBreakdown(stats, yi: true),
            "输入 696 · 输出 48.4万 · 缓存 1.04亿 · 写入 153.7万")
        XCTAssertEqual(UIFormat.sessionCost(stats), "$42.72")
        XCTAssertNil(UIFormat.sessionPartialUnpricedNote(stats))

        L10n.setLanguage("en")
        XCTAssertEqual(
            UIFormat.sessionTokenBreakdown(stats, yi: true),
            "Input 696 · Output 484.0K · Cache 104.00M · Write 1.54M")

        L10n.setLanguage("zh-Hans")
        stats.unpriced = 10
        stats.cost = 0
        XCTAssertEqual(UIFormat.sessionCost(stats), "未计价")
        XCTAssertNil(UIFormat.sessionPartialUnpricedNote(stats))

        stats.unpriced = 2
        stats.cost = 12.5
        XCTAssertEqual(UIFormat.sessionCost(stats), "$12.50")
        XCTAssertEqual(UIFormat.sessionPartialUnpricedNote(stats), "含 2 条未计价")

        L10n.setLanguage("en")
        XCTAssertEqual(UIFormat.sessionPartialUnpricedNote(stats), "2 unpriced")
    }

    func testSessionTimeRangeFormatsSingleSameDayAndCrossDayRanges() {
        let tz = TimeZone(secondsFromGMT: 8 * 3600)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func ms(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Int64 {
            let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let t1 = ms(2026, 11, 21, 10, 15)
        let t2 = ms(2026, 11, 21, 12, 30)
        let t3 = ms(2026, 11, 22, 8, 5)

        XCTAssertEqual(
            UIFormat.sessionTimeRange(firstMs: t1, lastMs: t1, timeZone: tz),
            "2026-11-21 10:15")
        XCTAssertEqual(
            UIFormat.sessionTimeRange(firstMs: t1, lastMs: t2, timeZone: tz),
            "2026-11-21 10:15 → 12:30")
        XCTAssertEqual(
            UIFormat.sessionTimeRange(firstMs: t1, lastMs: t3, timeZone: tz),
            "2026-11-21 10:15 → 2026-11-22 08:05")
        XCTAssertEqual(
            UIFormat.sessionTimeRange(firstMs: nil, lastMs: nil, fallbackLastSeen: "2026-11-21 12:30:45", timeZone: tz),
            "2026-11-21 12:30")
        XCTAssertEqual(
            UIFormat.sessionTimeRange(firstMs: nil, lastMs: nil, fallbackLastSeen: nil, timeZone: tz),
            "—")
    }

    func testSessionRowModelUsesRealFolderAndPrimaryModel() {
        var stats = UsageStore.ToolStats()
        stats.input = 696
        stats.output = 484_000
        stats.cacheRead = 104_000_000
        stats.cacheWrite = 1_537_000
        stats.tokens = 106_021_696
        stats.events = 4
        stats.cost = 42.72
        let row = UsageStore.SessionRow(
            tool: "claude",
            sessionID: "1bac6cac-aa7f-48b3-befe-0d0bc188f811",
            project: "-Volumes-Developer-----",
            workspacePath: "/Volumes/Developer/MyWorkspace",
            workspaceExists: true,
            filePath: "/Users/alice/.claude/projects/-Volumes-Developer-----/1bac6cac-aa7f-48b3-befe-0d0bc188f811.jsonl",
            fileExists: true,
            lastSeen: "2026-11-21 12:30:00",
            firstTs: 1_795_140_900_000,
            ts: 1_795_149_000_000,
            model: "claude-opus-5-5",
            models: ["claude-opus-5-5", "claude-sonnet-4-5"],
            title: "测试会话",
            stats: stats)
        let model = SessionRowModel(row: row)
        XCTAssertEqual(model.folderShort, "MyWorkspace")
        XCTAssertEqual(model.modelShort, "claude-opus-5-5 +1")
        XCTAssertEqual(model.modelsText, "claude-opus-5-5 · claude-sonnet-4-5")
        XCTAssertEqual(model.costLabel, "$42.72")
        XCTAssertTrue(model.sessionSubtitle.contains("MyWorkspace"))
        XCTAssertTrue(model.sessionSubtitle.contains("1bac6cac-aa7f-48b3-befe-0d0bc188f811"))
    }

    @MainActor
    func testSessionsAndSessionDetailRenderWithSelectedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = ["TT_UI_PREVIEW", "TOKENTRACKER_SETTINGS", "TOKENTRACKER_PRICES"]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        setenv(keys[0], "1", 1)
        setenv(keys[1], directory.appendingPathComponent("settings.json").path, 1)
        setenv(keys[2], directory.appendingPathComponent("prices.json").path, 1)
        let state = AppState(dbPath: directory.appendingPathComponent("usage.db").path)
        for (key, value) in zip(keys, previous) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }

        var stats = UsageStore.ToolStats()
        stats.input = 696
        stats.output = 484_000
        stats.cacheRead = 104_000_000
        stats.cacheWrite = 1_537_000
        stats.tokens = 106_021_696
        stats.events = 2
        stats.cost = 42.72
        let session = UsageStore.SessionRow(
            tool: "claude",
            sessionID: "1bac6cac-aa7f-48b3-befe-0d0bc188f811",
            project: "-Volumes-Developer-----",
            workspacePath: directory.path,
            workspaceExists: true,
            filePath: directory.appendingPathComponent("1bac6cac-aa7f-48b3-befe-0d0bc188f811.jsonl").path,
            fileExists: false,
            lastSeen: "2026-11-21 12:30:00",
            firstTs: 1_795_140_900_000,
            ts: 1_795_149_000_000,
            model: "claude-opus-5-5",
            models: ["claude-opus-5-5"],
            title: "测试会话",
            stats: stats)
        state.sessionRows = [session]
        state.selectedSessionID = SessionRowModel(row: session).id

        let listHost = NSHostingView(rootView: SessionsView(state: state).frame(width: 960, height: 640))
        XCTAssertTrue(listHost.fittingSize.width.isFinite)
        XCTAssertTrue(listHost.fittingSize.height.isFinite)

        let detailHost = NSHostingView(rootView: SessionDetailView(state: state).frame(width: 960, height: 640))
        XCTAssertTrue(detailHost.fittingSize.width.isFinite)
        XCTAssertTrue(detailHost.fittingSize.height.isFinite)
    }
}
