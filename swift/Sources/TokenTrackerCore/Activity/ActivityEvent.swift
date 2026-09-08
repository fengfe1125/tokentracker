import Foundation

public struct ActivityEvent: Equatable, Sendable {
    public var agent: String
    public var sessionID: String = ""
    public var turnID: String = ""
    public var rawName: String
    public var canonicalName: String
    public var namespace: String = "built-in"
    public var callID: String = ""
    public var parentCallID: String = ""
    public var startedAt: Int64?
    public var endedAt: Int64?
    public var durationMs: Int64?
    public var status: String = "unknown"
    public var sourceKind: String = ""
    public var confidence: String = "exact"
    public var skillName: String = ""
    public var skillConfidence: String = ""
    public var srcKey: String
}

public enum ActivityNormalizer {
    public static let parserVersion = 1

    public static func canonicalToolName(_ raw: String) -> String {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = [
            "bash": "shell", "shell": "shell", "execute_command": "shell", "exec_command": "shell",
            "read": "file.read", "read_file": "file.read", "write": "file.write",
            "write_file": "file.write", "edit": "file.edit", "apply_patch": "file.edit",
            "glob": "file.search", "grep": "file.search", "search": "web.search",
            "web_search": "web.search", "skill": "skill.activate", "skill_view": "skill.activate",
        ]
        if let value = names[low] { return value }
        if low.hasPrefix("mcp__") {
            return "mcp." + String(low.dropFirst(5)).replacingOccurrences(of: "__", with: ".")
        }
        return low.replacingOccurrences(of: " ", with: "_")
    }

    public static func namespace(_ raw: String) -> String {
        let low = raw.lowercased()
        if low.hasPrefix("mcp__") {
            return String(low.dropFirst(5).split(separator: "_").first ?? "mcp")
        }
        return "built-in"
    }

    public static func status(_ value: Any?) -> String {
        let low = String(describing: value ?? "").lowercased()
        if ["denied", "rejected", "blocked"].contains(where: low.contains) { return "denied" }
        if ["error", "failed", "failure"].contains(where: low.contains) { return "error" }
        if ["success", "completed", "complete", "done", "ok"].contains(where: low.contains) { return "success" }
        return "unknown"
    }

    public static func skill(rawName: String, arguments: Any?, allowPath: Bool = false)
        -> (name: String, confidence: String) {
        var object = arguments
        if let text = arguments as? String,
           let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) { object = parsed }
        if ["skill", "skill_view"].contains(rawName.lowercased()),
           let dict = object as? [String: Any] {
            for key in ["skill", "name", "skill_name"] {
                if let value = dict[key] as? String, !value.isEmpty { return (value, "exact") }
            }
        }
        guard allowPath else { return ("", "") }
        let text: String
        if let value = arguments as? String { text = value }
        else if let value = arguments,
                JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value),
                let encoded = String(data: data, encoding: .utf8) { text = encoded }
        else { text = "" }
        let pattern = #"(?:^|[/\\])([^/\\]+)[/\\]SKILL\.md(?:$|[\s'\"])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return ("", "") }
        return (String(text[range]), "derived")
    }

    public static func inferredCodexTools(_ script: String) -> [String] {
        let pattern = #"(?:await\s+)?tools\.([A-Za-z_$][\w$]*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let blocked: Set<String> = ["map", "filter", "reduce", "foreach", "find", "some", "every", "sort"]
        return regex.matches(in: script, range: NSRange(script.startIndex..., in: script)).compactMap {
            guard let range = Range($0.range(at: 1), in: script) else { return nil }
            let name = String(script[range])
            return blocked.contains(name.lowercased()) ? nil : name
        }
    }
}

public let activityCapabilities: [String: [String: String]] = [
    "claude": ["tools": "exact", "skills": "exact"],
    "kimi": ["tools": "exact", "skills": "exact"],
    "dsh": ["tools": "exact", "skills": "exact"],
    "opencode": ["tools": "exact", "skills": "exact"],
    "hermes": ["tools": "exact", "skills": "exact"],
    "pi": ["tools": "exact", "skills": "unknown"],
    "codex": ["tools": "exact+derived", "skills": "derived"],
]

public func activityNeedsBackfill(_ cursor: [String: Any]) -> Bool {
    (cursor["activity_parser_version"] as? NSNumber)?.intValue != ActivityNormalizer.parserVersion
}

public func markActivityCurrent(_ cursor: inout [String: Any]) {
    cursor["activity_parser_version"] = ActivityNormalizer.parserVersion
}

extension UsageStore {
    @discardableResult
    public func recordActivity(agent: String, srcKey: String, rawName: String,
                               sessionID: String = "", turnID: String = "",
                               callID: String = "", parentCallID: String = "",
                               startedAt: Int64? = nil, endedAt: Int64? = nil,
                               durationMs: Int64? = nil, status: String = "unknown",
                               sourceKind: String = "", confidence: String = "exact",
                               arguments: Any? = nil, allowSkillPath: Bool = false)
        throws -> (added: Int, updated: Int) {
        let skill = ActivityNormalizer.skill(rawName: rawName, arguments: arguments,
                                             allowPath: allowSkillPath)
        return try putActivityEvent(ActivityEvent(
            agent: agent, sessionID: sessionID, turnID: turnID, rawName: rawName,
            canonicalName: ActivityNormalizer.canonicalToolName(rawName),
            namespace: ActivityNormalizer.namespace(rawName), callID: callID,
            parentCallID: parentCallID, startedAt: startedAt, endedAt: endedAt,
            durationMs: durationMs, status: status, sourceKind: sourceKind,
            confidence: confidence, skillName: skill.name,
            skillConfidence: skill.confidence, srcKey: srcKey))
    }
}
