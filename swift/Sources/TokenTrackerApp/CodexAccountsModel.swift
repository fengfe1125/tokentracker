//
//  CodexAccountsModel.swift
//  TokenTrackerApp
//
//  Codex 多账号：保存当前登录、一键切换、重命名 / 删除。
//  切换涉及文件读写（回采 + 原子替换 auth.json），一律走自己的串行队列，
//  回主线程发布结果。提示只带账号名与结果，绝不带 token。
//

import Foundation
import TokenTrackerCore

@MainActor
final class CodexAccountsModel: ObservableObject {
    @Published private(set) var accounts: [CodexAccount] = []
    @Published private(set) var activeID: String? {
        didSet { onActiveChanged?(activeID) }
    }
    @Published private var notice: L10n.Template?
    /// 操作结果 / 错误提示
    var message: String? { notice.map(L10n.text) }

    /// 每次读到当前账号时调用（配额风险按账号区分）
    var onActiveChanged: ((String?) -> Void)?
    /// 成功切到另一个账号后调用
    var onSwitched: (() -> Void)?

    private let switcher: CodexAccountSwitcher
    private let queue = DispatchQueue(label: "tokentracker.codex-accounts")

    init(switcher: CodexAccountSwitcher) {
        self.switcher = switcher
    }

    /// 读账号库 + 当前 active。
    func reload() {
        let switcher = switcher
        queue.async { [weak self] in
            let accounts: [CodexAccount]
            do { accounts = try switcher.store.loadChecked() } catch {
                DispatchQueue.main.async { self?.notice = UIFormat.appError(error) }; return
            }
            let active = switcher.activeAccountID()
            DispatchQueue.main.async {
                self?.accounts = accounts
                self?.activeID = active
            }
        }
    }

    /// 保存当前 Codex 登录为一份账号快照（name 留空则用 email/id 兜底）。
    func captureCurrent(name: String) {
        let switcher = switcher
        queue.async { [weak self] in
            do {
                let account = try switcher.captureCurrent(name: name)
                let accounts = switcher.store.load()
                let active = switcher.activeAccountID()
                let message = L10n.message("已保存账号「\(account.name)」")
                DispatchQueue.main.async {
                    self?.accounts = accounts
                    self?.activeID = active
                    self?.notice = message
                }
            } catch {
                let message = L10n.message("保存失败：\(UIFormat.appError(error))")
                DispatchQueue.main.async { self?.notice = message }
            }
        }
    }

    /// 切换账号：后台执行「回采当前 → 原子写目标」，回主线程发布结果。
    func switchTo(id: String) {
        let switcher = switcher
        queue.async { [weak self] in
            do {
                try switcher.switchTo(id)
                let accounts = switcher.store.load()
                let active = switcher.activeAccountID()
                DispatchQueue.main.async {
                    self?.accounts = accounts
                    self?.activeID = active
                    self?.notice = L10n.message("已切换，请重启 Codex 生效")
                    self?.onSwitched?()
                }
            } catch {
                // 账号文件已换好但历史没写成：仍按已切换处理
                let switched = (error as? AccountPersistenceError) == .historyAfterSwitch
                let message = switched
                    ? L10n.message("切换已完成，但记录保存失败") : L10n.message("切换失败：\(UIFormat.appError(error))")
                let active = switched ? switcher.activeAccountID() : nil
                DispatchQueue.main.async {
                    self?.notice = message
                    if switched {
                        self?.activeID = active
                        self?.onSwitched?()
                    }
                }
            }
        }
    }

    func remove(id: String) {
        let switcher = switcher
        queue.async { [weak self] in
            let accounts: [CodexAccount]
            do { accounts = try switcher.store.remove(id) } catch {
                DispatchQueue.main.async { self?.notice = UIFormat.appError(error) }; return
            }
            DispatchQueue.main.async { self?.accounts = accounts }
        }
    }

    func rename(id: String, name: String) {
        let switcher = switcher
        queue.async { [weak self] in
            let accounts: [CodexAccount]
            do { accounts = try switcher.store.rename(id, name: name) } catch {
                DispatchQueue.main.async { self?.notice = UIFormat.appError(error) }; return
            }
            DispatchQueue.main.async { self?.accounts = accounts }
        }
    }
}
