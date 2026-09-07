//
//  GoBilling.swift
//  TokenTrackerCore
//
//  移植 billing.py 的 OpenCode Go 部分：Key 自动发现（环境变量 → opencode
//  auth.json）→ opencode.ai/zen/go/v1/usage。必须带浏览器 UA（否则
//  Cloudflare 1010）；间歇性连接重置自动重试；401/403 = 无订阅/Key 无效。
//

import Foundation

public struct GoBilling {
    static let quotaURL = "https://opencode.ai/zen/go/v1/usage"
    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    public let ctx: BillingContext

    public init(ctx: BillingContext) {
        self.ctx = ctx
    }

    /// 解析 OpenCode Go API Key：环境变量 → opencode auth.json。
    func apiKey() -> String? {
        for name in ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"] {
            if let value = ctx.env[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        for path in ["\(ctx.home)/.local/share/opencode/auth.json",
                     "\(ctx.home)/.config/opencode/auth.json"] {
            guard let data = FileManager.default.contents(atPath: path),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = parsed["opencode-go"] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { continue }
            return key
        }
        return nil
    }

    public func usage() -> [String: Any] {
        guard let key = apiKey() else {
            return ["error": "no_key",
                    "detail": "未找到 OpenCode Go API Key：opencode 登录后（auth.json）或用 OPENCODE_GO_API_KEY 环境变量"]
        }
        var status = 0
        var data: [String: Any] = [:]
        var lastErr = ""
        for attempt in 0..<3 {
            (status, data) = ctx.http(
                Self.quotaURL,
                ["Authorization": "Bearer \(key)",
                 "User-Agent": Self.browserUA,
                 "Accept": "application/json, text/plain, */*",
                 "Connection": "close"], nil, "GET")
            if status != 0 { break }
            lastErr = data["error"] as? String ?? "connection reset"
            if attempt < 2 { Thread.sleep(forTimeInterval: 2) }
        }
        if status == 401 || status == 403 {
            return ["error": "no_sub", "detail": "没有生效的 OpenCode Go 订阅，或 API Key 无效"]
        }
        guard status == 200 else {
            return ["error": "http_\(status)",
                    "detail": "Go 额度接口返回 \(status)（\(lastErr)）",
                    "_retry_after": data["_retry_after"] as Any]
        }
        guard let usage = data["usage"] as? [String: Any] else {
            return ["error": "no_usage", "detail": "Go 额度响应缺少 usage 字段"]
        }
        var windows: [String: Any] = [:]
        for (src, key) in [("rolling", "5h"), ("weekly", "7d"), ("monthly", "month")] {
            guard let w = usage[src] as? [String: Any],
                  let percent = (w["percent"] as? NSNumber)?.doubleValue else { continue }
            windows[key] = ["pct": percent,
                            "resets_at": BillingNet.isoMs(w["resetsAt"]) as Any]
        }
        if windows.isEmpty {
            return ["error": "no_windows", "detail": "Go 额度响应无可用窗口"]
        }
        return ["windows": windows, "plan": "OpenCode Go"]
    }
}
