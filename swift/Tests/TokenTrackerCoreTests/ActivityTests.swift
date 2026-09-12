import XCTest
@testable import TokenTrackerCore

final class ActivityTests: XCTestCase {
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
        XCTAssertEqual(try reopened.conn.scalarInt("PRAGMA user_version"), 4)
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
}
