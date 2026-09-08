//
//  CodexAccountSwitcher.swift
//  TokenTrackerCore
//
//  Codex 多账号切换核心：保存当前登录快照 + 一键原子替换 auth.json。
//  唯一必须做对的正确性点——「回采 before 覆盖」：Codex CLI 运行中会轮换
//  refresh_token，切换前必须把 live auth.json 存回「即将离开」的账号，否则用
//  旧令牌盖新令牌会把该账号登出（与 CodexBilling 顶部注释同款约束）。
//  authPath 口径与 CodexBilling 完全一致：CODEX_HOME ?? ~/.codex。
//

import Foundation

public enum CodexAccountError: Error, CustomStringConvertible {
    /// ~/.codex/auth.json 缺失，或没有 tokens.account_id（未登录）。
    case noLiveCredentials
    /// 目标 id 不在账号库里。
    case notFound(String)

    public var description: String {
        switch self {
        case .noLiveCredentials:
            return "未找到 Codex 登录态（~/.codex/auth.json 缺失或无 tokens.account_id）"
        case .notFound(let id):
            return "账号不存在：\(id)"
        }
    }
}

public struct CodexAccountSwitcher: @unchecked Sendable {
    public let ctx: BillingContext
    public let store: CodexAccountStore

    /// 串行化切换事务：回采 + 覆盖必须原子，避免并发对写 auth.json。
    /// 仿 CliFind.lock 的静态锁写法（NSLock 本身 Sendable）。
    static let lock = NSLock()

    /// store 默认从 ctx.home 派生（测试注入 tmp ctx 即隔离到临时目录）。
    public init(ctx: BillingContext = BillingContext(), store: CodexAccountStore? = nil) {
        self.ctx = ctx
        self.store = store ?? CodexAccountStore(home: ctx.home)
    }

    /// 与 CodexBilling.authPath 同口径。
    var authPath: String {
        expandPath(ctx.env["CODEX_HOME"] ?? (ctx.home + "/.codex")) + "/auth.json"
    }

    /// 读当前 live auth.json 整份；缺失 / 坏 JSON 返回 nil。
    func readLiveBundle() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// 从一份 bundle 取账号主键 tokens.account_id。
    static func accountID(in bundle: [String: Any]) -> String? {
        (bundle["tokens"] as? [String: Any])?["account_id"] as? String
    }

    /// 当前生效账号（live bundle 的 tokens.account_id）；未登录返回 nil。
    public func activeAccountID() -> String? {
        readLiveBundle().flatMap { Self.accountID(in: $0) }
    }

    /// 保存当前登录：读 live auth.json → 以 account_id 为主键 upsert。
    /// name 为空时用 email（再退回 id）兜底命名。
    @discardableResult
    public func captureCurrent(name: String) throws -> CodexAccount {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let live = readLiveBundle(), let id = Self.accountID(in: live) else {
            throw CodexAccountError.noLiveCredentials
        }
        let email = CodexAccount.email(fromBundle: live)
        var account = store.get(id) ?? CodexAccount(id: id, name: "", bundle: live)
        account.bundle = live
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            account.name = trimmed
        } else if account.name.isEmpty {
            account.name = email ?? id
        }
        if account.email == nil { account.email = email }
        store.upsert(account)
        return account
    }

    /// 切换到指定账号：★回采当前 live → ★原子写目标快照 → 记 lastUsedAt。
    public func switchTo(_ id: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let target = store.get(id) else { throw CodexAccountError.notFound(id) }
        // 1) 回采：把 live auth.json 存回「即将离开」的账号（其 refresh_token 可能已轮换）。
        //    仅当 live 账号确实存在且 != 目标时才回采，避免用目标自身覆盖。
        if let live = readLiveBundle(),
           let current = Self.accountID(in: live), current != id,
           var leaving = store.get(current) {
            leaving.bundle = live
            store.upsert(leaving)
        }
        // 2) 原子写入目标账号快照（tmp + rename，0600），不产生半截 auth.json。
        atomicWriteJSON(authPath, target.bundle, permissions: 0o600)
        store.touchUsed(id)
    }
}
