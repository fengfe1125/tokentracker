//
//  StoreMigrationTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_db_migrations.py：临时 SQLite fixture、token 记账一致性、
//  旧库升级可回滚。
//

import XCTest
@testable import TokenTrackerCore

final class StoreMigrationTests: XCTestCase {
    private let oldSchema = """
    CREATE TABLE usage_events (
     id INTEGER PRIMARY KEY, tool TEXT NOT NULL, session_id TEXT DEFAULT '',
     project TEXT DEFAULT '', ts INTEGER NOT NULL, model TEXT DEFAULT '',
     input INTEGER DEFAULT 0, output INTEGER DEFAULT 0, cache_read INTEGER DEFAULT 0,
     cache_write INTEGER DEFAULT 0, cost REAL, src_key TEXT NOT NULL, UNIQUE(tool,src_key));
    CREATE TABLE scan_state(tool TEXT PRIMARY KEY, cursor TEXT);
    """

    /// 对齐 test_four_classes_sum_inside_each_row：四种 token 在每行内部互斥相加。
    func testFourClassesSumInsideEachRow() throws {
        let tmp = try TempDir()
        let store = try tmp.store()
        try store.putEvent(tool: "t", srcKey: "a", sessionID: "s",
                           input: 100, output: 20, cacheRead: 30, cacheWrite: 10)
        try store.putEvent(tool: "t", srcKey: "b", sessionID: "s",
                           input: 100, output: 20, cacheRead: 50, cacheWrite: 10)
        XCTAssertEqual(try store.windowUsage(startMs: 0, includeCache: true), 340)
        XCTAssertEqual(try store.quotaUsage(rangeKey: "all", includeCache: true).tokens, 340)
        XCTAssertEqual(try store.stats().total.tokens, 340)
        XCTAssertEqual(try store.models().first?.stats.tokens, 340)
        XCTAssertEqual(try store.sessions().first?.stats.tokens, 340)
        XCTAssertEqual(try store.sessionDetail(tool: "t", sessionID: "s").total.tokens, 340)
        XCTAssertEqual(try store.daily().first?.stats.tokens, 340)
    }

    func testCacheHitRateUsesInputSideOnly() throws {
        var stats = UsageStore.ToolStats()
        stats.input = 100
        stats.output = 900
        stats.cacheRead = 300
        stats.cacheWrite = 100
        XCTAssertEqual(try XCTUnwrap(stats.cacheHitRate), 60, accuracy: 1e-9)
    }

    /// 概览的“输入总量”必须包含三类输入侧 token。完全命中缓存时，
    /// 非缓存 input 可以为 0，但用户实际送入模型的上下文不能显示成 0。
    func testInputSideTokensIncludesCachedInputWhenFreshInputIsZero() {
        var stats = UsageStore.ToolStats()
        stats.input = 0
        stats.output = 50
        stats.cacheRead = 9_000
        stats.cacheWrite = 1_000
        XCTAssertEqual(stats.inputSideTokens, 10_000)
    }

    private func makeOldDatabase(at path: String, fail: Bool = false) throws {
        let conn = try SQLiteConnection(path: path)
        for statement in oldSchema.split(separator: ";") {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { _ = try conn.execute(trimmed) }
        }
        _ = try conn.execute(
            "INSERT INTO usage_events(tool,session_id,ts,model,input,output,cache_read,cost,src_key) VALUES ('opencode','s',1,'m',1000,0,0,2,'s')")
        _ = try conn.execute(
            "INSERT INTO usage_events(tool,session_id,ts,model,input,output,cache_read,cost,src_key) VALUES ('codex','c',1,'gpt-5',1000000,0,800000,1.35,'legacy|x|1')")
        if fail {
            _ = try conn.execute(
                "CREATE TRIGGER reject_upgrade BEFORE UPDATE ON usage_events BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        }
        try conn.commit()
    }

    /// 对齐 test_legacy_upgrade_backed_up_and_repeatable。
    func testLegacyUpgradeBackedUpAndRepeatable() throws {
        let tmp = try TempDir()
        let path = tmp.path("usage.db")
        try makeOldDatabase(at: path)

        let store = try UsageStore(path: path)
        XCTAssertGreaterThan(try store.conn.scalarInt("PRAGMA user_version"), 0)

        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.hasPrefix("usage.db.v0.backup-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try SQLiteConnection(path: tmp.path(backups[0]))
        XCTAssertEqual(try backup.scalarInt("SELECT SUM(input) FROM usage_events"), 1_001_000)

        XCTAssertEqual(try store.stats(rangeKey: "all", tool: "opencode").total.tokens, 1000)
        XCTAssertEqual(try store.stats(rangeKey: "day", tool: "opencode").total.tokens, 0)
        XCTAssertEqual(try store.stats(rangeKey: "day", tool: "opencode").summary.unallocatedTokens, 1000)

        let codex = try XCTUnwrap(store.conn.queryOne(
            "SELECT * FROM usage_events WHERE tool='codex'"))
        XCTAssertEqual(codex.int("input"), 200_000)
        XCTAssertEqual(codex.double("cost"), 1.35, accuracy: 1e-9)
        XCTAssertEqual(codex.string("cost_source"), "legacy_unversioned")
        XCTAssertEqual(codex.string("provider"), "openai")
        XCTAssertNil(codex.stringOrNil("price_version_id"))
        XCTAssertEqual(codex.string("time_quality"), "unallocated")

        // 重复打开不重复迁移/备份
        let again = try UsageStore(path: path)
        XCTAssertEqual(try again.stats().total.tokens, 1_001_000)
        let backups2 = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.hasPrefix("usage.db.v0.backup-") }
        XCTAssertEqual(backups2.count, 1)
    }

    /// 更新版本写入的库：打开时报可识别的错误，且不改动库内容、不生成备份。
    func testNewerSchemaIsRejectedWithTypedErrorAndLeftUntouched() throws {
        let tmp = try TempDir()
        let path = tmp.path("usage.db")
        let future = Int(UsageStore.schemaVersion) + 1
        _ = try UsageStore(path: path).conn.execute("PRAGMA user_version=\(future)")
        XCTAssertThrowsError(try UsageStore(path: path)) { error in
            XCTAssertEqual(error as? UsageStoreError,
                           .newerSchema(found: future, supported: Int(UsageStore.schemaVersion)))
        }
        XCTAssertEqual(try SQLiteConnection(path: path, readOnly: true).scalarInt("PRAGMA user_version"), Int64(future))
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.contains(".backup-") }
        XCTAssertEqual(backups, [])
    }

    /// 库文件含项目路径与会话标题：新建与已有的库都只留本人读写。
    func testDatabaseFileIsOwnerOnly() throws {
        let tmp = try TempDir()
        let fresh = tmp.path("nested", "usage.db")
        _ = try UsageStore(path: fresh)
        func mode(_ path: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode(fresh) & 0o077, 0)
        XCTAssertEqual(try mode(tmp.path("nested")) & 0o077, 0, "新建的数据目录也只给本人")

        let existing = tmp.path("old.db")
        _ = try UsageStore(path: existing)
        chmod(existing, 0o644)
        let oldBackup = tmp.path("old.db.v7.backup-1.db")
        FileManager.default.createFile(atPath: oldBackup, contents: Data(), attributes: [.posixPermissions: 0o644])
        let unrelated = tmp.path("notes.txt")
        FileManager.default.createFile(atPath: unrelated, contents: Data(), attributes: [.posixPermissions: 0o644])
        _ = try UsageStore(path: existing)
        XCTAssertEqual(try mode(existing), 0o600)
        XCTAssertEqual(try mode(oldBackup), 0o600, "旧版本留下的迁移备份一并收紧")
        XCTAssertEqual(try mode(unrelated), 0o644, "不动同目录的其他文件")
    }

    /// 对齐 test_current_version_gains_call_index_without_backup。
    func testCurrentVersionGainsCallIndexWithoutBackup() throws {
        let tmp = try TempDir()
        let path = tmp.path("usage.db")
        _ = try UsageStore(path: path).conn.execute("DROP INDEX idx_activity_call")
        let store = try UsageStore(path: path)
        XCTAssertEqual(try store.conn.scalarInt("PRAGMA user_version"), Int64(UsageStore.schemaVersion))
        let plan = try store.conn.query(
            "EXPLAIN QUERY PLAN SELECT id FROM agent_activity_events "
                + "WHERE agent='codex' AND call_id='c' ORDER BY id DESC LIMIT 1")
            .map { $0.string("detail") }.joined(separator: " ")
        XCTAssertTrue(plan.contains("idx_activity_call"), plan)
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.contains(".backup-") }
        XCTAssertEqual(backups, [])
    }

    /// 对齐 test_upgrade_keeps_only_newest_migration_backups。
    func testUpgradeKeepsOnlyNewestMigrationBackups() throws {
        let tmp = try TempDir()
        let path = tmp.path("usage.db")
        try makeOldDatabase(at: path)
        let stale = ["usage.db.v5.backup-3.db", "usage.db.v4.backup-2.db", "usage.db.v3.backup-1.db"]
        for (age, name) in stale.enumerated() {
            FileManager.default.createFile(atPath: tmp.path(name), contents: Data())
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 - Double(age + 1))],
                ofItemAtPath: tmp.path(name))
        }
        let manual = tmp.path("usage.db.bak-manual")
        FileManager.default.createFile(atPath: manual, contents: Data())
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: manual)

        _ = try UsageStore(path: path)
        let kept = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.hasPrefix("usage.db.v") && $0.contains(".backup-") }
        XCTAssertEqual(kept.count, UsageStore.migrationBackupsKept)
        XCTAssertTrue(kept.contains("usage.db.v5.backup-3.db"))
        XCTAssertTrue(kept.contains { $0.hasPrefix("usage.db.v0.backup-") })
        for name in kept {
            let mode = (try FileManager.default.attributesOfItem(atPath: tmp.path(name))[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual((mode ?? -1) & 0o077, 0, "迁移备份同样只给本人：\(name)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual))
    }

    /// v6→v7：删除快照成本舍入噪声行，保留真实快照差量与 native 对账。
    func testV7PrunesSnapshotRoundingNoise() throws {
        let tmp = try TempDir()
        let path = tmp.path("usage.db")
        do {
            let store = try UsageStore(path: path)
            func put(_ key: String, input: Int64, cost: Double?, costSource: String, ts: Int64,
                     quality: String = "observed") throws {
                _ = try store.putEvent(tool: "opencode", srcKey: key, sessionID: "s", ts: ts,
                                       input: input, cost: cost, timeQuality: quality,
                                       intervalStart: quality == "observed" ? ts - 500 : nil,
                                       costSource: costSource, sourceKind: "aggregate_snapshot",
                                       sourceScope: "fixture.db")
            }
            try put("aggregate|d|0", input: 100, cost: 0.01, costSource: "native", ts: 1_000)
            try put("aggregate|d|1", input: 0, cost: 2e-17, costSource: "native", ts: 2_000)
            try put("aggregate|d|2", input: 0, cost: 2e-19, costSource: "native", ts: 3_000)
            try put("aggregate|d|3", input: 0, cost: 0.5, costSource: "native_adjustment", ts: 4_000,
                    quality: "unallocated")
            _ = try store.putEvent(tool: "claude", srcKey: "c", sessionID: "c", ts: 5_000, cost: 0)
            _ = try store.conn.execute("PRAGMA user_version=6")
            try store.conn.commit()
        }
        let store = try UsageStore(path: path)
        XCTAssertEqual(try store.conn.scalarInt("PRAGMA user_version"), Int64(UsageStore.schemaVersion))
        let kept = try store.conn.query("SELECT src_key FROM usage_events ORDER BY src_key")
            .map { $0.string("src_key") }
        XCTAssertEqual(kept, ["aggregate|d|0", "aggregate|d|3", "c"])
        let history = try XCTUnwrap(store.conn.queryOne(
            "SELECT original_json FROM migration_history WHERE version=7"))
        XCTAssertTrue(history.string("original_json").contains("\"rows\":2"))
        XCTAssertEqual(try store.sessions().first { $0.tool == "opencode" }?.ts, 1_000)
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.hasPrefix("usage.db.v6.backup-") }
        XCTAssertEqual(backups.count, 1)
    }

    /// v7→v8：把同一自然周在不同时区生成的重复周报合并为规范键 `week:yyyy-MM-dd`，保留最新快照。
    func testV8DeduplicatesTimezoneWeeklyReports() throws {
        let tmp = try TempDir()
        let path = tmp.path("usage.db")
        do {
            let store = try UsageStore(path: path)
            func insertLegacy(id: String, generatedAt: Int64, startMs: Int64, endMs: Int64,
                              tz: String, tokens: Int64) throws {
                var totals = UsageTotals()
                totals.input = tokens
                let report = WeeklyReport(
                    id: id, generatedAt: generatedAt,
                    query: UsageQuery(start: startMs, end: endMs, timeZoneID: tz),
                    totals: totals, previous: UsageTotals(), projects: [],
                    models: [], costSources: [], budgets: [], health: [], activityCount: 0)
                let payload = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
                _ = try store.conn.execute("INSERT INTO weekly_reports VALUES (?,?,?)",
                                           [id, generatedAt, payload])
            }
            // 2026-11-09 ~ 2026-11-15 在 4 个时区的重复周报
            try insertLegacy(id: "Asia/Shanghai:1794153600000", generatedAt: 1000,
                             startMs: 1_794_153_600_000, endMs: 1_794_758_400_000,
                             tz: "Asia/Shanghai", tokens: 100)
            try insertLegacy(id: "Asia/Taipei:1794153600000", generatedAt: 2000,
                             startMs: 1_794_153_600_000, endMs: 1_794_758_400_000,
                             tz: "Asia/Taipei", tokens: 200)
            try insertLegacy(id: "America/Los_Angeles:1794211200000", generatedAt: 3000,
                             startMs: 1_794_211_200_000, endMs: 1_794_816_000_000,
                             tz: "America/Los_Angeles", tokens: 300)
            try insertLegacy(id: "Asia/Ho_Chi_Minh:1794157200000", generatedAt: 4000,
                             startMs: 1_794_157_200_000, endMs: 1_794_762_000_000,
                             tz: "Asia/Ho_Chi_Minh", tokens: 400)
            // 上一周（2026-11-02 ~ 2026-11-08）
            try insertLegacy(id: "Asia/Shanghai:1793548800000", generatedAt: 500,
                             startMs: 1_793_548_800_000, endMs: 1_794_153_600_000,
                             tz: "Asia/Shanghai", tokens: 50)
            _ = try store.conn.execute("PRAGMA user_version=7")
            try store.conn.commit()
        }
        let store = try UsageStore(path: path)
        XCTAssertEqual(try store.conn.scalarInt("PRAGMA user_version"), Int64(UsageStore.schemaVersion))
        let reports = try store.weeklyReports()
        XCTAssertEqual(reports.map(\.id), ["week:2026-11-09", "week:2026-11-02"])
        XCTAssertEqual(reports[0].totals.tokens, 400)
        XCTAssertEqual(reports[1].totals.tokens, 50)
        let history = try XCTUnwrap(store.conn.queryOne(
            "SELECT original_json FROM migration_history WHERE version=8"))
        XCTAssertTrue(history.string("original_json").contains("\"removed\":3"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.hasPrefix("usage.db.v7.backup-") }
        XCTAssertEqual(backups.count, 1)
    }

    /// 对齐 test_failed_upgrade_rolls_back_schema_and_values。
    func testFailedUpgradeRollsBack() throws {
        let tmp = try TempDir()
        let path = tmp.path("usage.db")
        try makeOldDatabase(at: path, fail: true)
        XCTAssertThrowsError(try UsageStore(path: path))
        let conn = try SQLiteConnection(path: path)
        XCTAssertEqual(try conn.scalarInt("PRAGMA user_version"), 0)
    }
}
