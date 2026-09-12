import XCTest
@testable import TokenTrackerCore

final class KimiScannerTests: XCTestCase {
    func testExplicitSkillActivationAndSubagentEvents() throws {
        let tmp = try TempDir()
        let root = tmp.path("kimi")
        writeJSONL(tmp.path("kimi", "session_s.jsonl"), [
            ["kind": "event", "seq": 1,
             "envelope": ["type": "skill.activated", "timestamp": fixtureTS,
                          "payload": ["name": "diagram", "skill": ["name": "diagram"],
                                      "turnId": "turn-1"]]],
            ["kind": "event", "seq": 2,
             "envelope": ["type": "subagent.started", "timestamp": fixtureTS,
                          "payload": ["id": "child-1", "name": "worker", "parentId": "root-1",
                                      "turnId": "turn-1"]]],
        ])

        let store = try tmp.store()
        let result = try KimiScanner(journalDir: root, cliDir: tmp.path("missing"))
            .scan(store, testPrices, full: false)
        XCTAssertEqual(result.activityAdded, 2)

        let events = try store.activityTimeline(agent: "kimi", confidence: "all", limit: 100)
        XCTAssertEqual(events.count, 2)
        let skill = try XCTUnwrap(events.first { $0.eventKind == .skill })
        XCTAssertEqual(skill.skillName, "diagram")
        XCTAssertEqual(skill.skillConfidence, "exact")
        XCTAssertEqual(skill.confidence, "exact")
        let agent = try XCTUnwrap(events.first { $0.eventKind == .agent })
        XCTAssertEqual(agent.rawName, "worker")
        XCTAssertEqual(agent.parentCallID, "root-1")
        XCTAssertEqual(agent.eventLayer, .lifecycle)
    }
}
