import Foundation

public struct TaskHookConfiguration {
    public let path: String
    public let original: Data?
    public let proposed: Data
    public var text: String { String(data: proposed, encoding: .utf8) ?? "" }
    public static let marker = "TokenTracker task reminders v1"

    public static func isInstalled(path: String, channel: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let signature = " # " + marker + " [" + channel + "]"
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String)?.hasSuffix(signature) == true
                }
            }
        }
    }

    /// A preflight, not a claim that upstream trust or managed policy permits hooks.
    public static func blockingReason(provider: TaskProvider, root: String) -> String? {
        if provider == .claude {
            guard let data = FileManager.default.contents(atPath: root + "/settings.json"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if object["disableAllHooks"] as? Bool == true { return "当前配置已禁用 Hooks，请先在原工具确认设置" }
            if object["allowManagedHooksOnly"] as? Bool == true { return "当前配置仅允许受管理的 Hooks" }
        } else if let text = try? String(contentsOfFile: root + "/config.toml", encoding: .utf8) {
            var inFeatures = false
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inFeatures = line == "[features]" }
                let key = inFeatures ? "hooks" : "features.hooks"
                if line.range(of: "^" + NSRegularExpression.escapedPattern(for: key)
                              + "\\s*=\\s*false\\s*$", options: .regularExpression) != nil {
                    return "当前配置已禁用 Hooks，请先在原工具确认设置"
                }
            }
        }
        return nil
    }

    public static func preview(provider: TaskProvider, path: String, helper: String,
                               channel: String, installing: Bool) throws -> Self {
        let original = FileManager.default.contents(atPath: path)
        var root: [String: Any] = [:]
        if let original {
            guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw TaskBridgeError.invalidMessage }
            root = parsed
        }
        if let value = root["hooks"], !(value is [String: Any]) { throw TaskBridgeError.invalidMessage }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let signature = " # " + marker + " [" + channel + "]"
        for key in Array(hooks.keys) {
            guard let groups = hooks[key] as? [[String: Any]] else { throw TaskBridgeError.invalidMessage }
            let remaining = groups.compactMap { group -> [String: Any]? in
                var group = group
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let kept = handlers.filter { ($0["type"] as? String) != "command"
                    || ($0["command"] as? String)?.hasSuffix(signature) != true }
                if kept.isEmpty { return nil }
                group["hooks"] = kept; return group
            }
            if remaining.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = remaining }
        }
        if installing {
            let command = Resume.shlexQuote(helper) + " " + provider.rawValue + " " + channel + signature
            var events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
            events += provider == .codex ? ["Interrupt"] : ["PostToolUseFailure", "PermissionDenied", "Notification"]
            for event in events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                var group: [String: Any] = ["hooks": [["type": "command", "command": command,
                    "timeout": event == "PermissionRequest" ? 130 : (event == "SessionEnd" || event == "Interrupt" ? 1 : 3)]]]
                if event == "Notification" { group["matcher"] = "permission_prompt" }
                groups.append(group); hooks[event] = groups
            }
        }
        root["hooks"] = hooks
        return Self(path: path, original: original,
                    proposed: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]))
    }
    public func apply() throws {
        guard FileManager.default.contents(atPath: path) == original else { throw TaskBridgeError.invalidMessage }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original {
            let backup = path + ".tokentracker-backup-" + UUID().uuidString
            try original.write(to: URL(fileURLWithPath: backup), options: .atomic)
            chmod(backup, 0o600)
        }
        try proposed.write(to: url, options: .atomic)
        chmod(path, 0o600)
    }
}
