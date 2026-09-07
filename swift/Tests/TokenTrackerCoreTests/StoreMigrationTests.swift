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
        XCTAssertEqual(codex.double("cost"), 0.35, accuracy: 1e-9)
        XCTAssertEqual(codex.string("cost_source"), "recomputed")
        XCTAssertEqual(codex.string("time_quality"), "unallocated")

        // 重复打开不重复迁移/备份
        let again = try UsageStore(path: path)
        XCTAssertEqual(try again.stats().total.tokens, 1_001_000)
        let backups2 = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.hasPrefix("usage.db.v0.backup-") }
        XCTAssertEqual(backups2.count, 1)
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
