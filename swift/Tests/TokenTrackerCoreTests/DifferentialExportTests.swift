//
//  DifferentialExportTests.swift
//  TokenTrackerCoreTests
//
//  验证冻结差分基线 Fixtures/differential/expected.json 可被解码。
//

import XCTest
@testable import TokenTrackerCore

final class DifferentialExportTests: XCTestCase {
    private func loadBaseline() throws -> ExpectedExport {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/differential/expected.json")
        return try ExpectedExport.load(from: url)
    }

    func testBaselineDecodes() throws {
        let export = try loadBaseline()
        XCTAssertEqual(export.formatVersion, TokenTrackerCore.differentialFormatVersion)
        XCTAssertEqual(Set(export.scanResults.keys),
                       ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"])
        XCTAssertEqual(export.events.count, 19)
        XCTAssertEqual(export.sessionMeta.count, 7)
        XCTAssertEqual(export.snapshots.count, 4)
    }

    func testBaselineSpotValues() throws {
        let export = try loadBaseline()
        let claude = try XCTUnwrap(export.events.first {
            $0.tool == "claude" && $0.srcKey == "s-claude-1|msg_1"
        })
        XCTAssertEqual(claude.input, 1200)
        XCTAssertEqual(claude.cost, 0.0099)
        XCTAssertEqual(claude.timeQuality, "exact")

        // 聚合快照事件：时间未分配 + native 成本
        let hermes = try XCTUnwrap(export.events.first {
            $0.tool == "hermes" && $0.sessionID == "hermes-sess-1"
        })
        XCTAssertEqual(hermes.timeQuality, "unallocated")
        XCTAssertEqual(hermes.costSource, "native")
        XCTAssertEqual(hermes.cost, 0.052)

        // 事件按 (tool, src_key) 排序 —— Swift 侧导出必须同样排序
        let keys = export.events.map { "\($0.tool)\u{0}\($0.srcKey)" }
        XCTAssertEqual(keys, keys.sorted())
    }
}
