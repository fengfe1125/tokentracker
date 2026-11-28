//
//  KimiBilling.swift
//  TokenTrackerCore
//
//  Kimi 官方接口常量与区域解析，供 Subscriptions/ 的自有登录与查询使用。
//  旧版读取并刷新、回写 ~/.kimi-code 凭据的抓取链已移除；这里只读区域设置
//  （环境变量 / region 文件）来决定 API 域名，不读取凭据。
//

import Foundation

public struct KimiBilling {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"   // kimi-code 内置 public client
    static let planNames = ["LEVEL_BASIC": "基础版", "LEVEL_INTERMEDIATE": "中级版",
                            "LEVEL_PREMIUM": "高级版", "LEVEL_UNLIMITED": "无限版",
                            "LEVEL_PRO": "专业版"]

    public let ctx: BillingContext

    public init(ctx: BillingContext) {
        self.ctx = ctx
    }

    /// OAuth host：环境变量覆盖（与 kimi-code 同名）→ region 文件 → CN 默认。
    func oauthHost() -> String {
        if let env = ctx.env["KIMI_CODE_OAUTH_HOST"] ?? ctx.env["KIMI_OAUTH_HOST"],
           !env.isEmpty {
            return env.hasSuffix("/") ? String(env.dropLast()) : env
        }
        let root = ctx.env["KIMI_CODE_HOME"] ?? ctx.home + "/.kimi-code"
        let regionPath = expandPath(root) + "/region"
        if let text = try? String(contentsOfFile: regionPath, encoding: .utf8) {
            let region = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !region.isEmpty && region != "mainland-cn" {
                return "https://auth.kimi.ai"
            }
        }
        return "https://auth.kimi.com"
    }

    /// usages 等业务 API 前缀：与 OAuth host 同域族（auth.kimi.com ↔ api.kimi.com）。
    func apiBase() -> String {
        let host = oauthHost()
        if let match = try? NSRegularExpression(pattern: #"^(https://)auth\.(.+)$"#)
            .firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
           let r1 = Range(match.range(at: 1), in: host),
           let r2 = Range(match.range(at: 2), in: host) {
            return "\(host[r1])api.\(host[r2])/coding/v1"
        }
        return "https://api.kimi.com/coding/v1"
    }
}
