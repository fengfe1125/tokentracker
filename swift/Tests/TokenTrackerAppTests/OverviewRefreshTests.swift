import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class OverviewRefreshTests: XCTestCase {
    func testRangeChangeRefreshesStatisticsAndInsightsWithoutViewObserver() async throws {
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
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        try state.readStore.putEvent(tool: "codex", srcKey: "today", ts: Int64(now.timeIntervalSince1970 * 1000), input: 10)
        try state.readStore.putEvent(tool: "dsh", srcKey: "yesterday", ts: Int64(yesterday.timeIntervalSince1970 * 1000), input: 20)

        let day = expectation(description: "Today statistics refreshed after changing the selected range")
        var subscription = state.$updatedAt.dropFirst().sink { _ in
            if state.statTotal.tokens == 10 { day.fulfill() }
        }
        state.range = "day"
        XCTAssertEqual(state.insights.query.start, UsageQuery.period("day").start)
        await fulfillment(of: [day], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(state.loadedRange, "day")
        XCTAssertFalse(state.dataLoading)


        let latest = expectation(description: "Rapid changes publish only the final range")
        subscription = state.$updatedAt.dropFirst().sink { _ in
            XCTAssertEqual(state.statTotal.tokens, 30)
            latest.fulfill()
        }
        state.range = "all"
        state.range = "day"
        state.range = "week"
        await fulfillment(of: [latest], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(state.insights.query.start, UsageQuery.period("week").start)
    }

    func testHourBucketsSumToolsPerHourAndIgnoreMalformedLabels() {
        func row(_ tool: String, _ label: String, _ input: Int64) -> UsageStore.DailyRow {
            var stats = UsageStore.ToolStats()
            stats.input = input
            stats.tokens = input
            return UsageStore.DailyRow(tool: tool, day: label, stats: stats)
        }
        let hours = AppState.hourBuckets([row("codex", "09:00", 10), row("dsh", "09:00", 5),
                                          row("codex", "23:00", 7), row("codex", "2026-11-12", 99),
                                          row("codex", "24:00", 99)])
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[9], 15)
        XCTAssertEqual(hours[23], 7)
        XCTAssertEqual(hours.reduce(0, +), 22)
    }

    func testMenuBarPanelHasFiniteSizeWithAndWithoutData() throws {
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
        // 预览模式自带虚构订阅卡片；再清空一次覆盖「什么都没有」的面板
        for cards in [state.subscriptionCards, []] {
            state.subscriptionCards = cards
            let view = NSHostingView(rootView: MenuBarPanelView(state: state, actions: MenuBarPanelActions()))
            let size = view.fittingSize
            XCTAssertEqual(size.width, MenuBarPanelView.width, accuracy: 0.5)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThan(size.height, 100)
            XCTAssertLessThan(size.height, 760)
        }
    }

    func testAgentFilterScopesStatisticsSessionsInsightsAndActivityTogether() async throws {
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
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try state.readStore.putEvent(tool: "codex", srcKey: "a", sessionID: "s-codex", ts: now, input: 10)
        try state.readStore.putEvent(tool: "dsh", srcKey: "b", sessionID: "s-dsh", ts: now, input: 20)

        let filtered = expectation(description: "Only the selected agent is counted")
        var subscription = state.$updatedAt.dropFirst().sink { _ in
            if state.statTotal.tokens == 20 { filtered.fulfill() }
        }
        state.agentFilter = "dsh"
        // 同一次赋值同步到项目查询和活动页，不需要各页再选一遍
        XCTAssertEqual(state.insights.query.tool, "dsh")
        XCTAssertEqual(state.activityPage.agent, "dsh")
        await fulfillment(of: [filtered], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(state.sessionRows.map(\.sessionID), ["s-dsh"])
        XCTAssertEqual(state.dailyRows.map(\.tool), ["dsh"])
        // 菜单栏的今日量不受筛选影响
        XCTAssertEqual(state.today?.tokens, 30)
        XCTAssertEqual(state.todayHours.reduce(0, +), 30)

        let cleared = expectation(description: "Clearing the filter restores every agent")
        subscription = state.$updatedAt.dropFirst().sink { _ in
            if state.statTotal.tokens == 30 { cleared.fulfill() }
        }
        state.agentFilter = nil
        await fulfillment(of: [cleared], timeout: 3)
        subscription.cancel()
        XCTAssertNil(state.insights.query.tool)
        XCTAssertNil(state.activityPage.agent)

        // 自定义日期只覆盖时间，Agent 仍跟全局范围走；回到概览后失效
        state.selection = .usage
        state.insights.query.start = 1
        state.insights.query.end = 2
        state.insights.customRange = true
        state.range = "month"
        XCTAssertEqual(state.insights.query.start, 1)
        state.agentFilter = "codex"
        XCTAssertEqual(state.insights.query.tool, "codex")
        XCTAssertEqual(state.insights.query.end, 2)
        state.selection = .overview
        state.refreshVisibleData()
        XCTAssertFalse(state.insights.customRange)
        XCTAssertEqual(state.insights.query.start, UsageQuery.period("month").start)
    }

    func testSessionDrillDownNeedsSelectionStepsThroughListAndClosesOnNavigation() async throws {
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
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, session) in ["newest", "middle", "oldest"].enumerated() {
            try state.readStore.putEvent(tool: "codex", srcKey: session, sessionID: session,
                                         ts: now - Int64(index) * 60_000, input: 10)
        }
        let loaded = expectation(description: "Sessions loaded")
        let subscription = state.$updatedAt.dropFirst().sink { _ in
            if state.sessionRows.count == 3 { loaded.fulfill() }
        }
        state.selection = .usage
        state.refreshVisibleData()
        await fulfillment(of: [loaded], timeout: 3)
        subscription.cancel()

        // 没有选中会话时不进入详情
        state.showSessionDetail()
        XCTAssertNil(state.detail)

        state.selectedSessionID = "codex|middle"
        state.showSessionDetail()
        XCTAssertEqual(state.detail, .session)
        XCTAssertTrue(state.canStepSession(by: -1))
        state.stepSession(by: -1)
        XCTAssertEqual(state.selectedSessionID, "codex|newest")
        XCTAssertFalse(state.canStepSession(by: -1))
        state.stepSession(by: -1)                       // 到头不越界
        XCTAssertEqual(state.selectedSessionID, "codex|newest")
        state.stepSession(by: 2)
        XCTAssertEqual(state.selectedSessionID, "codex|oldest")
        XCTAssertFalse(state.canStepSession(by: 1))

        // 切到别的入口时离开详情；显式返回同理
        state.selection = .reports
        XCTAssertNil(state.detail)
        state.showActivityDetail()
        XCTAssertEqual(state.detail, .activity)
        state.closeDetail()
        XCTAssertNil(state.detail)
    }
}
