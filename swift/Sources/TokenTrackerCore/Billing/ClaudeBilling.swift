//
//  ClaudeBilling.swift
//  TokenTrackerCore
//
//  移植 billing.py 的 Claude 三级回退链：
//  1. 桌面 App 采样文件（<30min，无需凭据；不受 Claude Code 2.1.x 清空
//     钥匙串的官方 bug 影响）
//  2. api.anthropic.com/api/oauth/usage（钥匙串 / ~/.claude/.credentials.json /
//     本地快照三源遍历，跳过空壳；手写刷新失败委托官方 CLI 刷新）
//  3. 全灭 → 桌面采样顶底 / 提示重新登录
//  见到有效凭据自动快照（~/.tokentracker/claude_cred_backup.json）。
//

import Foundation

public struct ClaudeBilling {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "claude-cli/2.0.0 (external, cli)"
    static let tokenURL = "https://api.anthropic.com/v1/oauth/token"
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let planNames = ["pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"]

    public let ctx: BillingContext

    public init(ctx: BillingContext) {
        self.ctx = ctx
    }

    // ------------------------------------------------------------ 快照 ----

    private var snapPath: String { ctx.home + "/.tokentracker/claude_cred_backup.json" }

    /// 见到有效凭据（含 refreshToken）时快照一份（0600）——官方存储被清空后可复活。
    func snapSave(_ oauth: [String: Any]) {
        guard oauth["refreshToken"] != nil else { return }
        atomicWriteJSON(snapPath, ["claudeAiOauth": oauth, "saved_at": ctx.clock()])
    }

    func snapLoad() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: snapPath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              oauth["refreshToken"] != nil || oauth["accessToken"] != nil
        else { return nil }
        return oauth
    }

    // ---------------------------------------------------------- 凭据链 ----

    /// 全部凭据来源 → [(oauth, writeBack?, source)]。跳过被清空的空壳条目
    /// （accessToken/refreshToken 皆空），按 expiresAt 从新到旧排序。
    func credentials() -> [(oauth: [String: Any], save: (([String: Any]) -> Void)?, source: String)] {
        var cands: [([String: Any], (([String: Any]) -> Void)?, String)] = []
        if let kc = ctx.keychainRead(),
           let oauth = kc["claudeAiOauth"] as? [String: Any] {
            cands.append((oauth, { [ctx] newOAuth in
                var updated = kc
                updated["claudeAiOauth"] = newOAuth
                _ = ctx.keychainWrite(updated)
            }, "keychain"))
        }
        let credPath = ctx.home + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: credPath),
           let cred = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = cred["claudeAiOauth"] as? [String: Any] {
            cands.append((oauth, { newOAuth in
                var updated = cred
                updated["claudeAiOauth"] = newOAuth
                atomicWriteJSON(credPath, updated)
            }, "file"))
        }
        if let snap = snapLoad() {
            cands.append((snap, { [self] in snapSave($0) }, "snapshot"))
        }
        // 跳过空壳（官方 bug 清空的条目）
        cands = cands.filter { $0.0["accessToken"] != nil || $0.0["refreshToken"] != nil }
        cands.sort { ($0.0["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            > ($1.0["expiresAt"] as? NSNumber)?.doubleValue ?? 0 }
        return cands
    }

    // ------------------------------------------------------------ 刷新 ----

    /// refresh_token 换新的 access/refresh token（UA 须为 claude-cli，否则 CF 1010）。
    func refresh(_ refreshToken: String) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        let (status, data) = ctx.http(Self.tokenURL,
                                      ["Content-Type": "application/json",
                                       "User-Agent": Self.userAgent], body, "POST")
        guard status == 200, data["access_token"] is String else {
            throw SQLiteError(message: "HTTP \(status)")
        }
        return data
    }

    /// 手写刷新失败时委托官方 CLI：隔离 CLAUDE_CONFIG_DIR + refresh token 环境变量
    /// 跑 `claude auth login`，端点/UA/scope 全由官方 CLI 决定，抗协议变更。
    func refreshViaCLI(_ refreshToken: String) throws -> [String: Any] {
        guard let claude = ctx.cliResolver("claude") else {
            throw SQLiteError(message: "未找到 claude CLI")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let credFile = tmp.appendingPathComponent(".credentials.json")
        let credData = try JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": ["refreshToken": refreshToken]])
        try credData.write(to: credFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: credFile.path)
        try "{\"hasCompletedOnboarding\":true}"
            .write(to: tmp.appendingPathComponent(".claude.json"),
                   atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = tmp.path
        env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = refreshToken
        env["CLAUDE_CODE_OAUTH_SCOPES"] = "openid,profile,email,offline_access"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "login"]
        process.environment = env
        process.currentDirectoryURL = tmp
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        try process.run()
        // 60s 超时
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            let outText = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            let detail = (errText.isEmpty ? outText : errText).trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw SQLiteError(message: String(detail.prefix(120)))
        }
        guard let data = FileManager.default.contents(atPath: credFile.path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = parsed["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            throw SQLiteError(message: "CLI 未返回新 token")
        }
        let expMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return [
            "access_token": accessToken,
            "refresh_token": oauth["refreshToken"] as Any,
            "expires_in": max(60, Int((expMs - ctx.clock() * 1000) / 1000)),
        ]
    }

    // -------------------------------------------------------- 桌面采样 ----

    /// Claude 桌面 App 的配额采样文件（无需凭据）；样本 <30 分钟认为有效。
    func desktopUsage() -> [String: Any]? {
        let path = ctx.home + "/Library/Application Support/Claude/plan-usage-history.json"
        guard let data = FileManager.default.contents(atPath: path),
              let samples = (try? JSONSerialization.jsonObject(with: data))
                .flatMap({ ($0 as? [String: Any])?["samples"] }) as? [[String: Any]],
              let last = samples.last else { return nil }
        let t = (last["t"] as? NSNumber)?.doubleValue ?? 0
        let ageMin = (ctx.clock() * 1000 - t) / 60000
        guard ageMin <= 30 else { return nil }
        guard let usage = last["u"] as? [String: Any] else { return nil }
        var windows: [String: Any] = [:]
        if let fh = usage["fh"] { windows["5h"] = ["pct": fh, "resets_at": NSNull()] }
        if let sd = usage["sd"] { windows["7d"] = ["pct": sd, "resets_at": NSNull()] }
        if windows.isEmpty { return nil }
        return ["windows": windows, "_via": "desktop",
                "_sample_age_min": max(0, Int(ageMin))]
    }

    // -------------------------------------------------------- usage 接口 ----

    private func usageHTTP(_ token: String) -> (Int, [String: Any]) {
        ctx.http(Self.usageURL,
                 ["Authorization": "Bearer \(token)",
                  "anthropic-beta": "oauth-2025-04-20",
                  "Content-Type": "application/json"], nil, "GET")
    }

    /// 单个凭据来源：access token 直接调 → 过期/401 则刷新（手写 → CLI 委托）后重试。
    /// 成功时刷新后的凭据写回来源（refresh_token 轮换，不写回会把 Claude Code 登出）。
    func trySource(_ oauth: [String: Any], save: (([String: Any]) -> Void)?) -> [String: Any] {
        var oauth = oauth
        let tok = oauth["accessToken"] as? String
        let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        var needRefresh = tok == nil || (exp > 0 && ctx.clock() * 1000 > exp - 60_000)
        if !needRefresh, let tok {
            let (status, data) = usageHTTP(tok)
            if status == 200 {
                return ["data": data, "oauth": oauth]
            }
            if status == 429 {
                return ["error": "http_429",
                        "detail": "Claude usage 接口限流，稍后自动重试",
                        "_retry_after": data["_retry_after"] as Any]
            }
            if status != 401 {
                return ["error": "http_\(status)",
                        "detail": "Claude usage 接口返回 \(status)"]
            }
            needRefresh = true  // 401 → 尝试刷新
        }
        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            return ["error": "expired", "detail": "Claude 登录态已过期且无 refreshToken"]
        }
        var refreshed: [String: Any]?
        var err = ""
        do {
            refreshed = try refresh(refreshToken)
        } catch {
            err = String(describing: error)
            do {
                refreshed = try refreshViaCLI(refreshToken)  // 官方 CLI 委托刷新
            } catch {
                err = "\(err)；CLI 委托也失败(\(error))"
            }
        }
        guard let refreshed else {
            return ["error": "refresh_failed",
                    "detail": "Claude token 刷新失败(\(err))"]
        }
        oauth["accessToken"] = refreshed["access_token"]
        if let rt = refreshed["refresh_token"] as? String {
            oauth["refreshToken"] = rt
        }
        let expiresIn = (refreshed["expires_in"] as? NSNumber)?.intValue ?? 28800
        oauth["expiresAt"] = Int64(ctx.clock() * 1000) + Int64(expiresIn) * 1000
        save?(oauth)
        let (status, data) = usageHTTP(oauth["accessToken"] as? String ?? "")
        if status == 200 {
            return ["data": data, "oauth": oauth]
        }
        if status == 429 {
            return ["error": "http_429",
                    "detail": "Claude usage 接口限流，稍后自动重试",
                    "_retry_after": data["_retry_after"] as Any]
        }
        return ["error": "http_\(status)",
                "detail": "Claude usage 接口刷新后仍返回 \(status)"]
    }

    // ------------------------------------------------------------ 入口 ----

    public func oauthUsage() -> [String: Any] {
        // 1) 桌面采样（桌面 App 登录态独立于 CLI，最抗造）
        let desk = desktopUsage()

        // 2) OAuth API（能拿到 resets_at 和更细的窗口，成功则用更丰富的那份）
        let cands = credentials()
        var oauthErr: [String: Any]?
        for (oauth, save, _) in cands {
            let result = trySource(oauth, save: save)
            if let data = result["data"] as? [String: Any] {
                var windows: [String: Any] = [:]
                for (key, label) in [("five_hour", "5h"), ("seven_day", "7d"),
                                     ("seven_day_sonnet", "7d_sonnet"),
                                     ("seven_day_opus", "7d_opus")] {
                    guard let w = data[key] as? [String: Any] else { continue }
                    let pct = BillingNet.pct(w["utilization"] ?? w["used_percentage"])
                    if let pct {
                        windows[label] = ["pct": pct,
                                          "resets_at": BillingNet.isoMs(w["resets_at"]) as Any]
                    }
                }
                if !windows.isEmpty {
                    if let finalOAuth = result["oauth"] as? [String: Any] {
                        snapSave(finalOAuth)  // 凭据有效 → 快照（防官方存储再被清空）
                    }
                    let extra = data["extra_usage"] as? [String: Any] ?? [:]
                    let oauthFinal = result["oauth"] as? [String: Any] ?? [:]
                    let subscription = (oauthFinal["subscriptionType"] as? String) ?? ""
                    let plan = (data["plan"] as? String)
                        ?? (data["rate_limit_tier"] as? String)
                        ?? Self.planNames[subscription.lowercased()]
                        ?? subscription
                    return ["windows": windows, "plan": plan, "_via": "oauth",
                            "extra": ["used_credits": extra["used_credits"] as Any,
                                      "monthly_limit": extra["monthly_limit"] as Any,
                                      "disabled": extra["disabled_reason"] as Any]]
                }
                oauthErr = ["error": "no_windows", "detail": "接口未返回窗口数据"]
                continue
            }
            if result["data"] != nil {
                oauthErr = ["error": "parse", "detail": "接口响应格式异常"]
                continue
            }
            oauthErr = result
            // 限流是接口问题不是凭据问题，换源无意义，直接停
            if result["error"] as? String == "http_429" { break }
        }

        // 3) OAuth 全灭 → 桌面采样顶底（标记来源）
        if var desk {
            if let oauthErr {
                desk["_oauth_err"] = oauthErr["error"]
                if oauthErr["error"] as? String == "http_429" {
                    desk["_retry_after"] = oauthErr["_retry_after"] ?? OfficialCache.ttlErr
                }
            }
            return desk
        }
        if cands.isEmpty {
            return ["error": "no_credentials",
                    "detail": "未找到 Claude 登录态（钥匙串 / ~/.claude/.credentials.json 均为空）"]
        }
        var err = oauthErr ?? ["error": "unknown"]
        if ["expired", "refresh_failed"].contains(err["error"] as? String) {
            err["detail"] = (err["detail"] as? String ?? "")
                + "。请在终端执行 claude auth login 重新登录，或打开一次 Claude 桌面 App"
        }
        return err
    }
}
