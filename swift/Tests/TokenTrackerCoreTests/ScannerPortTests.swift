//
//  ScannerPortTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_scanners.py 的 claude/dsh/kimi/pi 用例 + 字节游标 +
//  会话标题提取（test_scanners.py 末尾的 TitleExtractionTest / ByteCursorTest）。
//

import XCTest
@testable import TokenTrackerCore

final class JsonlScannerPortTests: XCTestCase {
    /// test_claude_accepts_top_level_usage_and_invalid_message
    func testClaudeTopLevelUsageAndInvalidMessage() throws {
        let tmp = try TempDir()
        writeJSONL(tmp.path("claude", "project", "session.jsonl"), [
            ["model": "test-model", "usage": ["input_tokens": 10], "timestamp": fixtureTS],
            ["message": "bad", "usage": ["input_tokens": 20],
             "model": "test-model", "timestamp": fixtureTS],
        ])
        let store = try tmp.store()
        let outcome = try ClaudeScanner(root: tmp.path("claude"))
            .scan(store, testPrices, full: false)
        XCTAssertEqual(outcome.added, 2)
        let rows = try store.conn.query("SELECT * FROM usage_events ORDER BY src_key")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.int("input") }, 30)
    }

    /// test_dsh_missing_header_uses_directory_identity
    func testDshMissingHeaderUsesDirectoryIdentity() throws {
        let tmp = try TempDir()
        let event: [String: Any] = ["type": "assistant/chunk", "time": fixtureTSMs, "data": [
            "turn": 0, "step": 0,
            "chunk": ["type": "usage", "usage": ["inputTokens": 10]]]]
        var scanner = DshScanner(root: tmp.path("dsh"))
        scanner.reader = { path in   // 语料是明文 .jsonl.zstd（对齐 Python patch iter_zstd_jsonl）
            iterJSONL(path)
        }
        for session in ["session-a", "session-b"] {
            writeJSONL(tmp.path("dsh", "project", session, "session.jsonl.zstd"), [event])
        }
        let store = try tmp.store()
        _ = try scanner.scan(store, testPrices, full: false)
        _ = try scanner.scan(store, testPrices, full: true)
        let rows = try store.conn.query("SELECT * FROM usage_events")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map { $0.string("session_id") }).count, 2)
    }

    /// test_dsh_old_fallback_row_is_rekeyed_only_after_payload_match
    func testDshOldFallbackRekeyedOnlyAfterPayloadMatch() throws {
        let tmp = try TempDir()
        let event: [String: Any] = ["type": "assistant/chunk", "time": fixtureTSMs, "data": [
            "turn": 0, "step": 0,
            "chunk": ["type": "usage", "usage": ["inputTokens": 10]]]]
        writeJSONL(tmp.path("dsh", "project", "session-a", "session.jsonl.zstd"), [event])
        let store = try tmp.store()
        try store.putEvent(tool: "dsh", srcKey: "session|0|0", sessionID: "session",
                           project: "project", ts: fixtureTSMs, input: 10)
        var scanner = DshScanner(root: tmp.path("dsh"))
        scanner.reader = { iterJSONL($0) }
        _ = try scanner.scan(store, testPrices, full: false)
        let rows = try store.conn.query("SELECT * FROM usage_events")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("session_id"), "project/session-a/session.jsonl.zstd")
    }

    /// test_changed_tail_is_revisited_for_all_jsonl_scanners（改为扫描间追加，
    /// 覆盖同样的游标语义：mtime/size 变化 → 按字节偏移只读新增行）
    func testChangedTailRevisitedForAllJsonlScanners() throws {
        // claude
        try assertTailRevisited(tool: "claude", relative: "project/session.jsonl") { n in
            ["timestamp": fixtureTS,
             "message": ["id": "\(n)", "model": "test-model",
                         "usage": ["input_tokens": 10]]]
        } scan: { store, base in
            try ClaudeScanner(root: base).scan(store, testPrices, full: false)
        }
        // kimi
        try assertTailRevisited(tool: "kimi", relative: "session_a.jsonl") { n in
            ["kind": "event", "seq": n,
             "envelope": ["type": "turn.step.completed", "timestamp": fixtureTS,
                          "payload": ["model": "test-model",
                                      "usage": ["inputOther": 10]]]]
        } scan: { store, base in
            try KimiScanner(journalDir: base, cliDir: "\(base)-absent")
                .scan(store, testPrices, full: false)
        }
        // pi
        try assertTailRevisited(tool: "pi", relative: "session.jsonl") { n in
            ["type": "message", "id": "\(n)", "timestamp": fixtureTS,
             "message": ["model": "test-model", "usage": ["input": 10]]]
        } scan: { store, base in
            try PiScanner(roots: [base]).scan(store, testPrices, full: false)
        }
        // dsh
        try assertTailRevisited(tool: "dsh", relative: "project/session/session.jsonl.zstd") { n in
            ["type": "assistant/chunk", "time": fixtureTSMs, "data": [
                "turn": 0, "step": n,
                "chunk": ["type": "usage", "usage": ["inputTokens": 10]]]]
        } scan: { store, base in
            var scanner = DshScanner(root: base)
            scanner.reader = { iterJSONL($0) }
            return try scanner.scan(store, testPrices, full: false)
        }
    }

    private func assertTailRevisited(
        tool: String, relative: String,
        event: (Int) -> [String: Any],
        scan: (UsageStore, String) throws -> ScanOutcome
    ) throws {
        let tmp = try TempDir()
        let base = tmp.path(tool)
        let path = tmp.path(tool, relative)
        writeJSONL(path, [event(1)])
        let store = try tmp.store()
        _ = try scan(store, base)
        // 追加一行（mtime/size 变化）
        let data = try JSONSerialization.data(withJSONObject: event(2))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data("\n".utf8))
        try handle.close()
        _ = try scan(store, base)
        let rows = try store.conn.query("SELECT * FROM usage_events WHERE tool=?", [tool])
        XCTAssertEqual(rows.count, 2, tool)
    }
}

final class TitleExtractionPortTests: XCTestCase {
    /// test_claude_user_text
    func testClaudeUserText() {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user",
            "content": [["type": "text", "text": "帮我看看 这个   问题"]]]]
        XCTAssertEqual(userText(obj), "帮我看看 这个 问题")
        let obj2: [String: Any] = ["type": "user",
                                   "message": ["role": "user", "content": "直接字符串"]]
        XCTAssertEqual(userText(obj2), "直接字符串")
    }

    /// test_context_injection_filtered
    func testContextInjectionFiltered() {
        for bad in ["# AGENTS.md instructions for /x", "<environment_context>...</environment_context>",
                    "<system-reminder>x</system-reminder>", "Caveat: ..."] {
            let obj: [String: Any] = ["type": "response_item", "payload": ["role": "user",
                "content": [["type": "input_text", "text": bad]]]]
            XCTAssertEqual(userText(obj), "", bad)
        }
    }

    /// test_codex_response_item
    func testCodexResponseItem() {
        let obj: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "修复登录 bug"]]]]
        XCTAssertEqual(userText(obj), "修复登录 bug")
    }

    /// test_assistant_and_nonuser_ignored
    func testAssistantAndNonUserIgnored() {
        XCTAssertEqual(userText(["type": "assistant",
                                 "message": ["role": "assistant", "content": "x"]]), "")
        XCTAssertEqual(userText(["type": "summary", "summary": "x"]), "")
        XCTAssertEqual(userText([:]), "")
    }
}

final class ByteCursorPortTests: XCTestCase {
    /// test_delta_reads_only_new_lines
    func testDeltaReadsOnlyNewLines() throws {
        let tmp = try TempDir()
        let path = tmp.path("s.jsonl")
        try "{\"a\":1}\n{\"a\":2}\n".write(toFile: path, atomically: true, encoding: .utf8)
        let (items, off) = readJSONLDelta(path: path, offset: 0)
        XCTAssertEqual(items.count, 2)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"a\":3}\n".utf8))
        try handle.close()
        let (items2, off2) = readJSONLDelta(path: path, offset: off)
        XCTAssertEqual(items2.map { $0.0 }, [off])
        XCTAssertEqual(items2.first?.1["a"] as? Int, 3)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
        XCTAssertEqual(off2, size)
    }

    /// test_incomplete_tail_line_deferred
    func testIncompleteTailLineDeferred() throws {
        let tmp = try TempDir()
        let path = tmp.path("s.jsonl")
        try "{\"a\":1}\n{\"a\":2".write(toFile: path, atomically: true, encoding: .utf8)
        let (items, off) = readJSONLDelta(path: path, offset: 0)
        XCTAssertEqual(items.count, 1)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
        XCTAssertLessThan(off, size ?? 0)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("}\n".utf8))
        try handle.close()
        let (items2, _) = readJSONLDelta(path: path, offset: off)
        XCTAssertEqual(items2.first?.1["a"] as? Int, 2)
    }

    /// test_truncation_and_misaligned_offset_force_full
    func testTruncationAndMisalignedOffsetForceFull() throws {
        let tmp = try TempDir()
        let path = tmp.path("s.jsonl")
        try "{\"a\":1}\n".write(toFile: path, atomically: true, encoding: .utf8)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0
        XCTAssertEqual(readJSONLDelta(path: path, offset: size + 100).1, -1)  // 截断
        XCTAssertEqual(readJSONLDelta(path: path, offset: 3).1, -1)           // 不在行边界
    }
}
