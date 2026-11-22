import Foundation

public enum TaskProvider: String, Codable, CaseIterable, Sendable {
    case codex, claude, antigravity
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        }
    }
}

/// Transport only. Request arguments must never be encoded into reminder history.
public struct TaskHookEvent: Codable, Sendable {
    public var version = 1
    public var id: String
    public var provider: TaskProvider
    public var event: String
    public var session: String
    public var turn: String
    public var agent: String
    public var at: Date
    public var cwd: String
    public var tool: String
    public var arguments: String?
    public var sourceApp: String?
    public var call: String
    public var failed: Bool
    public var source: TaskClientSource? = nil
    public var client: TaskClient { source?.client ?? .unknown }
    public var requiresReply: Bool { event == "PermissionRequest" }
    public var isMain: Bool { agent.isEmpty }

    public static func parse(_ data: Data, provider: TaskProvider, now: Date = Date(),
                             sourceApp: String? = nil) throws -> Self {
        guard data.count <= TaskSocket.maximumFrame,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw TaskBridgeError.invalidMessage }
        if provider == .antigravity {
            return try parseAntigravity(raw, now: now, sourceApp: sourceApp)
        }
        guard let event = raw["hook_event_name"] as? String,
              ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
               "PermissionDenied", "Stop", "SessionEnd", "Interrupt", "Notification"].contains(event),
              let session = raw["session_id"] as? String, !session.isEmpty, session.utf8.count <= 512
        else { throw TaskBridgeError.invalidMessage }
        func string(_ key: String) -> String { raw[key] as? String ?? "" }
        // Notification is advisory; only permission prompts belong in this feature.
        if event == "Notification", string("notification_type") != "permission_prompt" {
            throw TaskBridgeError.invalidMessage
        }
        var arguments: String?
        if event == "PermissionRequest", let input = raw["tool_input"],
           JSONSerialization.isValidJSONObject(input),
           let encoded = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]) {
            arguments = String(data: encoded, encoding: .utf8)
        }
        return Self(id: UUID().uuidString, provider: provider, event: event, session: session,
                    turn: string("turn_id"), agent: string("agent_id"), at: now, cwd: string("cwd"),
                    tool: string("tool_name"), arguments: arguments, sourceApp: sourceApp,
                    call: string("tool_use_id"), failed: event == "PostToolUseFailure" || event == "PermissionDenied")
    }

    /// Antigravity camelCase protojson hooks（见 hooks.md）。只取会话与生命周期元数据，丢弃提示词与正文。
    private static func parseAntigravity(_ raw: [String: Any], now: Date, sourceApp: String?) throws -> Self {
        guard let rawEvent = (raw["hookEventName"] ?? raw["hook_event_name"]) as? String,
              ["SessionStart", "PreInvocation", "Stop", "SessionEnd", "Interrupt"].contains(rawEvent),
              let session = (raw["conversationId"] ?? raw["session_id"]) as? String,
              !session.isEmpty, session.utf8.count <= 512
        else { throw TaskBridgeError.invalidMessage }

        let normalizedEvent: String
        switch rawEvent {
        case "PreInvocation":
            if let num = raw["invocationNum"] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.intValue > 1 {
                throw TaskBridgeError.invalidMessage
            }
            normalizedEvent = "UserPromptSubmit"
        case "Stop":
            let reason = (raw["terminationReason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            normalizedEvent = reason == "USER_CANCELED" ? "Interrupt" : "Stop"
        default:
            normalizedEvent = rawEvent
        }

        var cwd = (raw["cwd"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cwd.isEmpty, let paths = raw["workspacePaths"] as? [Any] {
            for item in paths {
                if let p = item as? String {
                    let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("/") { cwd = trimmed; break }
                }
            }
        }

        let turn: String
        if let execNum = raw["executionNum"] as? NSNumber, CFGetTypeID(execNum) != CFBooleanGetTypeID() {
            turn = "exec_\(execNum.intValue)"
        } else if let execStr = raw["executionNum"] as? String, !execStr.isEmpty {
            turn = "exec_\(execStr)"
        } else {
            turn = raw["turn_id"] as? String ?? ""
        }

        let agent = (raw["agentId"] ?? raw["agent_id"] ?? raw["parentConversationId"]) as? String ?? ""
        let failed = (raw["terminationReason"] as? String)?.uppercased() == "ERROR"
        return Self(id: UUID().uuidString, provider: .antigravity, event: normalizedEvent, session: session,
                    turn: turn, agent: agent, at: now, cwd: cwd, tool: "", arguments: nil,
                    sourceApp: sourceApp, call: "", failed: failed)
    }
}

public enum TaskHookDecision: String, Codable, Sendable { case allow, deny, pass }
public struct TaskHookReply: Codable, Sendable {
    public let id: String
    public let decision: TaskHookDecision
    public init(id: String, decision: TaskHookDecision) { self.id = id; self.decision = decision }
    public func output() -> Data {
        guard decision != .pass else { return Data() }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
            "decision": ["behavior": decision.rawValue]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

public enum TaskBridgeError: Error { case invalidMessage, disconnected, timeout, unavailable, unsafePath }
