//
//  CodexScannerTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_scanners.py 的 CodexScannerTest（JSONL+SQLite 双源补缺的
//  20 个用例）。结构对齐：rollout() / log() / scan() 助手与 Python 同名。
//

import XCTest
@testable import TokenTrackerCore

final class CodexScannerPortTests: XCTestCase {
    private var tmp: TempDir!
    private var store: UsageStore!
    private var logsPath: String!
    private var sessionsDir: String!

    override func setUp() async throws {
        tmp = try TempDir()
        store = try tmp.store()
        logsPath = tmp.path("logs.db")
        sessionsDir = tmp.path("sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        tmp = nil; store = nil; logsPath = nil; sessionsDir = nil
    }

    private func rows() throws -> [Row] {
        try store.conn.query("SELECT * FROM usage_events ORDER BY src_key")
    }

    private func scan(full: Bool = false) throws -> ScanOutcome {
        try CodexScanner(logsDB: logsPath, sessionsDir: sessionsDir)
            .scan(store, testPrices, full: full)
    }

    /// rollout()：session_meta + turn_context + events
    @discardableResult
    private func rollout(_ events: [[String: Any]], sid: String = "session-a") -> String {
        let path = (sessionsDir as NSString).appendingPathComponent("\(sid).jsonl")
        writeJSONL(path, [
            ["type": "session_meta", "timestamp": fixtureTS, "payload": ["id": sid, "cwd": "/fixture"]],
            ["type": "turn_context", "timestamp": fixtureTS, "payload": ["model": "test-model"]],
        ] + events)
        return path
    }

    private func tokenEvent(_ total: [String: Any], turn: String? = "turn-a",
                            last: [String: Any]? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": "token_count",
                                      "info": ["total_token_usage": total,
                                               "last_token_usage": last ?? total]]
        if let turn { payload["turn_id"] = turn }
        return ["timestamp": fixtureTS, "type": "event_msg", "payload": payload]
    }

    /// log()：INSERT 一行 turn 遥测
    private func log(_ rowId: Int64, tokens: [String: Any]? = nil,
                     sid: String = "session-a", turn: String? = "turn-a") throws {
        let tokens = tokens ?? fixtureUsage()
        var body = ["input_tokens", "output_tokens", "cached_input_tokens",
                    "cache_write_input_tokens"]
            .filter { tokens[$0] != nil }
            .map { "codex.turn.token_usage.\($0)=\(tokens[$0]!)" }
            .joined(separator: " ")
        body += " model=test-model thread.id=\(sid)"
        if let turn { body += " turn.id=\(turn)" }
        let conn = try SQLiteConnection(path: logsPath)
        _ = try conn.execute(
            "CREATE TABLE IF NOT EXISTS logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, feedback_log_body TEXT)")
        _ = try conn.execute("INSERT INTO logs VALUES (?, ?, 0, ?)",
                             [rowId, fixtureTSMs / 1000, body])
        try conn.commit()
    }

    // ---------------------------------------------------------- 用例 ----

    func testSQLiteNormalizesCachedInputBeforePricing() throws {
        try log(1, tokens: fixtureUsage(1_000_000, 0, 800_000))
        _ = try scan()
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.int("input"), 200_000)
        XCTAssertEqual(row.int("cache_read"), 800_000)
        XCTAssertEqual(row.double("cost"), 0.56, accuracy: 1e-9)
    }

    func testRolloutCumulativeDeltaAndRepeatedNotifications() throws {
        rollout([tokenEvent(fixtureUsage()), tokenEvent(fixtureUsage()),
                 tokenEvent(fixtureUsage(150, 15, 30), turn: "turn-b",
                            last: fixtureUsage(50, 5, 10))])
        _ = try scan()
        _ = try scan(full: true)
        let rows = try rows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("input") }, 120)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("output") }, 15)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("cache_read") }, 30)
        XCTAssertEqual(Set(rows.map { $0.int("ts") }), [fixtureTSMs])
        XCTAssertEqual(Set(rows.map { $0.string("session_id") }), ["session-a"])
        XCTAssertEqual(Set(rows.map { $0.string("project") }), ["/fixture"])
    }

    func testTurnContextAndTaskStartedSupplyMissingTurnID() throws {
        rollout([["type": "event_msg", "timestamp": fixtureTS,
                  "payload": ["type": "task_started", "turn_id": "turn-b"]],
                 tokenEvent(fixtureUsage(), turn: nil)])
        try log(1, turn: "turn-b")
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("source_scope"), "turn-b")
    }

    func testReplayedParentSessionMetaDoesNotStealAttribution() throws {
        // 子代理 rollout：自身 meta 在前，重放的父会话 meta 在后；
        // 用量必须记在子会话名下，同 turn 的 SQLite 遥测被 JSONL 覆盖去重。
        let path = (sessionsDir as NSString).appendingPathComponent("child.jsonl")
        writeJSONL(path, [
            ["type": "session_meta", "timestamp": fixtureTS,
             "payload": ["id": "child", "cwd": "/fixture", "forked_from_id": "parent"]],
            ["type": "session_meta", "timestamp": fixtureTS,
             "payload": ["id": "parent", "cwd": "/fixture"]],
            ["type": "turn_context", "timestamp": fixtureTS, "payload": ["model": "test-model"]],
            tokenEvent(fixtureUsage(), turn: "turn-child"),
        ])
        try log(1, sid: "child", turn: "turn-child")
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("session_id"), "child")
        XCTAssertEqual(rows[0].string("source_kind"), "codex_jsonl")
        XCTAssertEqual(rows[0].int("input"), 80)
    }

    func testPerUsageFallbackAndISOTimestamp() throws {
        let path = (sessionsDir as NSString).appendingPathComponent("fallback.jsonl")
        writeJSONL(path, [["usage": fixtureUsage(100, 10, 20, 5), "model": "test-model",
                           "session_id": "s", "timestamp": fixtureTS]])
        _ = try scan()
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.int("input"), 75)
        XCTAssertEqual(row.int("cache_read"), 20)
        XCTAssertEqual(row.int("cache_write"), 5)
        XCTAssertEqual(row.int("ts"), fixtureTSMs)
        XCTAssertEqual(row.string("src_key"), "legacy|\(path)|1")
    }

    func testSQLiteSameTurnIsNotCountedPerLogLine() throws {
        try log(1)
        try log(2)
        _ = try scan()
        XCTAssertEqual(try rows().count, 1)
    }

    func testRolloutOverridesSameTurnButKeepsMissingTurn() throws {
        try log(1)
        try log(2, tokens: fixtureUsage(50, 5, 10), turn: "turn-b")
        rollout([tokenEvent(fixtureUsage())])
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("input") }, 120)
    }

    func testLaterRolloutReplacesExistingSQLiteWithoutDuplicates() throws {
        try log(1)
        try log(2, tokens: fixtureUsage(50, 5, 10), turn: "turn-b")
        _ = try scan()
        rollout([tokenEvent(fixtureUsage())])
        _ = try scan()
        _ = try scan(full: true)
        let rows = try rows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("input") }, 120)
    }

    func testUnavailableRolloutHistorySurvivesLaterSQLite() throws {
        let path = rollout([tokenEvent(fixtureUsage())])
        _ = try scan()
        try FileManager.default.removeItem(atPath: path)
        try log(1)
        try log(2, tokens: fixtureUsage(50, 5, 10), turn: "turn-b")
        _ = try scan()
        XCTAssertEqual(try rows().count, 2)
    }

    func testUnknownTurnJSONLTakesSessionPrecedence() throws {
        try log(1, turn: nil)
        rollout([tokenEvent(fixtureUsage(), turn: nil)])
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("source_kind"), "codex_jsonl")
    }

    func testPartialRolloutKeepsSQLiteRemainderUntilItCatchesUp() throws {
        try log(1)
        _ = try scan()
        rollout([tokenEvent(fixtureUsage(50, 5, 10))])
        _ = try scan()
        XCTAssertEqual(try rows().reduce(0) { $0 + $1.int("input") }, 80)
        XCTAssertEqual(try rows().count, 2)
        rollout([tokenEvent(fixtureUsage(50, 5, 10)), tokenEvent(fixtureUsage())])
        _ = try scan()
        _ = try scan(full: true)
        XCTAssertEqual(try rows().reduce(0) { $0 + $1.int("input") }, 80)
        XCTAssertEqual(Set(try rows().map { $0.string("source_kind") }), ["codex_jsonl"])
    }

    func testLaterSQLiteSupplementsPartialKnownTurn() throws {
        rollout([tokenEvent(fixtureUsage(50, 5, 10))])
        _ = try scan()
        try log(1)
        _ = try scan()
        _ = try scan(full: true)
        XCTAssertEqual(try rows().reduce(0) { $0 + $1.int("input") }, 80)
        XCTAssertEqual(try rows().count, 2)
    }

    func testUnmappedOldHistoryIsRetainedWithWarning() throws {
        try store.putEvent(tool: "codex", srcKey: "logs2|99", sessionID: "session-a",
                           ts: fixtureTSMs, model: "test-model",
                           input: 40, output: 5, cost: 0.00013)
        rollout([tokenEvent(fixtureUsage())])
        let result = try scan()
        XCTAssertNotNil(result.warning)
        let rows = try rows()
        XCTAssertEqual(rows.count, 2)
        let old = try XCTUnwrap(rows.first { $0.string("src_key") == "logs2|99" })
        XCTAssertEqual(old.string("time_quality"), "unallocated")
    }

    func testLastUsageFallbackThenCumulativeDoesNotDoubleCount() throws {
        var event = tokenEvent(fixtureUsage(50, 5, 10))
        var payload = event["payload"] as! [String: Any]
        var info = payload["info"] as! [String: Any]
        info.removeValue(forKey: "total_token_usage")
        payload["info"] = info
        event["payload"] = payload
        rollout([event, event, tokenEvent(fixtureUsage())])
        _ = try scan()
        XCTAssertEqual(try rows().reduce(0) { $0 + $1.int("input") }, 80)
        XCTAssertEqual(try rows().count, 2)
    }

    func testCumulativeResetIsRebaselinedWithoutNegativeUsage() throws {
        rollout([tokenEvent(fixtureUsage()), tokenEvent(fixtureUsage(10, 1, 0)),
                 tokenEvent(fixtureUsage(30, 3, 5))])
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("input") }, 95)
        XCTAssertTrue(rows.allSatisfy { $0.int("input") >= 0 && $0.int("cache_read") >= 0 })
    }

    func testInitialInheritedTotalUsesLastUsage() throws {
        rollout([tokenEvent(fixtureUsage(1000, 100, 200), last: fixtureUsage())])
        _ = try scan()
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.string("time_quality"), "exact")
        XCTAssertEqual(row.int("input"), 80)
        XCTAssertEqual(row.int("output"), 10)
        XCTAssertEqual(row.int("cache_read"), 20)
    }

    func testContinuationFileDoesNotRecountInheritedSessionTotal() throws {
        writeJSONL((sessionsDir as NSString).appendingPathComponent("a-original.jsonl"), [
            ["type": "session_meta", "timestamp": fixtureTS,
             "payload": ["id": "continued-session", "cwd": "/fixture"]],
            tokenEvent(fixtureUsage()),
        ])
        writeJSONL((sessionsDir as NSString).appendingPathComponent("b-continuation.jsonl"), [
            ["type": "session_meta", "timestamp": fixtureTS,
             "payload": ["id": "continued-session", "cwd": "/fixture"]],
            tokenEvent(fixtureUsage(1000, 100, 200), turn: "turn-b",
                       last: fixtureUsage()),
        ])
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("input") }, 160)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("output") }, 20)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("cache_read") }, 40)
    }

    func testAppendAfterEOFIsReadOnNextScan() throws {
        let path = rollout([tokenEvent(fixtureUsage())])
        _ = try scan()
        // 追加一条（模拟扫描间隙写入），下一轮增量必须读到
        let data = try JSONSerialization.data(
            withJSONObject: tokenEvent(fixtureUsage(150, 15, 30), turn: "turn-b"))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data("\n".utf8))
        try handle.close()
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("input") }, 120)
    }

    func testInvalidRolloutNeverRemovesSQLiteHistory() throws {
        try log(1)
        _ = try scan()
        rollout([tokenEvent(["input_tokens": "invalid"])])
        _ = try scan()
        let rows = try rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].int("input"), 80)
    }

    func testLegacyDatabaseRowIsCorrectedInPlace() throws {
        try log(1)
        try store.putEvent(tool: "codex", srcKey: "logs2|1", sessionID: "session-a",
                           ts: fixtureTSMs, model: "test-model",
                           input: 100, output: 10, cacheRead: 20, cost: 999)
        _ = try scan()
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.string("src_key"), "logs2|1")
        XCTAssertEqual(row.int("input"), 80)
        XCTAssertNotEqual(row.double("cost"), 999)
    }

    func testUnavailableOldSQLiteHistoryIsPreserved() throws {
        try store.putEvent(tool: "codex", srcKey: "logs2|99", sessionID: "other-session",
                           ts: fixtureTSMs, model: "test-model",
                           input: 40, output: 5, cost: 0.00013)
        rollout([tokenEvent(fixtureUsage())])
        _ = try scan()
        XCTAssertEqual(try rows().count, 2)
    }

    func testFailureRollsBackSourceReplacement() throws {
        try log(1)
        _ = try scan()
        let before = try store.conn.query("SELECT * FROM usage_events ORDER BY src_key")
        rollout([tokenEvent(fixtureUsage())])
        struct Synthetic: Error {}
        store.putEventHook = { _, sourceKind in
            if sourceKind == "codex_jsonl" { throw Synthetic() }
        }
        XCTAssertThrowsError(try CodexScanner(logsDB: logsPath, sessionsDir: sessionsDir)
            .scan(store, testPrices, full: false))
        store.putEventHook = nil
        let after = try store.conn.query("SELECT * FROM usage_events ORDER BY src_key")
        XCTAssertEqual(after.count, before.count)
        let cols = ["tool", "src_key", "session_id", "project", "ts", "model",
                    "input", "output", "cache_read", "cache_write", "time_quality",
                    "cost_source", "source_kind", "source_scope"]
        for (index, pair) in zip(before, after).enumerated() {
            for col in cols {
                XCTAssertEqual(pair.0[col] as? Int64, pair.1[col] as? Int64, "行 \(index) 列 \(col)")
                XCTAssertEqual(pair.0[col] as? String, pair.1[col] as? String, "行 \(index) 列 \(col)")
            }
        }
    }
}
