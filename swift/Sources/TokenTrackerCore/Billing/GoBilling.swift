//
//  GoBilling.swift
//  TokenTrackerCore
//
//  OpenCode Go 官方配额接口常量，供 Subscriptions/ 查询使用。必须带浏览器 UA
//  （否则 Cloudflare 1010）。
//

import Foundation

public enum GoBilling {
    static let quotaURL = "https://opencode.ai/zen/go/v1/usage"
    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
}
