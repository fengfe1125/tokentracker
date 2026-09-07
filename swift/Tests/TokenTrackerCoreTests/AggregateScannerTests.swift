//
//  AggregateScannerTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_aggregate_scanners.py：合成 provider 数据库 + 受控时钟
//  下的快照扫描语义（opencode / hermes）。
//

import XCTest
@testable import TokenTrackerCore

final class AggregateScannerPortTests: XCTestCase {
    private var tmp: TempDir!
    private var store: UsageStore!
    private var paths: [String: String] = [:]
    private var startMs: Int64!   // 2026-08-27 00:00 本地

    private enum ToolUnderTest: String {
        case opencode, hermes
    }

    override func setUp() async throws {
        tmp = try TempDir()
        store = try tmp.store()
        var cal = Calendar.current
        cal.timeZone = .current
        startMs = Int64(cal.date(from: DateComponents(year: 2026, month: 8, day: 27))!
            .timeIntervalSince1970 * 1000)

        let opencodePath = tmp.path("opencode.db")
        let opencodeConn = try SQLiteConnection(path: opencodePath)
        _ = try opencodeConn.execute(
            "CREATE TABLE session (id TEXT,directory TEXT,title TEXT,model TEXT,tokens_input INT,tokens_output INT,tokens_reasoning INT,tokens_cache_read INT,tokens_cache_write INT,cost REAL,time_created INT,time_updated INT)")
        _ = try opencodeConn.execute(
            "INSERT INTO session VALUES ('s','p','title','gpt-5',1000,0,0,0,0,0,1,1)")
        try opencodeConn.commit()

        let hermesPath = tmp.path("hermes.db")
        let hermesConn = try SQLiteConnection(path: hermesPath)
        _ = try hermesConn.execute("CREATE TABLE sessions(id TEXT,display_name TEXT)")
        _ = try hermesConn.execute("INSERT INTO sessions VALUES ('s','p')")
        _ = try hermesConn.execute(
            "CREATE TABLE session_model_usage(session_id TEXT,model TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_write_tokens INT,reasoning_tokens INT,estimated_cost_usd REAL,actual_cost_usd REAL,first_seen INT,last_seen INT,api_call_count INT,billing_provider TEXT,billing_base_url TEXT,billing_mode TEXT,task TEXT)")
        _ = try hermesConn.execute(
            "INSERT INTO session_model_usage VALUES ('s','gpt-5',1000,0,0,0,0,NULL,0,1,1,1,'p','url','m','t')")
        try hermesConn.commit()
        paths = ["opencode": opencodePath, "hermes": hermesPath]
    }

    override func tearDown() async throws {
        tmp = nil; store = nil; paths = [:]
    }

    @discardableResult
    private func scanAt(_ tool: ToolUnderTest, _ ms: Int64, full: Bool = false) throws -> ScanOutcome {
        store.nowMs = { ms }
        switch tool {
        case .opencode:
            return try OpencodeScanner(dbPath: paths["opencode"]!).scan(store, .default, full: full)
        case .hermes:
            var scanner = HermesScanner(home: tmp.url.path)
            scanner.dbFilesOverride = [paths["hermes"]!]
            return try scanner.scan(store, .default, full: full)
        }
    }

    private func update(_ tool: ToolUnderTest, _ value: Int64) throws {
        let conn = try SQLiteConnection(path: paths[tool.rawValue]!)
        if tool == .opencode {
            _ = try conn.execute("UPDATE session SET tokens_input=?,time_updated=time_updated+1", [value])
        } else {
            _ = try conn.execute("UPDATE session_model_usage SET input_tokens=?,last_seen=last_seen+1", [value])
        }
        try conn.commit()
    }

    /// 对齐 test_baseline_preserved_and_only_new_delta_in_today
    func testBaselinePreservedAndOnlyNewDeltaInToday() throws {
        for tool in [ToolUnderTest.opencode, .hermes] {
            try scanAt(tool, startMs - 3_600_000)
            // 未变化的观测收窄下一次差量的区间
            try scanAt(tool, startMs + 1000)
            try update(tool, 1100)
            try scanAt(tool, startMs + 2000)
            try scanAt(tool, startMs + 3000, full: true)
            store.rangeBoundsOverride = (startMs, startMs + 86_400_000)
            let today = try store.stats(rangeKey: "day", tool: tool.rawValue)
            XCTAssertEqual(today.total.tokens, 100, tool.rawValue)
            XCTAssertEqual(today.summary.estimatedTokens, 100, tool.rawValue)
            XCTAssertEqual(today.summary.unallocatedTokens, 1000, tool.rawValue)
            XCTAssertEqual(try store.stats(rangeKey: "all", tool: tool.rawValue).total.tokens, 1100)
            let cost = try store.stats(rangeKey: "all", tool: tool.rawValue).total.cost
            if tool == .hermes {
                // hermes actual=0/est=NULL 视为未知成本 → 价格表估算
                XCTAssertGreaterThan(cost, 0)
            } else {
                // opencode 自带 0 保持 0
                XCTAssertEqual(cost, 0)
            }
            store.rangeBoundsOverride = nil
        }
    }

    /// 对齐 test_cross_month_interval_and_counter_reset
    func testCrossMonthIntervalAndCounterReset() throws {
        for tool in [ToolUnderTest.opencode, .hermes] {
            try scanAt(tool, startMs - 40 * 86_400_000)
            try update(tool, 1100)
            try scanAt(tool, startMs + 1000)
            store.rangeBoundsOverride = (startMs, startMs + 86_400_000)
            let day = try store.stats(rangeKey: "day", tool: tool.rawValue)
            XCTAssertEqual(day.total.tokens, 0, tool.rawValue)
            XCTAssertEqual(day.summary.unallocatedTokens, 1100, tool.rawValue)
            store.rangeBoundsOverride = nil
            try update(tool, 10)
            let result = try scanAt(tool, startMs + 2000)
            XCTAssertEqual(result.counterResets, 1, tool.rawValue)
            try update(tool, 30)
            try scanAt(tool, startMs + 3000)
            XCTAssertEqual(try store.stats(rangeKey: "all", tool: tool.rawValue).total.tokens,
                           1120, tool.rawValue)
        }
    }

    /// 对齐 test_adopt_legacy_baseline_without_counting_it_twice
    func testAdoptLegacyBaselineWithoutCountingTwice() throws {
        for (tool, key) in [(ToolUnderTest.opencode, "s"),
                            (ToolUnderTest.hermes, "s|gpt-5|p|url|m|t")] {
            try store.putEvent(tool: tool.rawValue, srcKey: key, sessionID: "s",
                               input: 1000, timeQuality: "unallocated")
            try scanAt(tool, startMs)
            try update(tool, 1100)
            try scanAt(tool, startMs + 1000)
            XCTAssertEqual(try store.stats(rangeKey: "all", tool: tool.rawValue).total.tokens,
                           1100, tool.rawValue)
        }
    }

    /// 对齐 test_hermes_legacy_profile_is_matched_before_root_is_scanned
    func testHermesLegacyProfileMatchedBeforeRootScanned() throws {
        let root = paths["hermes"]!
        let profile = tmp.path("profile.db")
        // 备份复制（对齐 Python src.backup(dst)）
        let src = try SQLiteConnection(path: root)
        let dst = try SQLiteConnection(path: profile)
        try src.backup(to: dst)
        try update(.hermes, 100)
        let profileConn = try SQLiteConnection(path: profile)
        _ = try profileConn.execute("UPDATE session_model_usage SET input_tokens=900")
        try profileConn.commit()
        try store.putEvent(tool: "hermes", srcKey: "s|gpt-5|p|url|m|t", sessionID: "s",
                           project: "p", model: "gpt-5", input: 900, cost: 0,
                           timeQuality: "unallocated", costSource: "legacy")

        var scanner = HermesScanner(home: tmp.url.path)
        scanner.dbFilesOverride = [root, profile]
        store.nowMs = { self.startMs }
        _ = try scanner.scan(store, .default, full: false)
        store.nowMs = { self.startMs + 1000 }
        _ = try scanner.scan(store, .default, full: false)

        XCTAssertEqual(try store.stats(rangeKey: "all", tool: "hermes").total.tokens, 1000)
        let legacy = try XCTUnwrap(store.conn.queryOne(
            "SELECT source_scope FROM usage_events WHERE src_key='s|gpt-5|p|url|m|t'"))
        XCTAssertEqual(legacy.string("source_scope"), realPath(profile))
    }

    /// 对齐 test_hermes_ambiguous_decreased_profiles_preserve_legacy_with_warning
    func testHermesAmbiguousDecreasedProfilesPreserveLegacy() throws {
        let root = paths["hermes"]!
        let profile = tmp.path("profile.db")
        let src = try SQLiteConnection(path: root)
        let dst = try SQLiteConnection(path: profile)
        try src.backup(to: dst)
        try update(.hermes, 100)
        let profileConn = try SQLiteConnection(path: profile)
        _ = try profileConn.execute("UPDATE session_model_usage SET input_tokens=200")
        try profileConn.commit()
        try store.putEvent(tool: "hermes", srcKey: "s|gpt-5|p|url|m|t", sessionID: "s",
                           project: "p", model: "gpt-5", input: 900, cost: 0,
                           timeQuality: "unallocated")

        var scanner = HermesScanner(home: tmp.url.path)
        scanner.dbFilesOverride = [root, profile]
        store.nowMs = { self.startMs }
        let result = try scanner.scan(store, .default, full: false)
        XCTAssertNotNil(result.warning)
        let legacy = try XCTUnwrap(store.conn.queryOne(
            "SELECT source_scope,input,time_quality FROM usage_events WHERE src_key='s|gpt-5|p|url|m|t'"))
        XCTAssertEqual(legacy.string("source_scope"), "")
        XCTAssertEqual(legacy.int("input"), 900)
        XCTAssertEqual(legacy.string("time_quality"), "unallocated")
    }

    // ------------------------------------------------ put_snapshot 语义 ----

    private let snapshotPrices = PriceTable(fallback: nil, models: [
        "m": PriceRate(input: 1, output: 0),
    ])

    @discardableResult
    private func snapshot(_ store: UsageStore, input: Int64, cost: Double?, at: Int64,
                          source: String = "native") throws
        -> (added: Int, counterResets: Int) {
        try store.putSnapshot(tool: "test", sourceScope: "fixture.db", identity: "s",
                              sessionID: "s", project: "p", model: "m", input: input,
                              nativeCost: cost, costSource: source,
                              prices: snapshotPrices, observedAt: at)
    }

    /// test_native_cost_arrival_creates_unallocated_adjustment
    func testNativeCostArrivalCreatesUnallocatedAdjustment() throws {
        try snapshot(store, input: 1_000_000, cost: nil, at: startMs - 1000)
        try snapshot(store, input: 1_100_000, cost: 2, at: startMs + 1000)
        try snapshot(store, input: 1_200_000, cost: 2.2, at: startMs + 2000)
        XCTAssertEqual(try store.stats().total.cost, 2.2, accuracy: 1e-9)
        let rows = try store.conn.query(
            "SELECT * FROM usage_events WHERE cost_source='native_adjustment'")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].int("input"), 0)
        XCTAssertEqual(rows[0].string("time_quality"), "unallocated")
        XCTAssertEqual(rows[0].double("cost"), 0.9, accuracy: 1e-9)
    }

    /// test_native_source_switch_reconciles_history_without_negative_today
    func testNativeSourceSwitchReconcilesHistory() throws {
        try snapshot(store, input: 1_000_000, cost: 3, at: startMs, source: "provider_estimate")
        try snapshot(store, input: 1_100_000, cost: 2, at: startMs + 1000)
        XCTAssertEqual(try store.stats().total.cost, 2, accuracy: 1e-9)
        let adjustment = try XCTUnwrap(store.conn.queryOne(
            "SELECT cost,time_quality FROM usage_events WHERE cost_source='native_adjustment'"))
        XCTAssertEqual(adjustment.double("cost"), -1.1, accuracy: 1e-9)
        XCTAssertEqual(adjustment.string("time_quality"), "unallocated")
        store.rangeBoundsOverride = (startMs, startMs + 86_400_000)
        XCTAssertEqual(try store.stats(rangeKey: "day").total.cost, 0.1, accuracy: 1e-9)
    }

    /// test_old_snapshot_without_accounted_cost_uses_existing_ledger
    func testOldSnapshotWithoutAccountedCostUsesExistingLedger() throws {
        try snapshot(store, input: 1_000_000, cost: nil, at: startMs)
        let row = try XCTUnwrap(store.conn.queryOne(
            "SELECT values_json FROM aggregate_snapshots"))
        var old = try JSONSerialization.jsonObject(with: Data(row.string("values_json").utf8))
            as! [String: Any]
        old.removeValue(forKey: "accounted_cost")
        old.removeValue(forKey: "native_source")
        _ = try store.conn.execute("UPDATE aggregate_snapshots SET values_json=?", [
            String(data: JSONSerialization.data(withJSONObject: old), encoding: .utf8)!,
        ])
        try snapshot(store, input: 1_100_000, cost: 2, at: startMs + 1000)
        XCTAssertEqual(try store.stats().total.cost, 2, accuracy: 1e-9)
    }

    /// test_native_counter_reset_starts_new_cost_baseline
    func testNativeCounterResetStartsNewCostBaseline() throws {
        try snapshot(store, input: 1_000_000, cost: 2, at: startMs)
        try snapshot(store, input: 10, cost: 0.01, at: startMs + 1000)
        try snapshot(store, input: 30, cost: 0.03, at: startMs + 2000)
        XCTAssertEqual(try store.stats().total.tokens, 1_000_020)
        XCTAssertEqual(try store.stats().total.cost, 2.02, accuracy: 1e-9)
    }

    /// test_native_arrival_accounts_for_prices_filled_between_scans
    func testNativeArrivalAccountsForPricesFilledBetweenScans() throws {
        try store.putSnapshot(tool: "test", sourceScope: "fixture.db", identity: "s",
                              sessionID: "s", project: "p", model: "m", input: 1_000_000,
                              prices: PriceTable(fallback: nil, models: [:]),
                              observedAt: startMs)
        _ = try store.reprice(PriceTable(fallback: nil, models: ["m": PriceRate(input: 1)]))
        try snapshot(store, input: 1_100_000, cost: 2, at: startMs + 1000)
        XCTAssertEqual(try store.stats().total.cost, 2, accuracy: 1e-9)
    }

    /// test_concurrent_connections_serialize_snapshot_read_and_write（简化版：
    /// 两个连接并发写不同 identity，BEGIN IMMEDIATE + busy_timeout 保证不丢数据）
    func testConcurrentConnectionsSerializeSnapshots() throws {
        let path = tmp.path("concurrent.db")
        let storeA = try UsageStore(path: path)
        try snapshot(storeA, input: 100, cost: 0, at: 1)
        try storeA.conn.commit()

        let prices = snapshotPrices
        let group = DispatchGroup()
        let errorsLock = NSLock()
        nonisolated(unsafe) var errors: [String] = []
        for worker in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let workerStore = try UsageStore(path: path)
                    for n in 0..<25 {
                        try workerStore.putSnapshot(tool: "test", sourceScope: "fixture.db",
                                                    identity: "w\(worker)-\(n)",
                                                    sessionID: "s", project: "p", model: "m",
                                                    input: Int64(10 * (n + 1)), nativeCost: 0,
                                                    prices: prices, observedAt: Int64(n + 2))
                        try workerStore.conn.commit()
                    }
                } catch {
                    errorsLock.lock(); errors.append(String(describing: error)); errorsLock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(errors, [])
        let check = try UsageStore(path: path)
        XCTAssertEqual(try check.stats(rangeKey: "all", tool: "test").total.events, 51)
    }

    // ------------------------------------------------ hermes 成本优先级 ----

    private func insertHermesUsage(sessionID: String, model: String,
                                   actual: Double, estimated: Double?) throws {
        let conn = try SQLiteConnection(path: paths["hermes"]!)
        _ = try conn.execute(
            "INSERT INTO session_model_usage VALUES (?,?,1000,0,0,0,0,?,?,1,1,1,'p','url','m','t')",
            [sessionID, model, estimated as Any, actual])
        try conn.commit()
    }

    /// test_hermes_unknown_cost_falls_back_to_price_estimate
    func testHermesUnknownCostFallsBackToPriceEstimate() throws {
        try insertHermesUsage(sessionID: "u", model: "gpt-5", actual: 0, estimated: 0)
        try scanAt(.hermes, startMs)
        let total = try store.stats(rangeKey: "all", tool: "hermes").total
        XCTAssertGreaterThan(total.cost, 0)
        let row = try XCTUnwrap(store.conn.queryOne(
            "SELECT cost_source FROM usage_events WHERE tool='hermes' AND session_id='u'"))
        XCTAssertEqual(row.string("cost_source"), "estimate")
    }

    /// test_hermes_provider_estimate_preferred_over_zero_actual
    func testHermesProviderEstimatePreferredOverZeroActual() throws {
        try insertHermesUsage(sessionID: "e", model: "gpt-5", actual: 0, estimated: 0.5)
        try scanAt(.hermes, startMs)
        let cost = try store.conn.queryOne(
            "SELECT SUM(cost) AS c FROM usage_events WHERE tool='hermes' AND session_id='e'")?
            .double("c") ?? 0
        XCTAssertEqual(cost, 0.5, accuracy: 1e-9)
    }

    /// test_hermes_actual_cost_wins_when_positive
    func testHermesActualCostWinsWhenPositive() throws {
        try insertHermesUsage(sessionID: "a", model: "gpt-5", actual: 1.5, estimated: 0.9)
        try scanAt(.hermes, startMs)
        let cost = try store.conn.queryOne(
            "SELECT SUM(cost) AS c FROM usage_events WHERE tool='hermes' AND session_id='a'")?
            .double("c") ?? 0
        XCTAssertEqual(cost, 1.5, accuracy: 1e-9)
    }
}
