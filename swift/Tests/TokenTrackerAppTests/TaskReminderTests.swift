import XCTest
import Darwin
import TokenTrackerCore
@testable import TokenTrackerApp

@MainActor
final class TaskReminderTests: XCTestCase {
    private func event(_ name: String, session: String = "session", turn: String = "turn", agent: String = "",
                       tool: String = "Bash", call: String = "") throws -> TaskHookEvent {
        try TaskHookEvent.parse(JSONSerialization.data(withJSONObject: ["hook_event_name": name,
            "session_id": session, "turn_id": turn, "cwd": "/private/tmp/demo-project", "agent_id": agent,
            "tool_name": tool, "tool_use_id": call, "notification_type": "permission_prompt",
            "tool_input": ["command": "printf PRIVATE-ARGUMENTS"]]), provider: .claude)
    }
    private func model(_ root: URL) -> (TaskReminderModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let prefs = TaskReminderPreferences(defaults: defaults)
        prefs.enabled = true; prefs.claude = true
        return (TaskReminderModel(preferences: prefs, history: root.appendingPathComponent("history.json")), defaults)
    }
    func testDefaultOffAndLocalPreferences() {
        let prefs = TaskReminderPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertFalse(prefs.enabled); XCTAssertFalse(prefs.system); XCTAssertFalse(prefs.sound)
        XCTAssertFalse(prefs.accepts(.codex)); XCTAssertFalse(prefs.accepts(.claude))
    }
    func testClientObservationsAreIndependentAndHistoryRetainsOnlySafeSourceMetadata() throws {
        let root = URL(fileURLWithPath: "/tmp/tt-tasks-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = model(root)
        var desktop = try event("Stop", session: "desktop")
        desktop.source = TaskClientSource(client: .claudeDesktop, location: .local, confidence: .launchContext,
            configurationRoot: "/PRIVATE-CONFIG-PATH", engineVersion: "fixture-version")
        model.receive(desktop)
        XCTAssertNotNil(model.observedClients[.claudeDesktop])
        XCTAssertNil(model.observedClients[.claudeCLI])
        XCTAssertEqual(model.reminders[0].client, .claudeDesktop)
        var cli = try event("Stop", session: "cli")
        cli.source = TaskClientSource(client: .claudeCLI, location: .local, confidence: .launchContext)
        model.receive(cli)
        XCTAssertEqual(model.observedClients.count, 2)
        let data = try Data(contentsOf: root.appendingPathComponent("history.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-CONFIG-PATH"))
        let restored = TaskReminderModel(preferences: model.preferences, history: root.appendingPathComponent("history.json"))
        XCTAssertTrue(restored.observedClients.isEmpty, "History is not evidence that a client is currently connected")
        XCTAssertEqual(restored.reminders.last?.client, .claudeDesktop)
        var oldRows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        oldRows[0].removeValue(forKey: "client"); oldRows[0].removeValue(forKey: "engineVersion")
        let legacy = try JSONDecoder().decode([TaskReminder].self, from: JSONSerialization.data(withJSONObject: oldRows))
        XCTAssertEqual(legacy[0].clientName, TaskClient.unknown.name)
    }
    func testUnifiedNotificationRoutingPreservesRiskAndDoesNotMakeAnApprovalDecision() {
        let router = NotificationRouter()
        var task: String?; var risk: String?
        router.onTask = { task = $0 }; router.onRisk = { risk = $0 }
        router.route(task: "request", risk: nil)
        XCTAssertEqual(task, "request"); XCTAssertNil(risk)
        router.route(task: nil, risk: "existing-risk")
        XCTAssertEqual(risk, "existing-risk")
        router.route(task: nil, risk: nil)
        XCTAssertEqual(task, "request")
    }
    func testDisabledProviderCannotCreateApprovalOrCompletion() throws {
        let root = URL(fileURLWithPath: "/tmp/tt-tasks-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = model(root)
        model.preferences.claude = false
        model.receive(try event("PermissionRequest")); model.receive(try event("Stop"))
        XCTAssertTrue(model.reminders.isEmpty)
    }
    func testDedupeMainTurnsAndAdvisoryApprovalPriority() throws {
        let root = URL(fileURLWithPath: "/tmp/tt-tasks-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = model(root)
        var shown: [String] = []
        model.onPresent = { id, _ in shown.append(id) }
        model.receive(try event("Stop", agent: "child"))
        XCTAssertTrue(model.reminders.isEmpty)
        let stop = try event("Stop")
        model.receive(stop); model.receive(stop); model.receive(try event("Stop"))
        XCTAssertEqual(model.reminders.count, 1)
        model.receive(try event("PermissionRequest"))
        XCTAssertEqual(model.reminders.first?.state, .waiting)
        model.receive(try event("Notification"))
        XCTAssertEqual(model.reminders.count, 2)
        model.receive(try event("Stop", session: "another"))
        XCTAssertEqual(shown.count, 2, "A completion cannot replace a waiting approval")
    }
    func testHistoryOmitsArgumentsAndReloadCannotApprove() throws {
        let root = URL(fileURLWithPath: "/tmp/tt-tasks-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = model(root)
        let request = try event("PermissionRequest")
        model.receive(request)
        XCTAssertNotNil(model.reminders[0].arguments)
        let data = try Data(contentsOf: root.appendingPathComponent("history.json"))
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("PRIVATE-ARGUMENTS"))
        let reloaded = TaskReminderModel(preferences: model.preferences, history: root.appendingPathComponent("history.json"))
        XCTAssertEqual(reloaded.reminders[0].state, .expired); XCTAssertNil(reloaded.reminders[0].arguments)
        reloaded.decide(request.id, .allow)
        XCTAssertEqual(reloaded.reminders[0].state, .expired)
        model.receive(try event("Interrupt"))
        XCTAssertEqual(model.reminders[0].state, .expired); XCTAssertNil(model.reminders[0].arguments)
    }
    func testHistoryRetainsFiftyAndNeverAnnouncesOnReload() throws {
        let root = URL(fileURLWithPath: "/tmp/tt-tasks-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = model(root)
        for index in 0..<55 { model.receive(try event("Stop", turn: String(index))) }
        XCTAssertEqual(model.reminders.count, 50)
        let reloaded = TaskReminderModel(preferences: model.preferences, history: root.appendingPathComponent("history.json"))
        XCTAssertEqual(reloaded.reminders.count, 50); XCTAssertNil(reloaded.presentation)
    }
    func testStartupRemovesExpiredHistoryFromDisk() throws {
        let root = URL(fileURLWithPath: "/tmp/tt-tasks-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (original, _) = model(root)
        original.receive(try event("Stop"))
        let url = root.appendingPathComponent("history.json")
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        rows[0]["at"] = Date().addingTimeInterval(-8 * 86_400).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        let server = TaskHookServer(channel: "test", path: root.appendingPathComponent("events.sock").path)
        let reloaded = TaskReminderModel(preferences: original.preferences, history: url, server: server)
        reloaded.start(); defer { reloaded.stop() }
        XCTAssertTrue(reloaded.reminders.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode([TaskReminder].self, from: Data(contentsOf: url)).count, 0)
    }
    func testChildLifecycleCannotInvalidateParentApprovalAndCyclesSurviveRestart() throws {
        let root = URL(fileURLWithPath: "/tmp/tt-tasks-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = model(root)
        model.receive(try event("PermissionRequest"))
        model.receive(try event("SessionEnd", agent: "child"))
        XCTAssertEqual(model.reminders[0].state, .waiting)
        model.receive(try event("Stop", turn: "finished"))
        let reloaded = TaskReminderModel(preferences: model.preferences, history: root.appendingPathComponent("history.json"))
        let before = reloaded.reminders.count
        reloaded.receive(try event("Stop", turn: "finished"))
        XCTAssertEqual(reloaded.reminders.count, before)
    }
    func testSocketApprovalOnlyOnceAndDisconnectExpires() async throws {
        let path = "/tmp/tt-bridge-test-" + UUID().uuidString + "/events.sock"
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = TaskHookServer(channel: "test", path: path)
        let request = try event("PermissionRequest")
        let received = expectation(description: "Request delivered")
        let expired = expectation(description: "Disconnected request expired")
        server.onEvent = { event in if event.id == request.id { received.fulfill() } }
        server.onExpire = { _ in expired.fulfill() }
        try server.start(); defer { server.stop() }
        let fd = try TaskSocket.connect(path: path)
        try TaskSocket.send(JSONEncoder().encode(request), fd: fd, deadline: Date().addingTimeInterval(1))
        await fulfillment(of: [received], timeout: 2)
        XCTAssertTrue(server.resolve(request.id, decision: .allow))
        XCTAssertFalse(server.resolve(request.id, decision: .deny))
        let reply = try JSONDecoder().decode(TaskHookReply.self, from: TaskSocket.receive(fd, deadline: Date().addingTimeInterval(1)))
        XCTAssertEqual(reply.id, request.id); XCTAssertEqual(reply.decision, .allow)
        Darwin.close(fd)
        // A second server must not unlink the live socket.
        XCTAssertThrowsError(try TaskHookServer(channel: "test", path: path).start())
        let closed = try TaskSocket.connect(path: path)
        try TaskSocket.send(JSONEncoder().encode(try event("PermissionRequest", session: "second")), fd: closed,
                            deadline: Date().addingTimeInterval(1))
        Darwin.close(closed)
        await fulfillment(of: [expired], timeout: 2)
    }
    func testSocketTimeoutAbstainsAndLateDecisionFails() async throws {
        let path = "/tmp/tt-bridge-test-" + UUID().uuidString + "/events.sock"
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        let server = TaskHookServer(channel: "test", path: path, approvalTimeout: 0.04)
        let expired = expectation(description: "Bounded expiry")
        server.onExpire = { _ in expired.fulfill() }
        try server.start(); defer { server.stop() }
        let fd = try TaskSocket.connect(path: path); defer { Darwin.close(fd) }
        let request = try event("PermissionRequest")
        try TaskSocket.send(JSONEncoder().encode(request), fd: fd, deadline: Date().addingTimeInterval(1))
        await fulfillment(of: [expired], timeout: 2)
        let reply = try JSONDecoder().decode(TaskHookReply.self, from: TaskSocket.receive(fd, deadline: Date().addingTimeInterval(1)))
        XCTAssertEqual(reply.decision, .pass)
        XCTAssertFalse(server.resolve(request.id, decision: .allow))
    }
    func testConcurrentRequestsRouteIndependentlyAndShutdownAbstains() async throws {
        let path = "/tmp/tt-bridge-test-" + UUID().uuidString + "/events.sock"
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        let server = TaskHookServer(channel: "test", path: path)
        let delivered = expectation(description: "Three independent requests")
        delivered.expectedFulfillmentCount = 3
        server.onEvent = { _ in delivered.fulfill() }
        try server.start(); defer { server.stop() }
        let requests = try (0..<3).map { try event("PermissionRequest", session: "session-\($0)") }
        var sockets: [Int32] = []
        defer { for fd in sockets { Darwin.close(fd) } }
        for request in requests {
            let fd = try TaskSocket.connect(path: path); sockets.append(fd)
            try TaskSocket.send(JSONEncoder().encode(request), fd: fd, deadline: Date().addingTimeInterval(1))
        }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertTrue(server.resolve(requests[1].id, decision: .deny))
        XCTAssertTrue(server.isPending(requests[0].id)); XCTAssertTrue(server.isPending(requests[2].id))
        server.stop()
        for (index, fd) in sockets.enumerated() {
            let reply = try JSONDecoder().decode(TaskHookReply.self,
                from: TaskSocket.receive(fd, deadline: Date().addingTimeInterval(1)))
            XCTAssertEqual(reply.id, requests[index].id)
            XCTAssertEqual(reply.decision, index == 1 ? .deny : .pass)
            XCTAssertFalse(server.resolve(requests[index].id, decision: .allow))
        }
    }
}
