//
//  AntigravityScannerTests.swift
//  TokenTrackerCoreTests
//
//  覆盖 Antigravity 本地 transcript.jsonl 扫描、多端目录、增量字节游标、
//  会话记录（标题 / 详情 / 列表）、活动与 Skill 推导、以及可选 hooks.json 工作区映射。
//

import XCTest
@testable import TokenTrackerCore

final class AntigravityScannerTests: XCTestCase {
    private func transcriptPath(_ tmp: TempDir, _ root: String, _ conversationID: String,
                                filename: String = "transcript.jsonl") -> String {
        tmp.path(root, conversationID, ".system_generated", "logs", filename)
    }

    func testScansMultipleRootsIgnoresTranscriptFullAndCountsNonOverlappingTokens() throws {
        let tmp = try TempDir()
        writeJSONL(transcriptPath(tmp, "app-brain", "conv-app"), [
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE",
             "created_at": "2026-08-25T01:00:00Z",
             "content": "<USER_REQUEST>\n实现 Antigravity 记录\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nnow\n</ADDITIONAL_METADATA>"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T01:00:05Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 15289, "cache_read_tokens": 0, "output_tokens": 796],
            ["step_index": 5, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T01:00:30Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 2449, "cache_read_tokens": 15290, "output_tokens": 374],
        ])
        // transcript_full.jsonl 必须被忽略，防止重复计数
        writeJSONL(transcriptPath(tmp, "app-brain", "conv-app", filename: "transcript_full.jsonl"), [
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T01:00:05Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 999999, "cache_read_tokens": 999999, "output_tokens": 999999],
        ])
        writeJSONL(transcriptPath(tmp, "cli-brain", "conv-cli"), [
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE",
             "created_at": "2026-08-25T02:00:00Z", "content": "CLI 会话标题"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T02:00:02Z", "model": "claude-sonnet-4-5",
             "input_tokens": 1000, "cache_read_tokens": 2000, "cache_write_tokens": 500, "output_tokens": 100],
        ])

        let prices = PriceTable(versions: [
            PriceVersion(id: "test:anthropic:claude-sonnet-4-5", provider: "anthropic",
                         model: "claude-sonnet-4-5", effectiveAtMs: 0, fetchedAtMs: 0,
                         sourceURL: "fixture://prices",
                         rates: PriceRate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ])
        let scanner = AntigravityScanner(
            roots: [tmp.path("app-brain"), tmp.path("cli-brain"), tmp.path("missing-ide-brain")],
            workspaceMapPath: tmp.path("missing_workspaces.json"))
        XCTAssertTrue(scanner.detect())

        let store = try tmp.store()
        let outcome = try scanner.scan(store, prices, full: false)
        XCTAssertEqual(outcome.files, 2)
        XCTAssertEqual(outcome.added, 3)
        XCTAssertEqual(outcome.updated, 0)

        let (toolRows, total, _) = try store.stats(rangeKey: "all")
        XCTAssertEqual(toolRows.count, 1)
        XCTAssertEqual(toolRows[0].tool, "antigravity")
        XCTAssertEqual(toolRows[0].sessions, 2)
        XCTAssertEqual(total.input, 15289 + 2449 + 1000)
        XCTAssertEqual(total.cacheRead, 0 + 15290 + 2000)
        XCTAssertEqual(total.cacheWrite, 500)
        XCTAssertEqual(total.output, 796 + 374 + 100)
        XCTAssertEqual(total.unpriced, 2) // 两条 gemini-4-neon-xhigh 未匹配价格，保留 Token 且不估价
        // claude-sonnet-4-5: (1000*3 + 100*15 + 2000*0.3 + 500*3.75) / 1e6 = 0.006975
        XCTAssertEqual(total.cost, 0.006975, accuracy: 1e-6)

        // 幂等重扫不重复写入
        let second = try scanner.scan(store, prices, full: false)
        XCTAssertEqual(second.files, 0)
        XCTAssertEqual(second.added, 0)
    }

    func testIncrementalByteOffsetMonotonicUpdateAndFirstTitlePreservation() throws {
        let tmp = try TempDir()
        let path = transcriptPath(tmp, "brain", "conv-stream")
        writeJSONL(path, [
            ["step_index": 0, "type": "USER_INPUT", "created_at": "2026-08-25T01:00:00Z",
             "content": "<USER_REQUEST>\n首个问题标题\n</USER_REQUEST>"],
            ["step_index": 1, "type": "PLANNER_RESPONSE", "status": "RUNNING",
             "created_at": "2026-08-25T01:00:05Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 1000, "cache_read_tokens": 0, "output_tokens": 50],
        ])

        let store = try tmp.store()
        let scanner = AntigravityScanner(roots: [tmp.path("brain")],
                                         workspaceMapPath: tmp.path("workspaces.json"))
        let first = try scanner.scan(store, .default, full: false)
        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(first.updated, 0)

        // 增量追加同一步最终计数 + 后续用户输入 + 新一步
        let extraLines: [[String: Any]] = [
            ["step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T01:00:05Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 1000, "cache_read_tokens": 0, "output_tokens": 220],
            ["step_index": 2, "type": "USER_INPUT", "created_at": "2026-08-25T01:01:00Z",
             "content": "<USER_REQUEST>\n第二轮追问不应覆盖首条标题\n</USER_REQUEST>"],
            ["step_index": 3, "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T01:01:05Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 300, "cache_read_tokens": 1220, "output_tokens": 80],
        ]
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        for obj in extraLines {
            let data = try JSONSerialization.data(withJSONObject: obj)
            handle.write(data)
            handle.write(Data("\n".utf8))
        }

        let second = try scanner.scan(store, .default, full: false)
        XCTAssertEqual(second.files, 1)
        XCTAssertEqual(second.added, 1)
        XCTAssertEqual(second.updated, 1)

        let sessions = try store.sessions(rangeKey: "all", tool: "antigravity")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, "conv-stream")
        XCTAssertEqual(sessions[0].title, "首个问题标题")
        XCTAssertEqual(sessions[0].stats.output, 300) // 220 + 80
        XCTAssertEqual(sessions[0].stats.input, 1300)
        XCTAssertEqual(sessions[0].stats.cacheRead, 1220)
        XCTAssertEqual(sessions[0].stats.unpriced, 2)
    }

    func testRecordsExactToolsDerivedSkillsAndSubagentActivitiesAndSessionDetail() throws {
        let tmp = try TempDir()
        writeJSONL(transcriptPath(tmp, "brain", "conv-act"), [
            ["step_index": 0, "type": "USER_INPUT", "created_at": "2026-08-25T01:00:00Z",
             "content": "<USER_REQUEST>\n排查构建与技能加载\n</USER_REQUEST>"],
            ["step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T01:00:05Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 500, "cache_read_tokens": 0, "output_tokens": 120,
             "tool_calls": [
                ["name": "run_command", "args": ["CommandLine": "swift test"]],
                ["name": "read_file", "args": ["Path": "\"/Users/fixture/.agents/skills/tokentracker-release/SKILL.md\""]],
                ["name": "invoke_subagent", "args": ["TypeName": "research", "Role": "Codebase Researcher"]],
             ]],
        ])
        let store = try tmp.store()
        let scanner = AntigravityScanner(roots: [tmp.path("brain")],
                                         workspaceMapPath: tmp.path("workspaces.json"))
        let outcome = try scanner.scan(store, .default, full: false)
        // 2 个 exact 工具 + 1 个 derived skill + 1 个 exact agent = 4
        XCTAssertEqual(outcome.activityAdded, 4)

        let tools = try store.activitySummary(rangeKey: "all", agent: "antigravity", group: "tool", confidence: "exact")
        XCTAssertEqual(Set(tools.map(\.name)), ["run_command", "read_file"])

        let crossAgentTools = try store.activitySummary(rangeKey: "all", agent: nil, group: "tool", confidence: "exact")
        XCTAssertEqual(Set(crossAgentTools.map(\.name)), ["shell", "file.read"])

        let skills = try store.activitySummary(rangeKey: "all", agent: "antigravity", group: "skill", confidence: "derived")
        XCTAssertEqual(skills.map(\.name), ["tokentracker-release"])
        XCTAssertEqual(try store.activitySummary(rangeKey: "all", agent: "antigravity", group: "skill", confidence: "exact"), [])

        let agents = try store.activityTimeline(agent: "antigravity", kind: .agent)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].rawName, "invoke_subagent")
        XCTAssertEqual(agents[0].eventLayer, .lifecycle)

        let detail = try store.sessionDetail(tool: "antigravity", sessionID: "conv-act")
        XCTAssertEqual(detail.models.count, 1)
        XCTAssertEqual(detail.models[0].model, "gemini-4-neon-xhigh")
        XCTAssertEqual(detail.activity.count, 4)
        XCTAssertEqual(activityCapability(agent: "antigravity", category: "tools"), .exact)
        XCTAssertEqual(activityCapability(agent: "antigravity", category: "skills"), .derived)
        XCTAssertEqual(activityCapability(agent: "antigravity", category: "agents"), .exact)
    }

    func testWorkspaceHookMappingAndBackfillForPreviouslyScannedSessions() throws {
        let tmp = try TempDir()
        let repo = tmp.path("MyWorkspace")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let mapPath = tmp.path("antigravity_workspaces.json")
        writeJSONL(transcriptPath(tmp, "brain", "conv-ws"), [
            ["step_index": 0, "type": "USER_INPUT", "created_at": "2026-08-25T01:00:00Z",
             "content": "<USER_REQUEST>\n归属测试\n</USER_REQUEST>"],
            ["step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-25T01:00:05Z", "model": "gemini-4-neon-xhigh",
             "input_tokens": 800, "cache_read_tokens": 200, "output_tokens": 100],
        ])

        let store = try tmp.store()
        let scanner = AntigravityScanner(roots: [tmp.path("brain")], workspaceMapPath: mapPath)

        // 先在未配置 Hook 时扫描：归入未归属，但 Token 与会话记录都完整
        _ = try scanner.scan(store, .default, full: false)
        var sessions = try store.sessions(rangeKey: "all", tool: "antigravity")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].project, "")
        var projects = try store.projectSummaries(UsageQuery())
        XCTAssertEqual(projects.map(\.id), ["unassigned"])

        // 随后 Hook 收到 SessionStart / Stop 负载（含敏感提示词，不得落盘）
        let hookPayload = Data("""
        {
          "conversationId": "conv-ws",
          "workspacePaths": ["\(repo)"],
          "cwd": "/fallback/ignored",
          "lastUserInput": "SECRET-PROMPT-MUST-NOT-PERSIST",
          "hookEventName": "SessionStart"
        }
        """.utf8)
        XCTAssertTrue(AntigravityWorkspaceMap.recordHookPayload(hookPayload, path: mapPath, nowMs: 1_787_619_700_000))
        let persistedText = try String(contentsOfFile: mapPath, encoding: .utf8)
        XCTAssertFalse(persistedText.contains("SECRET-PROMPT-MUST-NOT-PERSIST"))

        // 下一次扫描（即使 transcript.jsonl 本身未变）自动回填项目路径与归属
        let rescan = try scanner.scan(store, .default, full: false)
        XCTAssertEqual(rescan.files, 0)

        let expectedRepo = URL(fileURLWithPath: repo).standardizedFileURL.resolvingSymlinksInPath().path
        var roots = ScanRoots(environment: [:])
        roots.antigravityRoots = [tmp.path("brain")]
        roots.antigravityWorkspaceMap = mapPath
        sessions = try store.sessions(rangeKey: "all", tool: "antigravity", roots: roots)
        XCTAssertEqual(sessions[0].project, expectedRepo)
        XCTAssertEqual(sessions[0].workspacePath, expectedRepo)
        XCTAssertTrue(sessions[0].workspaceExists)
        XCTAssertTrue(sessions[0].fileExists)
        XCTAssertTrue(sessions[0].filePath.hasSuffix("/conv-ws/.system_generated/logs/transcript.jsonl"))
        let detail = try store.sessionDetail(tool: "antigravity", sessionID: "conv-ws", roots: roots)
        XCTAssertEqual(detail.project, expectedRepo)
        XCTAssertEqual(detail.workspacePath, expectedRepo)
        XCTAssertTrue(detail.workspaceExists)
        XCTAssertTrue(detail.fileExists)
        XCTAssertTrue(detail.filePath.hasSuffix("/conv-ws/.system_generated/logs/transcript.jsonl"))
        projects = try store.projectSummaries(UsageQuery())
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "MyWorkspace")
        XCTAssertEqual(projects[0].totals.tokens, 1100)
    }

    func testHookPayloadValidationAndCwdFallback() throws {
        let tmp = try TempDir()
        let mapPath = tmp.path("map.json")
        // workspacePaths 缺失时回退 cwd
        let fallback = Data(#"{"conversationId":"conv-cwd","cwd":"/tmp/demo-proj"}"#.utf8)
        XCTAssertTrue(AntigravityWorkspaceMap.recordHookPayload(fallback, path: mapPath))
        let loaded = AntigravityWorkspaceMap.load(path: mapPath)
        XCTAssertEqual(loaded["conv-cwd"], URL(fileURLWithPath: "/tmp/demo-proj").resolvingSymlinksInPath().path)

        // 相对路径、路径穿越 conversationId、空字段均拒绝
        XCTAssertFalse(AntigravityWorkspaceMap.recordHookPayload(
            Data(#"{"conversationId":"conv-rel","cwd":"relative/path"}"#.utf8), path: mapPath))
        XCTAssertFalse(AntigravityWorkspaceMap.recordHookPayload(
            Data(#"{"conversationId":"../escape","cwd":"/tmp/ok"}"#.utf8), path: mapPath))
        XCTAssertFalse(AntigravityWorkspaceMap.recordHookPayload(Data("not json".utf8), path: mapPath))
    }

    func testHookConfigurationPreviewApplyBackupAndRemovalPreservesOtherHooks() throws {
        let tmp = try TempDir()
        let hooksPath = tmp.path("config", "hooks.json")
        try FileManager.default.createDirectory(atPath: tmp.path("config"), withIntermediateDirectories: true)
        let original = Data(#"{"custom-lint":{"PostToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"./lint.sh"}]}]}}"#.utf8)
        try original.write(to: URL(fileURLWithPath: hooksPath))

        XCTAssertFalse(AntigravityHookConfiguration.isInstalled(path: hooksPath, channel: "development"))
        let preview = try AntigravityHookConfiguration.preview(
            path: hooksPath,
            helper: "/tmp/path with 'quotes'/TokenTrackerHook",
            channel: "development",
            installing: true)
        XCTAssertEqual(FileManager.default.contents(atPath: hooksPath), original, "预览不得提前写入")

        try preview.apply()
        XCTAssertTrue(AntigravityHookConfiguration.isInstalled(path: hooksPath, channel: "development"))
        XCTAssertFalse(AntigravityHookConfiguration.isInstalled(path: hooksPath, channel: "production"))

        // 幂等重复安装
        let second = try AntigravityHookConfiguration.preview(
            path: hooksPath,
            helper: "/tmp/path with 'quotes'/TokenTrackerHook",
            channel: "development",
            installing: true)
        XCTAssertEqual(second.original, second.proposed)

        // 保留其他用户的自定义 Hook
        let installedObj = try XCTUnwrap(JSONSerialization.jsonObject(with: second.proposed) as? [String: Any])
        XCTAssertNotNil(installedObj["custom-lint"])
        let ourHook = try XCTUnwrap(installedObj["tokentracker-workspace-dev"] as? [String: Any])
        XCTAssertEqual((ourHook["SessionStart"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((ourHook["Stop"] as? [[String: Any]])?.count, 1)

        // 移除后原其他 Hook 完好保留，且陈旧预览被拒绝
        let removal = try AntigravityHookConfiguration.preview(
            path: hooksPath, helper: "/tmp/helper", channel: "development", installing: false)
        try removal.apply()
        XCTAssertFalse(AntigravityHookConfiguration.isInstalled(path: hooksPath, channel: "development"))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: hooksPath))) as? NSDictionary)
        XCTAssertEqual(restored, try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary))
        XCTAssertThrowsError(try preview.apply(), "文件已变化时旧预览不能覆盖")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tmp.path("config"))
            .contains { $0.contains("tokentracker-backup") })
    }
}
