import XCTest
@testable import TokenTrackerCore

final class SessionSourceResolverTests: XCTestCase {
    func testAbbreviateHomePathHandlesExactSubpathAndNonMatchingPrefix() {
        XCTAssertEqual(abbreviateHomePath("/Users/alice", home: "/Users/alice"), "~")
        XCTAssertEqual(
            abbreviateHomePath(
                "/Users/alice/.claude/projects/-Volumes-Developer-----/1bac6cac-aa7f-48b3-befe-0d0bc188f811.jsonl",
                home: "/Users/alice/"),
            "~/.claude/projects/-Volumes-Developer-----/1bac6cac-aa7f-48b3-befe-0d0bc188f811.jsonl")
        XCTAssertEqual(
            abbreviateHomePath("/Volumes/Developer/Project", home: "/Users/alice"),
            "/Volumes/Developer/Project")
        XCTAssertEqual(
            abbreviateHomePath("/Users/alice2/work", home: "/Users/alice"),
            "/Users/alice2/work")
    }

    func testClaudeSessionResolvesRealFolderPrimaryModelAndFile() throws {
        let tmp = try TempDir()
        let store = try tmp.store()
        let realWorkspace = tmp.path("workspaces/我的项目")
        try FileManager.default.createDirectory(atPath: realWorkspace, withIntermediateDirectories: true)

        let slug = "-Volumes-Developer-----"
        let sessionID = "1bac6cac-aa7f-48b3-befe-0d0bc188f811"
        let claudeRoot = tmp.path("claude/projects")
        let sessionFile = "\(claudeRoot)/\(slug)/\(sessionID).jsonl"
        try FileManager.default.createDirectory(
            atPath: (sessionFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let lines: [[String: Any]] = [
            [
                "type": "user",
                "cwd": realWorkspace,
                "timestamp": "2026-11-21T03:00:00Z",
                "message": ["role": "user", "content": "帮我检查会话展示"],
            ],
            [
                "type": "assistant",
                "cwd": realWorkspace,
                "timestamp": "2026-11-21T03:05:00Z",
                "message": [
                    "id": "msg_opus",
                    "model": "claude-opus-5-5",
                    "usage": [
                        "input_tokens": 696,
                        "output_tokens": 484_000,
                        "cache_read_input_tokens": 104_000_000,
                        "cache_creation_input_tokens": 1_537_000,
                    ],
                ],
            ],
            [
                "type": "assistant",
                "cwd": realWorkspace,
                "timestamp": "2026-11-21T03:20:00Z",
                "message": [
                    "id": "msg_sonnet",
                    "model": "claude-sonnet-4-5",
                    "usage": [
                        "input_tokens": 100,
                        "output_tokens": 50,
                        "cache_read_input_tokens": 0,
                        "cache_creation_input_tokens": 0,
                    ],
                ],
            ],
        ]
        let content = try lines.map {
            String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try content.write(toFile: sessionFile, atomically: true, encoding: .utf8)

        var roots = ScanRoots(environment: [:])
        roots.claude = claudeRoot
        let outcome = try ClaudeScanner(root: claudeRoot).scan(store, .default, full: true)
        XCTAssertEqual(outcome.added, 2)

        let rows = try store.sessions(rangeKey: "all", tool: "claude", roots: roots)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sessionID, sessionID)
        // claude-opus-5-5 消耗远大于 claude-sonnet-4-5，即使按字母序排在前面也应作为主模型
        XCTAssertEqual(row.model, "claude-opus-5-5")
        XCTAssertEqual(row.models, ["claude-opus-5-5", "claude-sonnet-4-5"])
        XCTAssertEqual(row.filePath, sessionFile)
        XCTAssertTrue(row.fileExists)
        XCTAssertEqual(realPath(row.workspacePath), realPath(realWorkspace))
        XCTAssertTrue(row.workspaceExists)
        XCTAssertNotNil(row.firstTs)
        XCTAssertNotNil(row.ts)
        XCTAssertLessThan(try XCTUnwrap(row.firstTs), try XCTUnwrap(row.ts))

        // 按真实文件夹名与主模型名搜索都能命中
        XCTAssertEqual(try store.sessions(rangeKey: "all", query: "我的项目", roots: roots).count, 1)
        XCTAssertEqual(try store.sessions(rangeKey: "all", query: "claude-opus-5-5", roots: roots).count, 1)

        // 详情查询同样返回完整文件与工作目录
        let detail = try store.sessionDetail(tool: "claude", sessionID: sessionID, roots: roots)
        XCTAssertEqual(detail.filePath, sessionFile)
        XCTAssertTrue(detail.fileExists)
        XCTAssertEqual(realPath(detail.workspacePath), realPath(realWorkspace))
        XCTAssertTrue(detail.workspaceExists)
        XCTAssertEqual(detail.models.map(\.model), ["claude-opus-5-5", "claude-sonnet-4-5"])

        // 清除 project_sources 后（模拟旧库未回填），依然能从 JSONL 流式解析真实工作目录
        _ = try store.conn.execute("DELETE FROM project_sources")
        try store.conn.commit()
        let fallbackRow = try XCTUnwrap(store.sessions(rangeKey: "all", tool: "claude", roots: roots).first)
        XCTAssertEqual(realPath(fallbackRow.workspacePath), realPath(realWorkspace))
        XCTAssertTrue(fallbackRow.workspaceExists)

        // 删除源文件后：cursor 仍保留历史路径，但 fileExists 准确变为 false
        try FileManager.default.removeItem(atPath: sessionFile)
        let deletedRow = try XCTUnwrap(store.sessions(rangeKey: "all", tool: "claude", roots: roots).first)
        XCTAssertEqual(deletedRow.filePath, sessionFile)
        XCTAssertFalse(deletedRow.fileExists)
    }

    func testResolvesFilesAcrossOtherAgents() throws {
        let tmp = try TempDir()
        let store = try tmp.store()
        let workspace = tmp.path("repo")
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)

        // 1. Codex rollout + SQLite fallback
        let codexRollout = tmp.path("codex/sessions/2026/11/21/rollout-codex-1.jsonl")
        try FileManager.default.createDirectory(
            atPath: (codexRollout as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"codex-1\",\"cwd\":\"\(workspace)\"}}\n"
            .write(toFile: codexRollout, atomically: true, encoding: .utf8)
        let codexDB = tmp.path("codex/logs_2.sqlite")
        FileManager.default.createFile(atPath: codexDB, contents: Data())
        try store.putEvent(tool: "codex", srcKey: "legacy|\(codexRollout)|5", sessionID: "codex-1",
                           project: workspace, ts: 10_000, model: "gpt-5.6", input: 100,
                           sourceKind: "codex_jsonl")
        try store.putEvent(tool: "codex", srcKey: "logs2|9", sessionID: "codex-sql",
                           project: "", ts: 9_000, model: "gpt-5", input: 50,
                           sourceKind: "codex_sqlite")

        // 2. Kimi journal & CLI
        let kimiJournalDir = tmp.path("kimi/events")
        try FileManager.default.createDirectory(atPath: kimiJournalDir, withIntermediateDirectories: true)
        let kimiJournal = "\(kimiJournalDir)/session_k1.jsonl"
        FileManager.default.createFile(atPath: kimiJournal, contents: Data())
        let kimiCLIFile = tmp.path("kimi/cli/k2.jsonl")
        try FileManager.default.createDirectory(
            atPath: (kimiCLIFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: kimiCLIFile, contents: Data())
        try store.putEvent(tool: "kimi", srcKey: "k1|step|1", sessionID: "k1",
                           project: workspace, ts: 8_000, model: "kimi-k3", input: 100)
        try store.putEvent(tool: "kimi", srcKey: "cli|\(kimiCLIFile)|1", sessionID: "k2",
                           project: (kimiCLIFile as NSString).deletingLastPathComponent,
                           ts: 7_000, model: "kimi-k3", input: 100)

        // 3. OpenCode & Hermes (source_scope)
        let opencodeDB = tmp.path("opencode/opencode.db")
        try FileManager.default.createDirectory(
            atPath: (opencodeDB as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: opencodeDB, contents: Data())
        try store.putEvent(tool: "opencode", srcKey: "agg|1", sessionID: "oc-1",
                           project: workspace, ts: 6_000, model: "gpt-5", input: 100,
                           sourceScope: opencodeDB)

        let hermesDB = tmp.path("hermes/state.db")
        try FileManager.default.createDirectory(
            atPath: (hermesDB as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: hermesDB, contents: Data())
        try store.putEvent(tool: "hermes", srcKey: "agg|2", sessionID: "hm-1",
                           project: "每日巡检", ts: 5_000, model: "claude-sonnet-4-5", input: 100,
                           sourceScope: hermesDB)

        // 4. Pi (basename in src_key + cursor)
        let piFile = tmp.path("pi/sessions/webapp/pi-sess-1.jsonl")
        try FileManager.default.createDirectory(
            atPath: (piFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: piFile, contents: Data())
        try store.setScanCursor(tool: "pi", cursor: [piFile: ["m": 1, "s": 1, "i": 1, "d": 1]])
        try store.putEvent(tool: "pi", srcKey: "pi-sess-1.jsonl|m1", sessionID: "pi-1",
                           project: workspace, ts: 4_000, model: "claude-sonnet-4-5", input: 100)

        // 5. DSH (parent dir == session_id in cursor)
        let dshFile = tmp.path("dsh/sessions/ws/dsh-1/session.jsonl.zstd")
        try FileManager.default.createDirectory(
            atPath: (dshFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dshFile, contents: Data())
        try store.setScanCursor(tool: "dsh", cursor: [dshFile: ["m": 1, "s": 1, "i": 1, "d": 1]])
        try store.putEvent(tool: "dsh", srcKey: "dsh-1|0|0", sessionID: "dsh-1",
                           project: workspace, ts: 3_000, model: "deepseek-v4-pro", input: 100)

        // 6. Antigravity (brain/<sid>/.system_generated/logs/transcript.jsonl + workspace map)
        let agRoot = tmp.path("antigravity/brain")
        let agFile = "\(agRoot)/ag-conv-1/.system_generated/logs/transcript.jsonl"
        try FileManager.default.createDirectory(
            atPath: (agFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: agFile, contents: Data())
        let agMap = tmp.path("antigravity_workspaces.json")
        XCTAssertTrue(AntigravityWorkspaceMap.record(conversationID: "ag-conv-1", workspace: workspace, path: agMap))
        try store.putEvent(tool: "antigravity", srcKey: "ag-conv-1|step_1", sessionID: "ag-conv-1",
                           project: "", ts: 2_000, model: "gemini-3-pro", input: 100)

        var roots = ScanRoots(environment: [:])
        roots.codexLogsDB = codexDB
        roots.codexSessions = tmp.path("codex/sessions")
        roots.kimiCodeHome = kimiJournalDir
        roots.kimiCLI = tmp.path("kimi/cli")
        roots.opencodeDB = opencodeDB
        roots.hermesHome = tmp.path("hermes")
        roots.piRoots = [tmp.path("pi/sessions")]
        roots.dshSessions = tmp.path("dsh/sessions")
        roots.antigravityRoots = [agRoot]
        roots.antigravityWorkspaceMap = agMap

        let rows = try store.sessions(rangeKey: "all", roots: roots)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.tool)|\($0.sessionID)", $0) })

        XCTAssertEqual(byID["codex|codex-1"]?.filePath, codexRollout)
        XCTAssertEqual(byID["codex|codex-1"]?.fileExists, true)
        XCTAssertEqual(byID["codex|codex-sql"]?.filePath, codexDB)
        XCTAssertEqual(byID["codex|codex-sql"]?.fileExists, true)

        XCTAssertEqual(byID["kimi|k1"]?.filePath, kimiJournal)
        XCTAssertEqual(byID["kimi|k1"]?.fileExists, true)
        XCTAssertEqual(byID["kimi|k2"]?.filePath, kimiCLIFile)
        XCTAssertEqual(byID["kimi|k2"]?.fileExists, true)

        XCTAssertEqual(byID["opencode|oc-1"]?.filePath, opencodeDB)
        XCTAssertEqual(byID["opencode|oc-1"]?.fileExists, true)

        XCTAssertEqual(byID["hermes|hm-1"]?.filePath, hermesDB)
        XCTAssertEqual(byID["hermes|hm-1"]?.fileExists, true)
        XCTAssertEqual(byID["hermes|hm-1"]?.workspacePath, "")
        XCTAssertEqual(byID["hermes|hm-1"]?.workspaceExists, false)

        XCTAssertEqual(byID["pi|pi-1"]?.filePath, piFile)
        XCTAssertEqual(byID["pi|pi-1"]?.fileExists, true)

        XCTAssertEqual(byID["dsh|dsh-1"]?.filePath, dshFile)
        XCTAssertEqual(byID["dsh|dsh-1"]?.fileExists, true)

        XCTAssertEqual(byID["antigravity|ag-conv-1"]?.filePath, agFile)
        XCTAssertEqual(byID["antigravity|ag-conv-1"]?.fileExists, true)
        XCTAssertEqual(realPath(byID["antigravity|ag-conv-1"]?.workspacePath ?? ""), realPath(workspace))
        XCTAssertEqual(byID["antigravity|ag-conv-1"]?.workspaceExists, true)
    }
}
