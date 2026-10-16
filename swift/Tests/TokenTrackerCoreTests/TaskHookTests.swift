import XCTest
import Darwin
@testable import TokenTrackerCore

final class TaskHookTests: XCTestCase {
    func testDesktopSourceRequiresEngineContextAndInnerCLIIsNotDesktop() {
        XCTAssertEqual(TaskClientSource.launchMode(provider: .codex, arguments:
            ["codex", "-c", "fixture=true", "app-server", "--analytics-default-enabled"]), "app-server")
        XCTAssertEqual(TaskClientSource.launchMode(provider: .codex, arguments:
            ["codex", "--config=fixture=true", "exec", "app-server"]), "exec")
        XCTAssertEqual(TaskClientSource.launchMode(provider: .codex, arguments:
            ["codex", "-c", "app-server"]), "interactive")
        XCTAssertNil(TaskClientSource.launchMode(provider: .codex, arguments:
            ["codex", "--unknown-option", "app-server"]))
        XCTAssertEqual(TaskClientSource.launchMode(provider: .claude, arguments:
            ["claude", "--permission-prompt-tool=stdio", "--input-format", "stream-json", "--output-format", "stream-json"]), "desktop-stream")
        XCTAssertEqual(TaskClientSource.launchMode(provider: .claude, arguments: ["claude"]), "interactive")
        XCTAssertNil(TaskClientSource.launchMode(provider: .claude, arguments: ["claude", "--print=fixture"]))
        let home = "/Users/fixture"
        let claudePath = home + "/Library/Application Support/Claude/claude-code/2.1.295/hash/claude.app/Contents/MacOS/claude"
        let desktop = TaskClientSource.identify(provider: .claude, enginePath: claudePath, mode: "desktop-stream",
            entrypoint: "claude-desktop", host: "com.anthropic.claudefordesktop", configurationRoot: "/fixture/.claude", home: home)
        XCTAssertEqual(desktop.client, .claudeDesktop)
        XCTAssertEqual(desktop.engineVersion, "2.1.295")
        XCTAssertEqual(desktop.confidence, .launchContext)
        let inner = TaskClientSource.identify(provider: .claude, enginePath: "/opt/homebrew/bin/claude", mode: "interactive",
            entrypoint: "cli", host: "com.anthropic.claudefordesktop", configurationRoot: nil, home: home)
        XCTAssertEqual(inner.client, .claudeCLI)
        let inherited = TaskClientSource.identify(provider: .claude, enginePath: "/opt/homebrew/bin/claude", mode: "interactive",
            entrypoint: "claude-desktop", host: "com.anthropic.claudefordesktop", configurationRoot: nil, home: home)
        XCTAssertEqual(inherited.client, .unknown)
        let codex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        XCTAssertEqual(TaskClientSource.identify(provider: .codex, enginePath: codex, mode: "interactive",
            entrypoint: nil, host: "com.openai.codex", configurationRoot: nil, home: home).client, .codexCLI)
        XCTAssertEqual(TaskClientSource.identify(provider: .codex, enginePath: codex, mode: "app-server",
            entrypoint: nil, host: "com.openai.codex", configurationRoot: nil, home: home).client, .codexDesktop)
        XCTAssertEqual(TaskClientSource.identify(provider: .codex, enginePath: "/fixture/app-server-daemon/bin/codex", mode: "app-server",
            entrypoint: nil, host: nil, configurationRoot: nil, home: home).client, .unknown)
        XCTAssertEqual(TaskClientSource.identify(provider: .codex, enginePath: nil, mode: nil,
            entrypoint: nil, host: "com.openai.codex", configurationRoot: nil, home: home).location, .unknown)
    }

    func testDesktopRootIgnoresTrackerShellEnvironmentAndRequiresConfirmation() throws {
        let env = ["CODEX_HOME": "/temporary/cli", "CLAUDE_CONFIG_DIR": "/temporary/claude"]
        let desktop = try XCTUnwrap(TaskHookConfigurationRoot.resolve(client: .codexDesktop,
            home: "/fixture", environment: env, exists: { _ in true }))
        XCTAssertEqual(desktop.path, "/fixture/.codex"); XCTAssertFalse(desktop.confirmed)
        XCTAssertEqual(TaskHookConfigurationRoot.resolve(client: .claudeDesktop,
            home: "/fixture", environment: env, exists: { _ in true })?.path, "/fixture/.claude")
        XCTAssertEqual(TaskHookConfigurationRoot.resolve(client: .codexCLI,
            home: "/fixture", environment: env, exists: { _ in true })?.path, "/temporary/cli")
        let observed = TaskHookConfigurationRoot.resolve(client: .codexDesktop, home: "/fixture",
            environment: env, observed: "/runtime/config", exists: { _ in true })
        XCTAssertEqual(observed?.path, "/runtime/config"); XCTAssertEqual(observed?.confirmed, true)
        let selected = TaskHookConfigurationRoot.resolve(client: .claudeDesktop, home: "/fixture",
            environment: env, selected: "/user/selected", observed: "/runtime/config", exists: { _ in true })
        XCTAssertEqual(selected?.configurationPath(provider: .claude), "/user/selected/settings.json")
        XCTAssertNil(TaskHookConfigurationRoot.resolve(client: .claudeDesktop,
            home: "/fixture", environment: env, exists: { _ in false }))
    }

    func testConfigurationPreflightRespectsExplicitDisableAndSharedInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json")
        try Data(#"{"disableAllHooks":true}"#.utf8).write(to: settings)
        XCTAssertNotNil(TaskHookConfiguration.blockingReason(provider: .claude, root: root.path))
        let config = root.appendingPathComponent("config.toml")
        try Data("[features]\nhooks = false # explicit opt out\n".utf8).write(to: config)
        XCTAssertNotNil(TaskHookConfiguration.blockingReason(provider: .codex, root: root.path))
        try Data("[features]\nhooks = true\n".utf8).write(to: config)
        XCTAssertNil(TaskHookConfiguration.blockingReason(provider: .codex, root: root.path))
        let path = root.appendingPathComponent("hooks.json").path
        XCTAssertFalse(TaskHookConfiguration.isInstalled(path: path, channel: "development"))
        try TaskHookConfiguration.preview(provider: .codex, path: path, helper: "/fixture/helper",
            channel: "development", installing: true).apply()
        XCTAssertTrue(TaskHookConfiguration.isInstalled(path: path, channel: "development"))
        XCTAssertFalse(TaskHookConfiguration.isInstalled(path: path, channel: "production"))
        let second = try TaskHookConfiguration.preview(provider: .codex, path: path, helper: "/fixture/helper",
            channel: "development", installing: true)
        XCTAssertEqual(second.original, second.proposed, "Desktop and CLI sharing a root install exactly one handler")
    }

    func testLegacyHookEventDecodesAsUnknownSource() throws {
        let event = try TaskHookEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"legacy","source":"startup"}"#.utf8), provider: .codex,
                                           sourceApp: "com.openai.codex")
        XCTAssertEqual(event.client, .unknown, "Host bundle and SessionStart source do not establish a desktop client")
        let decoded = try JSONDecoder().decode(TaskHookEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.client, .unknown)
        XCTAssertNil(decoded.source)
    }
    func testNormalizesOnlyLifecycleMetadataAndApprovalArguments() throws {
        let data = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","turn_id":"t","cwd":"/tmp/demo","tool_name":"Bash","tool_input":{"command":"printf secret-fixture"},"prompt":"PRIVATE-PROMPT","last_assistant_message":"PRIVATE-REPLY"}"#.utf8)
        let event = try TaskHookEvent.parse(data, provider: .codex)
        XCTAssertEqual(event.session, "s"); XCTAssertEqual(event.turn, "t")
        XCTAssertTrue(event.requiresReply); XCTAssertTrue(event.arguments!.contains("printf secret-fixture"))
        let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("PRIVATE-PROMPT")); XCTAssertFalse(encoded.contains("PRIVATE-REPLY"))
        let stop = try TaskHookEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"s","agent_id":"child","tool_input":{"command":"private"}}"#.utf8), provider: .claude)
        XCTAssertFalse(stop.isMain); XCTAssertNil(stop.arguments)
        XCTAssertThrowsError(try TaskHookEvent.parse(Data(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s"}"#.utf8), provider: .claude))
        XCTAssertThrowsError(try TaskHookEvent.parse(Data(#"{"hook_event_name":"Unknown","session_id":"s"}"#.utf8), provider: .codex))
    }
    func testDecisionHasOnlyOneShotOfficialFields() throws {
        for decision in [TaskHookDecision.allow, .deny] {
            let object = try JSONSerialization.jsonObject(with: TaskHookReply(id: "id", decision: decision).output()) as! [String: Any]
            let output = object["hookSpecificOutput"] as! [String: Any]
            XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
            let decisionObject = output["decision"] as! [String: String]
            XCTAssertEqual(decisionObject, ["behavior": decision.rawValue])
        }
        XCTAssertTrue(TaskHookReply(id: "id", decision: .pass).output().isEmpty)
    }
    func testConfigRoundTripPreservesOtherHooksAndSettingsAndRejectsStalePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("settings.json").path
        let original = Data(#"{"env":{"TEST":"preserved"},"hooks":{"Stop":[{"matcher":"other","hooks":[{"type":"command","command":"echo existing"}]}]}}"#.utf8)
        try original.write(to: URL(fileURLWithPath: path))
        let preview = try TaskHookConfiguration.preview(provider: .claude, path: path, helper: "/tmp/path with 'quotes'/TokenTrackerHook", channel: "development", installing: true)
        XCTAssertEqual(FileManager.default.contents(atPath: path), original, "Preview must not write")
        try preview.apply()
        let installed = try TaskHookConfiguration.preview(provider: .claude, path: path, helper: "/tmp/path with 'quotes'/TokenTrackerHook", channel: "development", installing: true)
        XCTAssertEqual(installed.proposed, preview.proposed, "Installation is idempotent")
        let object = try JSONSerialization.jsonObject(with: installed.proposed) as! [String: Any]
        let hooks = object["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks["Stop"]?.count, 2)
        let permission = hooks["PermissionRequest"]![0]["hooks"] as! [[String: Any]]
        XCTAssertEqual(permission[0]["timeout"] as? Int, 130)
        let removal = try TaskHookConfiguration.preview(provider: .claude, path: path, helper: "/tmp/helper", channel: "development", installing: false)
        try removal.apply()
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! NSDictionary
        XCTAssertEqual(restored, try JSONSerialization.jsonObject(with: original) as! NSDictionary)
        XCTAssertThrowsError(try preview.apply(), "A preview cannot overwrite a changed file")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("tokentracker-backup") })
    }
    func testSocketFramesAreBoundedAndClosedPeerFails() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }
        fds.forEach(TaskSocket.configure)
        XCTAssertTrue(TaskSocket.sameUser(fds[0]))
        let data = Data("payload".utf8)
        try TaskSocket.send(data, fd: fds[0], deadline: Date().addingTimeInterval(1))
        XCTAssertEqual(try TaskSocket.receive(fds[1], deadline: Date().addingTimeInterval(1)), data)
        var oversized = UInt32(TaskSocket.maximumFrame + 1).bigEndian
        _ = withUnsafeBytes(of: &oversized) { Darwin.write(fds[0], $0.baseAddress!, 4) }
        XCTAssertThrowsError(try TaskSocket.receive(fds[1], deadline: Date().addingTimeInterval(1)))
        XCTAssertThrowsError(try TaskSocket.receive(fds[1], deadline: Date().addingTimeInterval(0.02)))
        shutdown(fds[0], SHUT_RDWR)
        XCTAssertThrowsError(try TaskSocket.receive(fds[1], deadline: Date().addingTimeInterval(1)))
    }
    func testUnsafeDirectoryIsRejected() throws {
        let path = "/tmp/tt-task-unsafe-" + UUID().uuidString
        XCTAssertEqual(mkdir(path, 0o755), 0)
        defer { rmdir(path) }
        XCTAssertThrowsError(try TaskSocket.prepareDirectory(path))
    }
}
