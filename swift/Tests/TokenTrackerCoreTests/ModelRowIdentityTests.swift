import XCTest
@testable import TokenTrackerCore

final class ModelRowIdentityTests: XCTestCase {
    func testSameModelAcrossToolsHasDistinctStableIdentity() {
        let codex = UsageStore.ModelRow(tool: "codex", model: "gpt-6.1-sol", stats: .init())
        var pi = UsageStore.ModelRow(tool: "pi", model: "gpt-6.1-sol", stats: .init())
        XCTAssertNotEqual(codex.id, pi.id)
        let originalID = pi.id
        pi.stats.tokens = 100
        XCTAssertEqual(pi.id, originalID)
        XCTAssertEqual(Set([codex.id, pi.id]).count, 2)
    }

    func testIdentityDoesNotCollideWhenComponentsContainSeparators() {
        let first = UsageStore.ModelRow(tool: "a:b", model: "c", stats: .init())
        let second = UsageStore.ModelRow(tool: "a", model: "b:c", stats: .init())
        XCTAssertNotEqual(first.id, second.id)
    }
}
