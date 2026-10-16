import XCTest
@testable import TokenTrackerApp
import TokenTrackerCore

final class NotchHUDTests: XCTestCase {
    func testNotchPlacementUsesPointsAndNonzeroDisplayOrigins() throws {
        for origin in [CGPoint.zero, CGPoint(x: -1470, y: 400), CGPoint(x: 1900, y: -1000)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1470, height: 956))
            let left = CGRect(x: origin.x, y: origin.y + 924, width: 645.5, height: 32)
            let frame = try XCTUnwrap(NotchHUDLayout.stripFrame(leftArea: left, screen: screen,
                topInset: 32, builtIn: true, count: 2))
            XCTAssertEqual(frame.width, 58)
            XCTAssertEqual(left.maxX - frame.maxX, 8)
            XCTAssertEqual(frame.midY, left.midY)
            XCTAssertFalse(NotchHUDLayout.needsPlacement(current: frame.offsetBy(dx: -0.5, dy: 0), target: frame))
            XCTAssertTrue(NotchHUDLayout.needsPlacement(current: frame.offsetBy(dx: 20, dy: 0), target: frame))
            XCTAssertTrue(left.contains(frame))
            // 1x/2x scaling must not change the point-space layout.
            for scale in [1.0, 2.0] {
                XCTAssertEqual((frame.width * scale) / scale, 58)
            }
            let card = NotchHUDLayout.cardFrame(strip: frame, screen: screen,
                                               size: CGSize(width: 320, height: 380))
            XCTAssertTrue(screen.contains(card))
            XCTAssertLessThan(card.maxY, frame.minY)
        }
    }

    func testNoAnchorForExternalNonNotchedOrInsufficientScreens() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let left = CGRect(x: 0, y: 924, width: 645, height: 32)
        XCTAssertNil(NotchHUDLayout.stripFrame(leftArea: nil, screen: screen, topInset: 0, builtIn: true, count: 2))
        XCTAssertNil(NotchHUDLayout.stripFrame(leftArea: left, screen: screen, topInset: 32, builtIn: false, count: 2))
        XCTAssertNil(NotchHUDLayout.stripFrame(leftArea: left, screen: screen, topInset: 32, builtIn: true, count: 40))
        XCTAssertNil(NotchHUDLayout.stripFrame(leftArea: left, screen: screen, topInset: 32, builtIn: true, count: 0))
    }

    func testFullScreenCoordinatesAndVisibilityTransitions() {
        let external = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let converted = NotchHUDLayout.windowServerFrame(external, primaryTop: 956)
        XCTAssertEqual(converted, CGRect(x: -1920, y: -24, width: 1920, height: 1080))
        XCTAssertTrue(NotchHUDLayout.coversDisplay(window: converted, screen: converted))
        XCTAssertFalse(NotchHUDLayout.coversDisplay(window: converted.insetBy(dx: 0, dy: 16), screen: converted))
        for enabled in [true, false] {
            for anchored in [true, false] {
                for active in [true, false] {
                    for full in [true, false] {
                        XCTAssertEqual(NotchHUDVisibility.shouldShow(enabled: enabled, hasAnchor: anchored,
                            sessionActive: active, fullScreen: full), enabled && anchored && active && !full)
                    }
                }
            }
        }
    }

    @MainActor
    func testPreferencesAreAppOnlyPersistAndKeepOneProvider() {
        let suite = "tt.notch.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = NotchHUDPreferences(defaults: defaults)
        XCTAssertFalse(prefs.enabled)
        XCTAssertEqual(prefs.quotaDisplay, .remaining)
        XCTAssertEqual(prefs.providers, ["codex", "claude"])
        prefs.enabled = true
        prefs.quotaDisplay = .remaining
        prefs.setProvider("codex", visible: false)
        prefs.setProvider("claude", visible: false)
        prefs.setProvider("kimi", visible: true)
        prefs.setProvider("kimi", visible: true)
        let restored = NotchHUDPreferences(defaults: defaults)
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.quotaDisplay, .remaining)
        XCTAssertEqual(restored.providers, ["claude", "kimi"])
        XCTAssertNil(defaults.object(forKey: "menubar_ring"))
    }

    func testOutsideClicksUseTheEventAndIgnoreQueuedClicksBeforeOpening() {
        let strip = CGRect(x: 579, y: 925, width: 58, height: 30)
        let card = CGRect(x: 317, y: 539, width: 320, height: 380)
        func dismiss(_ point: CGPoint, timestamp: TimeInterval = 11) -> Bool {
            NotchHUDInteraction.shouldDismissClick(point: point, timestamp: timestamp,
                                                   openedAt: 10, strip: strip, card: card)
        }
        XCTAssertFalse(dismiss(CGPoint(x: 1000, y: 100), timestamp: 9))
        XCTAssertFalse(dismiss(CGPoint(x: 594, y: 940)))
        XCTAssertFalse(dismiss(CGPoint(x: 623, y: 940)))
        XCTAssertFalse(dismiss(CGPoint(x: 400, y: 700)))
        XCTAssertTrue(dismiss(CGPoint(x: 1000, y: 100)))
    }

    func testQuotaAcceptsOnlyOfficialFinitePercentages() {
        let previous = L10n.language
        defer { L10n.setLanguage(previous) }
        L10n.setLanguage("zh-Hans")
        func quota(_ pct: Double?, source: String = "official", stale: Bool = false) -> NotchHUDQuota {
            NotchHUDQuota(provider: "codex", entry: MenuBarQuotaEntry(id: "codex", name: "Codex", windows: [
                MenuBarQuotaWindow(pct: pct, source: source, stale: stale, label: "5h")]))
        }
        XCTAssertNil(quota(nil).pct)
        XCTAssertEqual(quota(nil).value, "暂无数据")
        XCTAssertEqual(quota(0).value, "0%")
        XCTAssertNil(quota(125).pct)
        XCTAssertNil(quota(-10).pct)
        XCTAssertNil(quota(80, source: "local").pct)
        XCTAssertEqual(quota(80, source: "local").value, "暂无数据")
        XCTAssertTrue(quota(80, stale: true).window!.stale)
        XCTAssertEqual(quota(80, stale: true).value, "~80%")
        XCTAssertNil(quota(.nan).pct)
    }

    func testRemainingQuotaUsesOfficialUsedPercentAndKeepsUrgencyDirection() {
        let previous = L10n.language
        defer { L10n.setLanguage(previous) }
        L10n.setLanguage("zh-Hans")
        let entry = MenuBarQuotaEntry(id: "codex", name: "Codex", windows: [
            MenuBarQuotaWindow(pct: 88, source: "official", stale: false, label: "5h"),
            MenuBarQuotaWindow(pct: 14, source: "official", stale: false, label: "7d"),
            MenuBarQuotaWindow(pct: 99, source: "local", stale: false, label: "month")])
        let used = NotchHUDQuota(provider: "codex", entry: entry)
        let left = NotchHUDQuota(provider: "codex", entry: entry, display: .remaining)
        XCTAssertEqual(used.summary, "已用 88%")
        XCTAssertEqual(left.summary, "剩余 12%")
        XCTAssertEqual(left.fraction, 0.12, accuracy: 0.0001)
        XCTAssertEqual(left.role, used.role, "Low remaining quota must retain the warning color")
        XCTAssertEqual(left.window?.label, "5h", "A local estimate cannot win window selection")
        XCTAssertTrue(left.windowSummary.contains("5h"))
    }

    func testTodayUsageKeepsHourlyGapsAndUnallocatedHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: path)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15))!
        let day = Calendar.current.startOfDay(for: now)
        func ms(_ hours: Double) -> Int64 { Int64(day.addingTimeInterval(hours * 3600).timeIntervalSince1970 * 1000) }
        try store.putEvent(tool: "codex", srcKey: "exact", ts: ms(10.5), input: 100)
        try store.putEvent(tool: "codex", srcKey: "same-hour", ts: ms(11.5), input: 200,
                           timeQuality: "observed", intervalStart: ms(11.1))
        try store.putEvent(tool: "codex", srcKey: "cross-hour", ts: ms(13.5), input: 300,
                           timeQuality: "observed", intervalStart: ms(12.5))
        try store.putEvent(tool: "codex", srcKey: "history", ts: ms(0), input: 400, timeQuality: "unallocated")
        try store.putEvent(tool: "claude", srcKey: "other", ts: ms(10.5), input: 900)
        let usage = try NotchHUDUsage.load(path: path, provider: "codex", now: now)
        XCTAssertEqual(usage.tokens, 600)
        XCTAssertEqual(usage.estimatedTokens, 500)
        XCTAssertEqual(usage.excludedFromHours, 300)
        XCTAssertEqual(usage.unallocatedTokens, 400)
        XCTAssertEqual(usage.hours.map(\.tokens), [100, 200])
        XCTAssertNil(try NotchHUDUsage.load(path: path, provider: "missing", now: now).tokens)
        XCTAssertEqual(try NotchHUDUsage.load(path: path, provider: "missing", now: now).hours, [])
    }

    @MainActor
    func testCloseReleasesRefreshAndDiscardsLateResult() async throws {
        let started = expectation(description: "query started")
        let loader = SuspendedHUDLoader(started: started)
        let model = NotchHUDDetailModel { try await loader.load($0) }
        let request = try XCTUnwrap(model.open("codex"))
        await fulfillment(of: [started], timeout: 2)
        model.close()
        XCTAssertNil(model.refresh())
        await loader.finish("codex", tokens: 10)
        await request.value
        XCTAssertNil(model.provider)
        XCTAssertNil(model.usage)
        XCTAssertFalse(model.failed)
        let count = await loader.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSwitchRejectsPreviousToolAndQueryFailureIsUnavailable() async throws {
        let started = expectation(description: "both queries started")
        started.expectedFulfillmentCount = 2
        let loader = SuspendedHUDLoader(started: started)
        let model = NotchHUDDetailModel { try await loader.load($0) }
        let first = try XCTUnwrap(model.open("codex"))
        // Ensure the first task begins before switching; no fixed sleeps.
        let deadline = Date().addingTimeInterval(2)
        while await loader.count == 0, Date() < deadline { await Task.yield() }
        let second = try XCTUnwrap(model.open("claude"))
        await fulfillment(of: [started], timeout: 2)
        await loader.finish("claude", tokens: 20)
        await second.value
        await loader.finish("codex", tokens: 10)
        await first.value
        XCTAssertEqual(model.provider, "claude")
        XCTAssertEqual(model.usage?.tokens, 20)
        let failure = NotchHUDDetailModel { _ in throw CocoaError(.fileReadCorruptFile) }
        await failure.open("codex")?.value
        XCTAssertTrue(failure.failed)
        XCTAssertNil(failure.usage)
    }
}

private actor SuspendedHUDLoader {
    let started: XCTestExpectation
    var count = 0
    var continuations: [String: CheckedContinuation<NotchHUDUsage, Error>] = [:]
    init(started: XCTestExpectation) { self.started = started }
    func load(_ provider: String) async throws -> NotchHUDUsage {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[provider] = continuation
            started.fulfill()
        }
    }
    func finish(_ provider: String, tokens: Int64) {
        continuations.removeValue(forKey: provider)?.resume(returning: NotchHUDUsage(
            tokens: tokens, estimatedTokens: 0, excludedFromHours: 0, unallocatedTokens: 0, hours: []))
    }
}
