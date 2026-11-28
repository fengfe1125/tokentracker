//
//  ClaudeBilling.swift
//  TokenTrackerCore
//
//  Claude 官方配额接口常量，供 Subscriptions/ 的自有登录与查询使用。
//  旧版直接读取并刷新 Claude Code 钥匙串 / 凭据文件的抓取链已移除：
//  TokenTracker 只用自己账号库里的登录态。
//

import Foundation

public enum ClaudeBilling {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "claude-cli/2.0.0 (external, cli)"
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let planNames = ["pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"]
}
