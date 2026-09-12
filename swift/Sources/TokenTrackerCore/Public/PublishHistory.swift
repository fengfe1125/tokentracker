//
//  PublishHistory.swift
//  TokenTrackerCore
//
//  只记录真正发起的公开统计 HTTP 请求。配置校验失败、内容未变化、
//  节流与退避等跳过决定不属于“上传记录”，不会写入这里。
//

import Foundation

public enum PublishTrigger: String, Codable, CaseIterable, Sendable {
    case automatic
    case manual
    case forced
}

public struct PublishAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Double
    public var trigger: PublishTrigger
    public var succeeded: Bool
    public var status: Int
    public var bytes: Int
    public var error: String

    public init(id: UUID = UUID(), timestamp: Double, trigger: PublishTrigger,
                succeeded: Bool, status: Int, bytes: Int, error: String) {
        self.id = id
        self.timestamp = timestamp
        self.trigger = trigger
        self.succeeded = succeeded
        self.status = status
        self.bytes = bytes
        self.error = Self.sanitize(error)
    }

    private static func sanitize(_ text: String) -> String {
        let singleLine = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        let compact = String(singleLine).split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(compact.prefix(240))
    }
}

public final class PublishHistoryStore: @unchecked Sendable {
    public let path: String
    public let limit: Int
    private let lock = NSLock()

    public init(path: String = NSHomeDirectory() + "/.tokentracker/publish_history.json",
                limit: Int = 50) {
        self.path = path
        self.limit = max(1, limit)
    }

    public func load() -> [PublishAttempt] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    public func append(_ attempt: PublishAttempt) {
        lock.lock(); defer { lock.unlock() }
        var rows = loadUnlocked()
        rows.insert(attempt, at: 0)
        saveUnlocked(Array(rows.prefix(limit)))
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        saveUnlocked([])
    }

    private func loadUnlocked() -> [PublishAttempt] {
        guard let data = FileManager.default.contents(atPath: path),
              let rows = try? JSONDecoder().decode([PublishAttempt].self, from: data)
        else { return [] }
        return Array(rows.prefix(limit))
    }

    private func saveUnlocked(_ rows: [PublishAttempt]) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(rows) else { return }
        let temporary = path + ".\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data) else { return }
        chmod(temporary, 0o600)
        if FileManager.default.fileExists(atPath: path) {
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                       withItemAt: URL(fileURLWithPath: temporary))
        }
        if FileManager.default.fileExists(atPath: temporary) {
            try? FileManager.default.moveItem(atPath: temporary, toPath: path)
        }
        chmod(path, 0o600)
    }
}
