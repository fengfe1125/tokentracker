import XCTest
@testable import TokenTrackerCore

final class ActivityTests: XCTestCase {
    func testCompletionStillTargetsNewestMatchingCallAcrossAgents() throws {
        let temp = try TempDir()
        let store = try temp.store()
        try store.recordActivity(agent: "codex", srcKey: "older", rawName: "shell", sessionID: "older", callID: "reused", startedAt: 10)
        try store.recordActivity(agent: "codex", srcKey: "newer", rawName: "shell", sessionID: "newer", callID: "reused", startedAt: 20)
        try store.recordActivity(agent: "claude", srcKey: "other", rawName: "shell", sessionID: "other", callID: "reused", startedAt: 30)
        XCTAssertEqual(try store.completeActivity(agent: "codex", callID: "reused", endedAt: 45), 1)
        XCTAssertEqual(try store.activityTimeline(sessionID: "newer").first?.durationMs, 25)
        XCTAssertNil(try store.activityTimeline(sessionID: "older").first?.endedAt)
        XCTAssertNil(try store.activityTimeline(sessionID: "other").first?.endedAt)
        XCTAssertEqual(try store.completeActivity(agent: "codex", callID: "missing", endedAt: 50), 0)
    }

    func testRecordActivityIsIdempotentAndResultEnrichesCall() throws {
        let temp = try TempDir()
        let store = try temp.store()

        let first = try store.recordActivity(
            agent: "claude", srcKey: "fixture:1", rawName: "Skill",
            sessionID: "session-1", callID: "call-1", startedAt: 100,
            sourceKind: "tool_use", arguments: ["skill": "research"])
        let duplicate = try store.recordActivity(
            agent: "claude", srcKey: "fixture:1", rawName: "Skill",
            sessionID: "session-1", callID: "call-1", startedAt: 100,
            sourceKind: "tool_use", arguments: ["skill": "research"])
        let updated = try store.completeActivity(
            agent: "claude", callID: "call-1", status: "success", endedAt: 145)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(duplicate.added, 0)
        XCTAssertEqual(duplicate.updated, 0)
        XCTAssertEqual(updated, 1)
        let rows = try store.activityTimeline(sessionID: "session-1")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].skillName, "research")
        XCTAssertEqual(rows[0].skillConfidence, "exact")
        XCTAssertEqual(rows[0].status, "success")
        XCTAssertEqual(rows[0].durationMs, 45)
    }

    func testExactAndDerivedStaySeparateInSummary() throws {
        let temp = try TempDir()
        let store = try temp.store()
        _ = try store.recordActivity(
            agent: "codex", srcKey: "outer", rawName: "exec",
            sessionID: "s", callID: "outer", startedAt: 10,
            status: "success", sourceKind: "function_call", confidence: "exact")
        _ = try store.recordActivity(
            agent: "codex", srcKey: "inner", rawName: "read_mcp_resource",
            sessionID: "s", parentCallID: "outer", startedAt: 11,
            status: "unknown", sourceKind: "exec_inner", confidence: "derived")

        XCTAssertEqual(try store.activitySummary(group: "agent", confidence: "exact").first?.calls, 1)
        XCTAssertEqual(try store.activitySummary(group: "agent", confidence: "derived").first?.calls, 1)
        let combined = try XCTUnwrap(store.activitySummary(group: "agent", confidence: "all").first)
        XCTAssertEqual(combined.exact, 1)
        XCTAssertEqual(combined.derived, 1)
    }

    func testCrossAgentToolSummaryUsesCanonicalNames() throws {
        let temp = try TempDir()
        let store = try temp.store()
        _ = try store.recordActivity(agent: "claude", srcKey: "one", rawName: "Bash")
        _ = try store.recordActivity(agent: "codex", srcKey: "two", rawName: "shell")

        let combined = try XCTUnwrap(store.activitySummary(group: "tool").first)
        XCTAssertEqual(combined.name, "shell")
        XCTAssertEqual(combined.calls, 2)
        XCTAssertEqual(try store.activitySummary(
            agent: "claude", group: "tool").first?.name, "Bash")
    }

    func testMatrixSummaryMatchesPerAgentCanonicalSummaries() throws {
        let temp = try TempDir()
        let store = try temp.store()
        _ = try store.recordActivity(agent: "claude", srcKey: "one", rawName: "Bash")
        _ = try store.recordActivity(agent: "claude", srcKey: "alias", rawName: "shell")
        _ = try store.recordActivity(agent: "codex", srcKey: "two", rawName: "shell")
        _ = try store.recordActivity(agent: "codex", srcKey: "three", rawName: "apply_patch",
                                     confidence: "derived")

        let matrix = try store.activityMatrixSummary(confidence: "all")
        XCTAssertEqual(matrix["claude"]?.map(\.name), ["shell"])
        XCTAssertEqual(matrix["claude"]?.map(\.calls), [2])
        XCTAssertEqual(matrix["codex"]?.map(\.name), ["file.edit", "shell"])
        XCTAssertEqual(matrix["codex"]?.map(\.calls), [1, 1])
        XCTAssertEqual(try store.activityMatrixSummary(confidence: "exact")["codex"]?.map(\.name),
                       ["shell"])
    }

    func testNormalizationAndConservativeCodexInference() {
        XCTAssertEqual(ActivityNormalizer.canonicalToolName("apply_patch"), "file.edit")
        XCTAssertEqual(ActivityNormalizer.canonicalToolName("mcp__server__lookup"), "mcp.server.lookup")
        XCTAssertEqual(ActivityNormalizer.inferredCodexTools(
            "await tools.read_mcp_resource({}); tools[name]({}); tools.map(x => x)"),
            ["read_mcp_resource"])
        XCTAssertEqual(activityCapabilities["pi"]?["skills"], "unknown")
    }

    func testSkillPathIsDerivedOnlyWhenExplicitlyAllowed() {
        let path = "open /tmp/skills/openai-docs/SKILL.md now"
        XCTAssertEqual(ActivityNormalizer.skill(
            rawName: "exec", arguments: path, allowPath: false).name, "")
        let inferred = ActivityNormalizer.skill(
            rawName: "exec", arguments: path, allowPath: true)
        XCTAssertEqual(inferred.name, "openai-docs")
        XCTAssertEqual(inferred.confidence, "derived")
    }

    func testTimelineHonorsRange() throws {
        let temp = try TempDir()
        let store = try temp.store()
        _ = try store.recordActivity(
            agent: "kimi", srcKey: "today", rawName: "Read", startedAt: store.nowMs())
        _ = try store.recordActivity(
            agent: "kimi", srcKey: "old", rawName: "Read", startedAt: 1)
        XCTAssertEqual(try store.activityTimeline(rangeKey: "day").count, 1)
        XCTAssertEqual(try store.activityTimeline(rangeKey: "all").count, 2)
    }

    func testKindFilterHasStableCursorAndDoesNotTruncateSkillSummary() throws {
        let temp = try TempDir()
        let store = try temp.store()
        for index in 0..<12 {
            _ = try store.recordActivity(
                agent: "claude", srcKey: "skill-\(index)", rawName: "Skill",
                sessionID: "session-\(index % 2)", callID: "skill-call-\(index)",
                startedAt: 100, status: "success",
                arguments: ["skill": "skill-\(index)"])
        }
        _ = try store.recordActivity(
            agent: "codex", srcKey: "ordinary-tool", rawName: "exec", startedAt: 100,
            arguments: ["path": "/skills/accidental/SKILL.md"], eventKind: .tool)

        XCTAssertEqual(try store.activitySummary(group: "skill").count, 12)
        XCTAssertEqual(try store.activitySummary(group: "tool").count, 1)
        var page = try store.activityTimelinePage(
            confidence: "all", limit: 5, kind: .skill)
        var seen = page.rows
        while let before = page.nextBefore {
            page = try store.activityTimelinePage(
                confidence: "all", limit: 5, before: before,
                beforeID: page.nextBeforeID, kind: .skill)
            seen.append(contentsOf: page.rows)
        }
        XCTAssertEqual(Set(seen.map(\.srcKey)).count, 12)
        XCTAssertEqual(try store.activityTimelinePage(
            confidence: "all", limit: 100, kind: .skill, query: "skill-11").rows
            .map(\.skillName), ["skill-11"])
        XCTAssertEqual(activityCapability(agent: "pi", category: "skills"), .unknown)
        XCTAssertEqual(activityCapability(agent: "missing", category: "skills"), .unavailable)
    }

    func testV2MarkerPreservesCompatibleResidualActivityRows() throws {
        let temp = try TempDir()
        do {
            let store = try temp.store()
            _ = try store.recordActivity(
                agent: "codex", srcKey: "kept", rawName: "exec", status: "success")
            _ = try store.conn.execute("PRAGMA user_version=2")
            try store.conn.commit()
        }

        let reopened = try temp.store()
        XCTAssertEqual(try reopened.conn.scalarInt("PRAGMA user_version"), Int64(UsageStore.schemaVersion))
        XCTAssertEqual(try reopened.activityTimeline().map(\.srcKey), ["kept"])
    }

    func testV2MarkerRejectsMalformedResidualActivityTable() throws {
        let temp = try TempDir()
        do {
            let store = try temp.store()
            _ = try store.conn.execute("DROP TABLE agent_activity_events")
            _ = try store.conn.execute(
                "CREATE TABLE agent_activity_events(id INTEGER PRIMARY KEY,agent TEXT)")
            _ = try store.conn.execute("PRAGMA user_version=2")
            try store.conn.commit()
        }

        XCTAssertThrowsError(try temp.store()) { error in
            XCTAssertTrue(String(describing: error).contains("schema is incompatible"))
        }
        let raw = try SQLiteConnection(path: temp.path("usage.db"))
        XCTAssertEqual(try raw.scalarInt("PRAGMA user_version"), 2)
    }

    func testV3ActivityTableAddsKindAndLayerAfterExistingRows() throws {
        let temp = try TempDir()
        let raw = try SQLiteConnection(path: temp.path("usage.db"))
        _ = try raw.execute("""
            CREATE TABLE agent_activity_events(
              id INTEGER PRIMARY KEY, agent TEXT NOT NULL,
              session_id TEXT NOT NULL DEFAULT '', turn_id TEXT NOT NULL DEFAULT '',
              raw_name TEXT NOT NULL, canonical_name TEXT NOT NULL,
              namespace TEXT NOT NULL DEFAULT '', call_id TEXT NOT NULL DEFAULT '',
              parent_call_id TEXT NOT NULL DEFAULT '', started_at INTEGER, ended_at INTEGER,
              duration_ms INTEGER, status TEXT NOT NULL DEFAULT 'unknown',
              source_kind TEXT NOT NULL DEFAULT '', confidence TEXT NOT NULL DEFAULT 'exact',
              skill_name TEXT NOT NULL DEFAULT '', skill_confidence TEXT NOT NULL DEFAULT '',
              src_key TEXT NOT NULL, UNIQUE(agent, src_key))
            """)
        _ = try raw.execute(
            "INSERT INTO agent_activity_events(agent,raw_name,canonical_name,source_kind,src_key) "
                + "VALUES (?,?,?,?,?)",
            ["codex", "exec", "exec", "codex_rollout", "old-tool"])
        _ = try raw.execute(
            "INSERT INTO agent_activity_events(agent,raw_name,canonical_name,skill_name,"
                + "skill_confidence,src_key) VALUES (?,?,?,?,?,?)",
            ["claude", "Skill", "skill.activate", "research", "exact", "old-skill"])
        _ = try raw.execute("PRAGMA user_version=3")
        try raw.commit()

        let upgraded = try temp.store()
        let rows = try upgraded.conn.query(
            "SELECT raw_name,event_kind,event_layer FROM agent_activity_events ORDER BY id")
        XCTAssertEqual(rows.map { ($0.string("raw_name"), $0.string("event_kind"), $0.string("event_layer")) }.count, 2)
        XCTAssertEqual(rows[0].string("event_kind"), "tool")
        XCTAssertEqual(rows[0].string("event_layer"), "request_fallback")
        XCTAssertEqual(rows[1].string("event_kind"), "skill")
    }

    func testDshAndPiRealToolResultFormatsCompleteActivityStatus() throws {
        let temp = try TempDir()
        let store = try temp.store()

        // Pi: role == "toolResult" 直接在 message 顶层携带 toolCallId / isError
        let piDir = temp.path("pi")
        try FileManager.default.createDirectory(atPath: piDir, withIntermediateDirectories: true)
        writeJSONL(temp.path("pi", "s1.jsonl"), [
            ["type": "session", "id": "pi-s1", "cwd": "/repo"],
            ["type": "message", "id": "m1", "timestamp": 1_787_619_600_000,
             "message": ["role": "assistant", "content": [
                ["type": "toolCall", "id": "pi-ok", "name": "bash"],
                ["type": "toolCall", "id": "pi-err", "name": "read"],
             ]]],
            ["type": "message", "id": "m2", "timestamp": 1_787_619_601_500,
             "message": ["role": "toolResult", "toolCallId": "pi-ok", "isError": false]],
            ["type": "message", "id": "m3", "timestamp": 1_787_619_602_000,
             "message": ["role": "toolResult", "toolCallId": "pi-err", "isError": true]],
        ])
        _ = try PiScanner(roots: [piDir]).scan(store, .default, full: false)
        let piEvents = try store.activityTimeline(agent: "pi", confidence: "exact", limit: 10)
        XCTAssertEqual(piEvents.first { $0.callID == "pi-ok" }?.status, "success")
        XCTAssertEqual(piEvents.first { $0.callID == "pi-ok" }?.durationMs, 1500)
        XCTAssertEqual(piEvents.first { $0.callID == "pi-err" }?.status, "error")

        // DSH: tool/result 把 toolCallId / isError 放在 data.message.content[].tool-result
        let dshDir = temp.path("dsh", "ws", "sess1")
        try FileManager.default.createDirectory(atPath: dshDir, withIntermediateDirectories: true)
        let dshFile = temp.path("dsh", "ws", "sess1", "session.jsonl.zstd")
        FileManager.default.createFile(atPath: dshFile, contents: Data())
        var dsh = DshScanner(root: temp.path("dsh"))
        dsh.reader = { _ in
            [
                (1, ["type": "session", "id": "dsh-s1", "cwd": "/repo"]),
                (2, ["type": "tool/call", "time": 1_787_619_600_000,
                     "data": ["callId": "dsh-ok", "name": "bash"]]),
                (3, ["type": "tool/call", "time": 1_787_619_600_100,
                     "data": ["callId": "dsh-err", "name": "read"]]),
                (4, ["type": "tool/result", "time": 1_787_619_600_400,
                     "data": ["message": ["source": ["kind": "tool", "callId": "dsh-ok"],
                                          "content": [["type": "tool-result", "toolCallId": "dsh-ok", "isError": false]]]]]),
                (5, ["type": "tool/result", "time": 1_787_619_600_600,
                     "data": ["message": ["source": ["kind": "tool", "callId": "dsh-err"],
                                          "content": [["type": "tool-result", "toolCallId": "dsh-err", "isError": true]]]]]),
            ]
        }
        _ = try dsh.scan(store, .default, full: false)
        let dshEvents = try store.activityTimeline(agent: "dsh", confidence: "exact", limit: 10)
        XCTAssertEqual(dshEvents.first { $0.callID == "dsh-ok" }?.status, "success")
        XCTAssertEqual(dshEvents.first { $0.callID == "dsh-ok" }?.durationMs, 400)
        XCTAssertEqual(dshEvents.first { $0.callID == "dsh-err" }?.status, "error")
    }
}
