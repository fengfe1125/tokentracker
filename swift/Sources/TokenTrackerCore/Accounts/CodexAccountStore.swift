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

    /// path 显式指定优先；否则落在 home/.tokentracker/codex_accounts.json。
    /// 测试注入 tmp 路径，App 走默认（NSHomeDirectory）。
    public init(path: String? = nil, home: String = NSHomeDirectory()) {
        self.path = path ?? (home + "/.tokentracker/codex_accounts.json")
    }

    /// 读全部账号；文件缺失 / 损坏返回空数组（不抛错，UI 侧无感）。
    public func load() -> [CodexAccount] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["accounts"] as? [[String: Any]] else { return [] }
        return raw.compactMap { CodexAccount(dict: $0) }
    }

    /// 原子落盘（0600）。格式 {"version":1,"accounts":[...]}。
    func save(_ accounts: [CodexAccount]) {
        atomicWriteJSON(path,
                        ["version": 1, "accounts": accounts.map { $0.toDict() }],
                        permissions: 0o600)
    }

    /// 按 id 去重插入 / 更新；已存在则保留其 addedAt（首次添加时间不因回采而变）。
    /// 返回更新后的完整列表，省调用方二次 load。
    @discardableResult
    public func upsert(_ account: CodexAccount) -> [CodexAccount] {
        var accounts = load()
        var updated = account
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            updated.addedAt = accounts[idx].addedAt
            accounts[idx] = updated
        } else {
            accounts.append(updated)
        }
        save(accounts)
        return accounts
    }

    public func get(_ id: String) -> CodexAccount? {
        load().first { $0.id == id }
    }

    @discardableResult
    public func remove(_ id: String) -> [CodexAccount] {
        var accounts = load()
        accounts.removeAll { $0.id == id }
        save(accounts)
        return accounts
    }

    @discardableResult
    public func rename(_ id: String, name: String) -> [CodexAccount] {
        var accounts = load()
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].name = name
        }
        save(accounts)
        return accounts
    }

    /// 记一次「最近使用」（切换成功后调用）。
    @discardableResult
    public func touchUsed(_ id: String, at date: Date = Date()) -> [CodexAccount] {
        var accounts = load()
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].lastUsedAt = date
        }
        save(accounts)
        return accounts
    }
}
