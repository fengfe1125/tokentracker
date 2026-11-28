//
//  CodexBilling.swift
//  TokenTrackerCore
//
//  Codex 官方配额接口常量，供 Subscriptions/ 的自有登录与查询使用。
//  旧版复用并回写 ~/.codex/auth.json 的抓取链已移除（账号切换见 Accounts/）。
//

import Foundation

public enum CodexBilling {
    static let whamURL = "https://chatgpt.com/backend-api/wham/usage"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let cliUA = "codex_cli_rs/0.150.1"
}
