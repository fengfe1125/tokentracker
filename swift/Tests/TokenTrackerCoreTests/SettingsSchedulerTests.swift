//
//  SettingsSchedulerTests.swift
//  TokenTrackerCoreTests
//
//  移植 test_server.py 的 ScanServiceTest + 设置校验（_SETTINGS_SCHEMA）。
//

import XCTest
@testable import TokenTrackerCore

/// @Sendable 闭包里的可变状态盒（测试单线程/锁保护下使用）。
// 同步执行的线程（对齐 Python InlineThread）
private final class InlineThread: ScanThreadHandle {
    private let block: () -> Void
    init(block: @escaping () -> Void) { self.block = block }
    func start() { block() }
    func join(timeout: TimeInterval) {}
    var isAlive: Bool { false }
    var isCurrentThread: Bool { true }
}

final class ScanSchedulerPortTests: XCTestCase {
    /// test_startup_interval_and_stop_with_injected_wait
    func testStartupIntervalAndStopWithInjectedWait() {
        let now = StateBox(100.0)
        let calls = StateBox<[(Double, [String]?, Bool)]>([])
        let scheduler = ScanScheduler(
            scan: { tools, full in
                calls.value.append((now.value, tools, full))
                return ([:], 0)
            },
            interval: 60,
            clock: { now.value },
            wait: { timeout in
                XCTAssertEqual(timeout, 60)
                now.value += timeout
                return calls.value.count >= 3   // 三次后通知停等
            },
            threadFactory: { InlineThread(block: $0) })
        scheduler.startAuto()
        XCTAssertEqual(calls.value.map { $0.0 }, [100, 160, 220])
        XCTAssertEqual(calls.value.count, 3)
        let status = scheduler.snapshot()
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.last?.startedAt, 220)
        XCTAssertEqual(status.last?.finishedAt, 220)
        XCTAssertEqual(status.last?.source, "automatic")
        scheduler.stop()
        XCTAssertFalse(scheduler.request())
    }

    /// test_manual_and_automatic_share_lock
    func testManualAndAutomaticShareLock() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let scheduler = ScanScheduler(scan: { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return ([:], 0)
        })
        XCTAssertTrue(scheduler.request(source: "manual"))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(scheduler.request(source: "automatic"))
        XCTAssertTrue(scheduler.snapshot().running)
        release.signal()
        scheduler.stop()
        let deadline = Date() + 2
        while scheduler.snapshot().running && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(scheduler.snapshot().running)
        XCTAssertTrue(scheduler.snapshot().last?.done ?? false)
    }

    /// test_failure_records_timestamps_and_releases_lock
    func testFailureRecordsTimestampsAndReleasesLock() {
        struct Synthetic: Error {}
        let times = StateBox([10.0, 11.0, 12.0, 13.0])
        let callCount = StateBox(0)
        let scheduler = ScanScheduler(
            scan: { _, _ in
                callCount.value += 1
                if callCount.value == 1 { throw Synthetic() }
                return (["claude": ScanOutcome(
                    added: 1, activityAdded: 2, activityUpdated: 3)], 2)
            },
            clock: {
                defer { if !times.value.isEmpty { times.value.removeFirst() } }
                return times.value.first ?? 99
            },
            threadFactory: { InlineThread(block: $0) })
        XCTAssertTrue(scheduler.request(tools: ["claude"], full: true))
        var last = scheduler.snapshot().last
        XCTAssertEqual(last?.startedAt, 10)
        XCTAssertEqual(last?.finishedAt, 11)
        XCTAssertNotNil(last?.error)
        XCTAssertTrue(scheduler.request())
        last = scheduler.snapshot().last
        XCTAssertNil(last?.error)
        XCTAssertEqual(last?.repriced, 2)
        XCTAssertEqual(last?.added, 1)
        XCTAssertEqual(last?.activityAdded, 2)
        XCTAssertEqual(last?.activityUpdated, 3)
        scheduler.stop()
    }

    /// test_stop_wakes_waiting_scheduler_without_a_second_scan（对齐：stop 后不再扫）
    func testStopWakesWaitingSchedulerWithoutSecondScan() {
        let scanCount = StateBox(0)
        let scheduler = ScanScheduler(
            scan: { _, _ in scanCount.value += 1; return ([:], 0) },
            interval: 0.05)
        scheduler.startAuto()
        Thread.sleep(forTimeInterval: 0.02)
        scheduler.stop()
        let countAtStop = scanCount.value
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(scanCount.value, countAtStop)
    }
}

final class SettingsStorePortTests: XCTestCase {
    private var tmp: TempDir!
    private var storePath: String!

    override func setUp() async throws {
        tmp = try TempDir()
        storePath = tmp.path("settings.json")
    }

    override func tearDown() async throws {
        tmp = nil; storePath = nil
    }

    /// test_settings_get_returns_defaults_and_providers
    func testDefaultsWhenMissing() {
        let store = SettingsStore(path: storePath)
        XCTAssertEqual(store.effectiveString("menubar_provider"), "claude")
        XCTAssertTrue(store.effectiveBool("menubar_ring"))
        XCTAssertFalse(store.effectiveBool("launch_at_login"))
        XCTAssertEqual(store.effectiveString("terminal_app"), "auto")
        XCTAssertFalse(store.effectiveBool("menubar_compact"))
        XCTAssertFalse(store.effectiveBool("unit_yi"))
        XCTAssertTrue(store.effectiveBool("price_sync_enabled"))
    }

    /// test_settings_post_validates_and_merges
    func testValidatesAndMerges() {
        let store = SettingsStore(path: storePath)
        XCTAssertTrue(store.set(key: "menubar_provider", value: "kimi"))
        XCTAssertEqual(store.effectiveString("menubar_provider"), "kimi")
        XCTAssertTrue(store.set(key: "menubar_compact", value: true))
        XCTAssertTrue(store.effectiveBool("menubar_compact"))
        // 非法值一律拒绝且不落盘
        XCTAssertFalse(store.set(key: "menubar_provider", value: "INVALID ID!"))
        XCTAssertFalse(store.set(key: "menubar_compact", value: "yes"))   // 非 bool
        XCTAssertFalse(store.set(key: "price_sync_enabled", value: "yes"))
        XCTAssertFalse(store.set(key: "terminal_app", value: "vscode"))
        XCTAssertFalse(store.set(key: "unknown_key", value: 1))
        XCTAssertEqual(store.effectiveString("menubar_provider"), "kimi") // 未被破坏
        XCTAssertEqual(store.load()["unknown_key"] as? Int, nil)
        XCTAssertTrue(store.set(key: "price_sync_enabled", value: false))
        XCTAssertFalse(store.effectiveBool("price_sync_enabled"))
    }

    /// 原子写入：tmp 文件不残留。
    func testAtomicSaveLeavesNoTmp() {
        let store = SettingsStore(path: storePath)
        XCTAssertTrue(store.set(key: "unit_yi", value: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storePath + ".tmp"))
        XCTAssertEqual(SettingsStore(path: storePath).effectiveBool("unit_yi"), true)
    }

    /// provider id 正则：off / 小写字母数字下划线连字符 ≤24。
    func testProviderIDPattern() {
        for ok in ["off", "claude", "codex", "go", "a1_-b"] {
            XCTAssertTrue(SettingsStore.isValid(key: "menubar_provider", value: ok), ok)
        }
        for bad in ["", "Off", " claude", "x y", String(repeating: "a", count: 25), "🔥"] {
            XCTAssertFalse(SettingsStore.isValid(key: "menubar_provider", value: bad), bad)
        }
    }
}
