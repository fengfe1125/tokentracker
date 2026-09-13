//
//  CodexAccountStore.swift
//  TokenTrackerCore
//
//  Codex 账号快照的持久化：独立文件 ~/.tokentracker/codex_accounts.json，
//  与 usage.db 分离（账号是密钥类数据，不进出用量库 / 导出 / 差分流程）。
//  写用 atomicWriteJSON（tmp + rename，0600）；读容错（缺文件 / 坏 JSON → 空表）。
//  仿 SettingsStore 的 struct + 路径注入范式；事务串行化交给 CodexAccountSwitcher。
//

import Foundation

public struct CodexAccountStore: Sendable {
    public let path: String
    private let writer: @Sendable (String, [String:Any]) throws -> Void

    /// path 显式指定优先；否则落在 home/.tokentracker/codex_accounts.json。
    /// 测试注入 tmp 路径，App 走默认（NSHomeDirectory）。
    public init(path: String? = nil, home: String = NSHomeDirectory(), writer: @escaping @Sendable (String, [String:Any]) throws -> Void = { try writeAccountJSON($0,$1) }) {
        self.writer = writer
        self.path = path ?? (home + "/.tokentracker/codex_accounts.json")
    }

    /// 读全部账号；文件缺失 / 损坏返回空数组（不抛错，UI 侧无感）。
    public func load() -> [CodexAccount] { (try? loadChecked()) ?? [] }

    public func loadChecked() throws -> [CodexAccount] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["version"] as? Int) == 1,
              let raw = obj["accounts"] as? [[String: Any]] else {
            throw AccountPersistenceError.corrupt
        }
        let accounts = raw.compactMap { CodexAccount(dict: $0) }
        guard accounts.count == raw.count, Set(accounts.map(\.id)).count == accounts.count else {
            throw AccountPersistenceError.corrupt
        }
        return accounts
    }

    /// 原子落盘（0600）。格式 {"version":1,"accounts":[...]}。
    func save(_ accounts: [CodexAccount]) throws {
        try writer(path,
                        ["version": 1, "accounts": accounts.map { $0.toDict() }])
    }

    /// 按 id 去重插入 / 更新；已存在则保留其 addedAt（首次添加时间不因回采而变）。
    /// 返回更新后的完整列表，省调用方二次 load。
    @discardableResult
    public func upsert(_ account: CodexAccount) throws -> [CodexAccount] {
        var accounts = try loadChecked()
        var updated = account
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            updated.addedAt = accounts[idx].addedAt
            accounts[idx] = updated
        } else {
            accounts.append(updated)
        }
        try save(accounts)
        return accounts
    }

    public func get(_ id: String) -> CodexAccount? {
        load().first { $0.id == id }
    }

    @discardableResult
    public func remove(_ id: String) throws -> [CodexAccount] {
        var accounts = try loadChecked()
        accounts.removeAll { $0.id == id }
        try save(accounts)
        return accounts
    }

    @discardableResult
    public func rename(_ id: String, name: String) throws -> [CodexAccount] {
        var accounts = try loadChecked()
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].name = name
        }
        try save(accounts)
        return accounts
    }

    /// 记一次「最近使用」（切换成功后调用）。
    @discardableResult
    public func touchUsed(_ id: String, at date: Date = Date()) throws -> [CodexAccount] {
        var accounts = try loadChecked()
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].lastUsedAt = date
        }
        try save(accounts)
        return accounts
    }
}
