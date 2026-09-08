//
//  DifferentialScanTests.swift
//  TokenTrackerCoreTests
//
//  Phase 1 的硬门槛：Swift 扫描器扫 tests/differential 语料的结果，
//  必须与 Python 基线 expected_python.json 逐字段一致。
//

import XCTest
@testable import TokenTrackerCore

final class DifferentialScanTests: XCTestCase {
    static let fixedNowMs: Int64 = 1_787_626_800_000 // 2026-08-25T03:00:00Z

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TokenTrackerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // repo root
    }

    /// 语料不存在时用 make_corpus.py 生成（需要 python3 + zstd）。
    private func ensureCorpus() throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: "/tmp/tt_diff_corpus", isDirectory: &isDir),
           isDir.boolValue { return }
        let script = repoRoot.appendingPathComponent("tests/differential/make_corpus.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "make_corpus.py 生成失败")
    }

    private func corpusRoots() -> ScanRoots {
        var roots = ScanRoots(environment: [:])
        let corpus = "/tmp/tt_diff_corpus"
        roots.claude = "\(corpus)/claude/projects"
        roots.codexLogsDB = "\(corpus)/codex/logs_2.sqlite"
        roots.codexSessions = "\(corpus)/codex/sessions"
        roots.opencodeDB = "\(corpus)/opencode/opencode.db"
        roots.dshSessions = "\(corpus)/dsh/sessions"
        roots.hermesHome = "\(corpus)/hermes"
        roots.kimiCodeHome = "\(corpus)/kimi-code/server/events"
        roots.kimiCLI = "\(corpus)/kimi-cli-nonexistent"
        roots.piRoots = ["\(corpus)/pi/sessions"]
        return roots
    }

    private func normalizedEvents(_ store: UsageStore) throws -> [ExpectedEvent] {
        try store.conn.query(
            "SELECT tool,src_key,session_id,project,ts,model,input,output,"
                + "cache_read,cache_write,cost,time_quality,interval_start,cost_source,"
                + "source_kind,source_scope FROM usage_events ORDER BY tool,src_key"
        ).map { row in
            ExpectedEvent(
                tool: row.string("tool"), srcKey: row.string("src_key"),
                sessionID: row.string("session_id"), project: row.string("project"),
                ts: row.int("ts"), model: row.string("model"),
                input: row.int("input"), output: row.int("output"),
                cacheRead: row.int("cache_read"), cacheWrite: row.int("cache_write"),
                cost: row.doubleOrNil("cost").map { roundHalfEven($0, 6) },
                timeQuality: row.string("time_quality"),
                intervalStart: row.intOrNil("interval_start"),
                costSource: row.string("cost_source"),
                sourceKind: row.string("source_kind"),
                sourceScope: row.string("source_scope"))
        }
    }

    private func normalizedMeta(_ store: UsageStore) throws -> [ExpectedSessionMeta] {
        try store.conn.query(
            "SELECT tool,session_id,title FROM session_meta ORDER BY tool,session_id"
        ).map { ExpectedSessionMeta(tool: $0.string("tool"),
                                    sessionID: $0.string("session_id"),
                                    title: $0.string("title")) }
    }

    private func normalizedActivities(_ store: UsageStore) throws -> [ExpectedActivity] {
        try store.conn.query(
            "SELECT agent,session_id,turn_id,raw_name,canonical_name,namespace,call_id,"
                + "parent_call_id,started_at,ended_at,duration_ms,status,source_kind,confidence,"
                + "skill_name,skill_confidence,src_key FROM agent_activity_events ORDER BY agent,src_key"
        ).map { row in
            ExpectedActivity(agent: row.string("agent"), sessionID: row.string("session_id"),
                turnID: row.string("turn_id"), rawName: row.string("raw_name"),
                canonicalName: row.string("canonical_name"), namespace: row.string("namespace"),
                callID: row.string("call_id"), parentCallID: row.string("parent_call_id"),
                startedAt: row.intOrNil("started_at"), endedAt: row.intOrNil("ended_at"),
                durationMs: row.intOrNil("duration_ms"), status: row.string("status"),
                sourceKind: row.string("source_kind"), confidence: row.string("confidence"),
                skillName: row.string("skill_name"), skillConfidence: row.string("skill_confidence"),
                srcKey: row.string("src_key"))
        }
    }

    private func normalizedSnapshots(_ store: UsageStore) throws -> [ExpectedSnapshot] {
        try store.conn.query(
            "SELECT tool,source_scope,identity,values_json,observed_at,revision "
                + "FROM aggregate_snapshots ORDER BY tool,source_scope,identity"
        ).map { row in
            let valuesText = row.string("values_json")
            var values = (try? JSONDecoder().decode(SnapshotValues.self,
                                                    from: Data(valuesText.utf8))) ?? SnapshotValues()
            values.nativeCost = values.nativeCost.map { roundHalfEven($0, 6) }
            values.accountedCost = values.accountedCost.map { roundHalfEven($0, 6) }
            values.costOffset = values.costOffset.map { roundHalfEven($0, 6) }
            return ExpectedSnapshot(tool: row.string("tool"),
                                    sourceScope: row.string("source_scope"),
                                    identity: row.string("identity"),
                                    observedAt: row.int("observed_at"),
                                    revision: Int(row.int("revision")),
                                    values: values)
        }
    }

    func testSwiftMatchesPythonBaseline() throws {
        try ensureCorpus()
        let store = try UsageStore(path: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tt_diff_swift_\(UUID().uuidString).db").path)
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        store.nowMs = { DifferentialScanTests.fixedNowMs }

        let prices = PriceTable.load(from: repoRoot
            .appendingPathComponent("tests/differential/prices.json").path)
        let runner = ScanRunner(store: store, prices: prices, roots: corpusRoots())
        let results = runner.runAll()
        _ = try store.reprice(prices)

        let baseline = try ExpectedExport.load(from: repoRoot
            .appendingPathComponent("tests/differential/expected_python.json"))

        // scan_results
        var scanResults: [String: ScanResultCounts] = [:]
        for (tool, outcome) in results {
            scanResults[tool] = ScanResultCounts(
                added: outcome.added, updated: outcome.updated, files: outcome.files,
                counterResets: ["opencode", "hermes"].contains(tool) ? outcome.counterResets : nil,
                activityAdded: outcome.activityAdded, activityUpdated: outcome.activityUpdated,
                warning: outcome.warning, skipped: outcome.skipped)
        }
        assertDictEqual(scanResults, baseline.scanResults, label: "scan_results")

        // events（逐字段比对，定位第一条差异）
        let events = try normalizedEvents(store)
        XCTAssertEqual(events.count, baseline.events.count,
                       "events 数量不一致\nSwift: \(events)\nPython: \(baseline.events)")
        for (index, pair) in zip(events, baseline.events).enumerated() {
            XCTAssertEqual(pair.0, pair.1, "events[\(index)] 不一致", file: #filePath, line: 0)
        }

        let activities = try normalizedActivities(store)
        XCTAssertEqual(activities.count, baseline.activities.count, "activities 数量不一致")
        for (index, pair) in zip(activities, baseline.activities).enumerated() {
            XCTAssertEqual(pair.0, pair.1, "activities[\(index)] 不一致", file: #filePath, line: 0)
        }

        // session_meta / snapshots
        XCTAssertEqual(try normalizedMeta(store), baseline.sessionMeta, "session_meta 不一致")
        XCTAssertEqual(try normalizedSnapshots(store), baseline.snapshots, "snapshots 不一致")
    }

    private func assertDictEqual(_ lhs: [String: ScanResultCounts],
                                 _ rhs: [String: ScanResultCounts], label: String) {
        XCTAssertEqual(Set(lhs.keys), Set(rhs.keys), "\(label) 键集不一致")
        for key in lhs.keys {
            XCTAssertEqual(lhs[key], rhs[key], "\(label)[\(key)] 不一致")
        }
    }
}
