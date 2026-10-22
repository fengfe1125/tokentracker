//
//  SubscriptionAccountStore.swift
//  TokenTrackerCore
//
//  TokenTracker 自有的订阅账号库：自己登录得到的会话与用户添加/导入的 API Key。
//  查询只用这里的账号，不再读取其他软件的配置。
//
//  存储为 ~/.tokentracker/subscription_accounts.json（0600，原子替换）。与发布 Token
//  同一取舍：ad-hoc 签名每次更新都会让钥匙串重新弹窗授权，因此不用钥匙串。
//

import Foundation

public struct StoredSubscriptionAccount: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case oauth, apiKey }
    public enum Origin: String, Codable, Sendable { case login, manual, imported }

    public var id: String
    public var provider: SubscriptionProvider
    public var label: String
    public var kind: Kind
    public var origin: Origin
    /// 导入来源工具名（仅展示，如 "DSH"）。
    public var importedFrom: String?
    var token: String
    var refreshToken: String?
    public var expiresAt: Date?
    var extra: [String: String]
    var accountID: String?
    public var addedAt: Date
    /// 用户指定为菜单栏账号。
    public var menuBar: Bool

    init(provider: SubscriptionProvider, label: String = "", kind: Kind, origin: Origin, importedFrom: String? = nil,
         token: String, refreshToken: String? = nil, expiresAt: Date? = nil, extra: [String: String] = [:],
         accountID: String? = nil, addedAt: Date = Date(), menuBar: Bool = false) {
        self.id = UUID().uuidString.lowercased()
        self.provider = provider
        self.label = label
        self.kind = kind
        self.origin = origin
        self.importedFrom = importedFrom
        self.token = token
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.extra = extra
        self.accountID = accountID.flatMap { $0.isEmpty ? nil : $0 }
        self.addedAt = addedAt
        self.menuBar = menuBar
    }

    var credential: SubscriptionCredential {
        SubscriptionCredential(kind: kind == .apiKey ? .apiKey : .oauth, token: token, expiresAt: expiresAt, extra: extra)
    }

    /// 同一供应商账号：账号 ID 相同，或凭据相同。
    func sameAccount(as other: Self) -> Bool {
        guard provider == other.provider else { return false }
        if let a = accountID, let b = other.accountID { return a == b }
        return token == other.token
    }
}

public final class SubscriptionAccountStore: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()

    public init(path: String = NSHomeDirectory() + "/.tokentracker/subscription_accounts.json") {
        self.path = path
    }

    private struct File: Codable {
        var version = 1
        var accounts: [StoredSubscriptionAccount]
    }

    public func load() -> [StoredSubscriptionAccount] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> [StoredSubscriptionAccount] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(File.self, from: data))?.accounts ?? []
    }

    private func write(_ accounts: [StoredSubscriptionAccount]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(accounts: accounts))
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = path + ".tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        chmod(temporary, 0o600)
        if rename(temporary, path) != 0 {
            try? FileManager.default.removeItem(atPath: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 新增；同一账号已存在时替换其凭据（保留 id 与菜单栏选择），返回最终记录。
    @discardableResult
    public func upsert(_ account: StoredSubscriptionAccount) throws -> StoredSubscriptionAccount {
        lock.lock(); defer { lock.unlock() }
        var accounts = read()
        var saved = account
        if let index = accounts.firstIndex(where: { $0.id == account.id || $0.sameAccount(as: account) }) {
            saved.id = accounts[index].id
            saved.menuBar = accounts[index].menuBar
            saved.addedAt = accounts[index].addedAt
            if saved.label.isEmpty { saved.label = accounts[index].label }
            accounts[index] = saved
        } else {
            accounts.append(saved)
        }
        try write(accounts)
        return saved
    }

    /// 刷新后的令牌只写回仍存在的同一条记录（用户已移除则丢弃）。
    func updateTokens(_ account: StoredSubscriptionAccount) throws {
        lock.lock(); defer { lock.unlock() }
        var accounts = read()
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].token = account.token
        accounts[index].refreshToken = account.refreshToken
        accounts[index].expiresAt = account.expiresAt
        accounts[index].extra = account.extra
        try write(accounts)
    }

    public func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try write(read().filter { $0.id != id })
    }

    /// 设为该供应商的菜单栏账号（同供应商其他账号取消）。
    public func setMenuBar(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var accounts = read()
        guard let provider = accounts.first(where: { $0.id == id })?.provider else { return }
        for index in accounts.indices where accounts[index].provider == provider {
            accounts[index].menuBar = accounts[index].id == id
        }
        try write(accounts)
    }

    // ------------------------------------------------------------ 导入 ----

    /// 一键导入：把本机配置里可直接查询的 API Key 复制进账号库。之后不再读取原文件。
    /// OAuth 登录态不导入（需在 TokenTracker 里自己登录）；配给中转的 Key 不导入。
    @discardableResult
    public func importAPIKeys(from discovery: SubscriptionDiscovery = SubscriptionDiscovery()) throws -> Int {
        let candidates = discovery.discover().filter {
            $0.credential?.kind == .apiKey && $0.discoveryProblem == nil
        }
        var added = 0
        for candidate in candidates {
            guard let credential = candidate.credential else { continue }
            let existing = load()
            if existing.contains(where: { $0.provider == candidate.provider && $0.token == credential.token }) { continue }
            try upsert(StoredSubscriptionAccount(provider: candidate.provider, label: candidate.label, kind: .apiKey,
                                                 origin: .imported, importedFrom: candidate.sources.first?.tool,
                                                 token: credential.token, extra: credential.extra))
            added += 1
        }
        return added
    }

    /// 手动添加 API Key。region 仅 MiniMax 使用（"cn" / "global"）。
    @discardableResult
    public func addAPIKey(provider: SubscriptionProvider, key: String, label: String = "",
                          region: String? = nil) throws -> StoredSubscriptionAccount {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { throw SubscriptionAuthError.invalidInput }
        var extra: [String: String] = [:]
        switch provider {
        case .minimax: extra["host"] = region == "cn" ? "api.minimaxi.com" : "api.minimax.io"
        case .kimi: extra["host"] = "api.kimi.com"
        case .deepseek, .go: break
        default: throw SubscriptionAuthError.invalidInput
        }
        return try upsert(StoredSubscriptionAccount(provider: provider, label: label, kind: .apiKey, origin: .manual,
                                                    token: trimmed, extra: extra))
    }

    public static let apiKeyProviders: [SubscriptionProvider] = [.deepseek, .go, .minimax, .kimi]
}
