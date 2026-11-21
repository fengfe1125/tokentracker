//
//  AntigravityWorkspaceMap.swift
//  TokenTrackerCore
//
//  Antigravity 可选 hooks.json 工作区映射：
//  只记录 conversationId -> 绝对工作目录路径，不保存提示词、参数或对话正文。
//  写入走 flock 锁 + 原子替换 + 0600 权限，多个并发会话同时触发 Hook 也不会互相覆盖。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum AntigravityWorkspaceMap {
    public static let defaultPath = NSHomeDirectory() + "/.tokentracker/antigravity_workspaces.json"
    private static let maxEntries = 5_000

    private struct Entry: Codable {
        var workspace: String
        var updatedAt: Int64

        enum CodingKeys: String, CodingKey {
            case workspace
            case updatedAt = "updated_at"
        }
    }

    private struct Document: Codable {
        var version: Int = 1
        var conversations: [String: Entry] = [:]
    }

    public static func load(path: String = defaultPath) -> [String: String] {
        let resolved = expandPath(path)
        guard let data = FileManager.default.contents(atPath: resolved),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else {
            return [:]
        }
        var out: [String: String] = [:]
        for (conversationID, entry) in doc.conversations {
            guard isValidConversationID(conversationID),
                  let normalized = normalizeWorkspacePath(entry.workspace) else { continue }
            out[conversationID] = normalized
        }
        return out
    }

    /// 解析 Antigravity Hook 的 stdin JSON（camelCase protojson），仅提取 conversationId 与工作区路径。
    /// 刻意丢弃 lastUserInput、transcriptPath 等其他字段。
    public static func extractMapping(from data: Data) -> (conversationID: String, workspace: String)? {
        guard data.count <= TaskSocket.maximumFrame,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = raw["conversationId"] as? String else {
            return nil
        }
        let conversationID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidConversationID(conversationID) else { return nil }

        var candidate: String?
        if let paths = raw["workspacePaths"] as? [Any] {
            for item in paths {
                if let path = item as? String, let normalized = normalizeWorkspacePath(path) {
                    candidate = normalized
                    break
                }
            }
        }
        if candidate == nil, let cwd = raw["cwd"] as? String {
            candidate = normalizeWorkspacePath(cwd)
        }
        guard let workspace = candidate else { return nil }
        return (conversationID, workspace)
    }

    /// 处理一条 Hook 负载并更新本地工作区映射文件。返回是否写入了有效映射。
    @discardableResult
    public static func recordHookPayload(_ data: Data, path: String = defaultPath,
                                         nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let mapping = extractMapping(from: data) else { return false }
        return record(conversationID: mapping.conversationID,
                      workspace: mapping.workspace,
                      path: path,
                      nowMs: nowMs)
    }

    @discardableResult
    public static func record(conversationID: String, workspace: String,
                              path: String = defaultPath,
                              nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        let trimmedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidConversationID(trimmedID),
              let normalized = normalizeWorkspacePath(workspace) else {
            return false
        }
        let resolvedPath = expandPath(path)
        let dir = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let lockPath = resolvedPath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 {
            flock(fd, LOCK_EX)
        }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }

        var doc: Document
        if let data = FileManager.default.contents(atPath: resolvedPath),
           let decoded = try? JSONDecoder().decode(Document.self, from: data) {
            doc = decoded
        } else {
            doc = Document()
        }

        if let existing = doc.conversations[trimmedID], existing.workspace == normalized {
            return true
        }
        doc.conversations[trimmedID] = Entry(workspace: normalized, updatedAt: nowMs)
        if doc.conversations.count > maxEntries {
            let kept = doc.conversations
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maxEntries)
            doc.conversations = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(doc) else { return false }
        let tempURL = URL(fileURLWithPath: resolvedPath + ".tmp-\(UUID().uuidString)")
        let targetURL = URL(fileURLWithPath: resolvedPath)
        do {
            try encoded.write(to: tempURL, options: .atomic)
            chmod(tempURL.path, 0o600)
            if FileManager.default.fileExists(atPath: resolvedPath) {
                _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: targetURL)
            }
            chmod(resolvedPath, 0o600)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    private static func isValidConversationID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
            && !value.contains("/") && !value.contains("\\")
    }

    private static func normalizeWorkspacePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.utf8.count <= 1024, !trimmed.contains("\0") else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Antigravity 全局 `~/.gemini/config/hooks.json` 配置的预览、备份与原子合并。
/// 与 `TaskHookConfiguration` 保持相同安全边界：不静默改写，保留其他全部 Hook，写前校验原文未变并留备份。
public struct AntigravityHookConfiguration: Sendable {
    public let path: String
    public let original: Data?
    public let proposed: Data
    public var text: String { String(data: proposed, encoding: .utf8) ?? "" }

    public static var defaultPath: String {
        NSHomeDirectory() + "/.gemini/config/hooks.json"
    }

    public static func hookName(channel: String) -> String {
        channel == "development" ? "tokentracker-workspace-dev" : "tokentracker-workspace"
    }

    public static func isInstalled(path: String = defaultPath, channel: String) -> Bool {
        let resolved = expandPath(path)
        guard let data = FileManager.default.contents(atPath: resolved),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[hookName(channel: channel)] as? [String: Any] else {
            return false
        }
        if (entry["enabled"] as? Bool) == false { return false }
        let startHandlers = entry["SessionStart"] as? [[String: Any]] ?? []
        let stopHandlers = entry["Stop"] as? [[String: Any]] ?? []
        func hasCommand(_ list: [[String: Any]]) -> Bool {
            list.contains {
                ($0["type"] as? String ?? "command") == "command"
                    && ($0["command"] as? String)?.contains("antigravity-workspace") == true
            }
        }
        return hasCommand(startHandlers) && hasCommand(stopHandlers)
    }

    public static func preview(path: String = defaultPath, helper: String,
                               channel: String, installing: Bool) throws -> Self {
        let resolved = expandPath(path)
        let original = FileManager.default.contents(atPath: resolved)
        var root: [String: Any] = [:]
        if let original {
            guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw TaskBridgeError.invalidMessage
            }
            root = parsed
        }
        let key = hookName(channel: channel)
        if installing {
            let command = Resume.shlexQuote(helper) + " antigravity-workspace"
            let handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 3,
            ]
            root[key] = [
                "SessionStart": [handler],
                "Stop": [handler],
            ]
        } else {
            root.removeValue(forKey: key)
        }
        let proposed = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return Self(path: resolved, original: original, proposed: proposed)
    }

    public func apply() throws {
        guard FileManager.default.contents(atPath: path) == original else {
            throw TaskBridgeError.invalidMessage
        }
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
