//
//  SubscriptionAdapters.swift
//  TokenTrackerCore
//
//  各供应商的只读额度/余额适配器。只用发现到的那份凭据查询一次：
//  不刷新、不轮换、不回写其他工具的登录态，不发生成请求，不消耗额度。
//  每家只把凭据发往自己登记的域名；私有接口结果标记 privateAPI。
//

import Foundation

struct SubscriptionFetchContext {
    var transport: SubscriptionTransport
    var now: Date
    var env: [String: String] = [:]
}

enum SubscriptionAdapters {
    /// 每家允许携带凭据的域名。
    static let hosts: [SubscriptionProvider: Set<String>] = [
        .claude: ["api.anthropic.com"],
        .codex: ["chatgpt.com"],
        .kimi: ["api.kimi.com", "api.kimi.ai"],
        .go: ["opencode.ai"],
        .deepseek: ["api.deepseek.com"],
        .copilot: ["api.github.com"],
        .gemini: ["cloudcode-pa.googleapis.com"],
        .minimax: ["api.minimaxi.com", "api.minimax.io"],
        .grok: ["cli-chat-proxy.grok.com"],
        .workbuddy: ["copilot.tencent.com"],
        .workbuddyAI: ["www.workbuddy.ai"],
        .zcode: ["zcode.z.ai", "api.z.ai", "open.bigmodel.cn"],
    ]

    static let privateAPIs: Set<SubscriptionProvider> = [.copilot, .gemini, .minimax, .grok, .workbuddy, .workbuddyAI, .zcode]

    static func fetch(_ account: SubscriptionAccount, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        if let problem = account.discoveryProblem {
            let status: SubscriptionStatus = problem == .noCredential ? .signedOut : .unsupported
            return .failure(status, problem)
        }
        guard let credential = account.credential, !credential.token.isEmpty else {
            return .failure(.signedOut, .noCredential)
        }
        if let expiry = credential.expiresAt, expiry <= ctx.now {
            return .failure(.expired, .credentialExpired)
        }
        var snapshot: SubscriptionSnapshot
        switch account.provider {
        case .claude: snapshot = claude(credential, needsIdentity: account.providerAccountID == nil, ctx)
        case .codex: snapshot = codex(credential, ctx)
        case .kimi: snapshot = kimi(credential, ctx)
        case .go: snapshot = go(credential, ctx)
        case .deepseek: snapshot = deepseek(credential, ctx)
        case .copilot: snapshot = copilot(credential, ctx)
        case .gemini: snapshot = gemini(credential, ctx)
        case .minimax: snapshot = minimax(credential, ctx)
        case .grok: snapshot = grok(credential, ctx)
        case .workbuddy, .workbuddyAI: snapshot = workbuddy(account.provider, credential, ctx)
        case .zcode: snapshot = zcode(credential, ctx)
        case .zenFree: snapshot = .failure(.unsupported, .freeModel)
        }
        snapshot.privateAPI = privateAPIs.contains(account.provider)
        if snapshot.status == .current { snapshot.sampledAt = ctx.now }
        return snapshot
    }

    // ------------------------------------------------------------ 公共 ----

    static func send(_ provider: SubscriptionProvider, _ request: SubscriptionRequest,
                     _ ctx: SubscriptionFetchContext) -> SubscriptionResponse {
        guard SubscriptionHTTP.permits(request.url, hosts: hosts[provider] ?? []) else {
            return SubscriptionResponse(status: 0, failure: .blocked)
        }
        return ctx.transport(request)
    }

    static func failure(_ response: SubscriptionResponse, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let retryAt = response.retryAfter.map { ctx.now.addingTimeInterval($0) }
        switch response.failure {
        case .blocked: return .failure(.failed, .untrustedEndpoint)
        case .timeout: return .failure(.failed, .timeout)
        case .network: return .failure(.failed, .network)
        case nil: break
        }
        switch response.status {
        case 401: return .failure(.expired, .unauthorized, http: 401)
        case 403: return .failure(.forbidden, .forbidden, http: 403, retryAt: retryAt)
        case 429: return .failure(.failed, .rateLimited, http: 429,
                                  retryAt: retryAt ?? ctx.now.addingTimeInterval(5 * 60))
        default: return .failure(.failed, .httpStatus, http: response.status, retryAt: retryAt)
        }
    }

    static func current(_ windows: [SubscriptionWindow], plan: String = "",
                        accountKey: String? = nil) -> SubscriptionSnapshot {
        guard !windows.isEmpty else { return .failure(.failed, .noWindows) }
        return SubscriptionSnapshot(status: .current, windows: windows, plan: plan, accountKey: accountKey)
    }

    static func jsonBody(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func percent(used: Double, of limit: Double) -> Double? {
        limit > 0 ? used / limit * 100 : nil
    }

    // ---------------------------------------------------------- Claude ----

    static func claude(_ c: SubscriptionCredential, needsIdentity: Bool,
                       _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        guard c.kind == .oauth else { return .failure(.unsupported, .apiKeyOnly) }
        let headers = ["Authorization": "Bearer " + c.token, "anthropic-beta": "oauth-2025-04-20",
                       "User-Agent": ClaudeBilling.userAgent, "Accept": "application/json"]
        let response = send(.claude, SubscriptionRequest(url: URL(string: ClaudeBilling.usageURL)!, headers: headers), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        var snapshot = current(claudeWindows(response.json), plan: claudePlan(c.extra["plan"] ?? ""))
        guard snapshot.status == .current, needsIdentity else { return snapshot }
        // 钥匙串等来源没有账号 ID：读一次 profile 拿 account.uuid，用于跨来源去重。
        let profile = send(.claude, SubscriptionRequest(
            url: URL(string: "https://api.anthropic.com/api/oauth/profile")!, headers: headers), ctx)
        if profile.status == 200, let uuid = (profile.json["account"] as? [String: Any])?["uuid"] as? String, !uuid.isEmpty {
            snapshot.accountKey = subscriptionHash("claude|" + uuid)
        }
        return snapshot
    }

    static func claudePlan(_ raw: String) -> String {
        ClaudeBilling.planNames[raw.lowercased()] ?? raw
    }

    static func claudeWindows(_ data: [String: Any]) -> [SubscriptionWindow] {
        let names = ["seven_day_sonnet": "Sonnet", "seven_day_opus": "Opus", "seven_day_oauth_apps": "OAuth Apps"]
        func rank(_ key: String) -> Int { key == "five_hour" ? 0 : key == "seven_day" ? 1 : 2 }
        let keys = data.keys.filter { $0.hasPrefix("five_hour") || $0.hasPrefix("seven_day") }
            .sorted { (rank($0), $0) < (rank($1), $1) }
        return keys.compactMap { key in
            guard let w = data[key] as? [String: Any],
                  let pct = subscriptionNumber(w["utilization"] ?? w["used_percentage"]) else { return nil }
            let name: String? = key == "five_hour" || key == "seven_day" ? nil
                : names[key] ?? key.replacingOccurrences(of: "seven_day_", with: "").capitalized
            return SubscriptionWindow(id: key, name: name, duration: key.hasPrefix("five_hour") ? 18_000 : 604_800,
                                      usedPercent: pct, resetsAt: subscriptionDate(w["resets_at"]))
        }
    }

    // ----------------------------------------------------------- Codex ----

    static func codex(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        guard c.kind == .oauth else { return .failure(.unsupported, .apiKeyOnly) }
        var headers = ["Authorization": "Bearer " + c.token, "Accept": "application/json",
                       "User-Agent": CodexBilling.cliUA]
        if let account = c.extra["account"] { headers["ChatGPT-Account-Id"] = account }
        let response = send(.codex, SubscriptionRequest(url: URL(string: CodexBilling.whamURL)!, headers: headers), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        return current(codexWindows(response.json, now: ctx.now), plan: codexPlan(response.json["plan_type"] as? String ?? ""))
    }

    static func codexPlan(_ raw: String) -> String {
        ["plus": "Plus", "pro": "Pro", "team": "Team", "business": "Business",
         "enterprise": "Enterprise", "edu": "Edu", "free": "Free"][raw.lowercased()] ?? raw
    }

    static func codexWindows(_ data: [String: Any], now: Date) -> [SubscriptionWindow] {
        let rate = data["rate_limit"] as? [String: Any] ?? [:]
        return ["primary_window", "secondary_window"].compactMap { key in
            guard let w = rate[key] as? [String: Any], let pct = subscriptionNumber(w["used_percent"]) else { return nil }
            let reset = subscriptionDate(w["reset_at"])
                ?? subscriptionNumber(w["reset_after_seconds"]).map { now.addingTimeInterval($0) }
            return SubscriptionWindow(id: key, duration: subscriptionNumber(w["limit_window_seconds"]).map { Int($0) },
                                      usedPercent: pct, resetsAt: reset)
        }
    }

    // ------------------------------------------------------------ Kimi ----

    static func kimi(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let host = c.extra["host"] ?? "api.kimi.com"
        guard let url = URL(string: "https://\(host)/coding/v1/usages") else { return .failure(.failed, .untrustedEndpoint) }
        let response = send(.kimi, SubscriptionRequest(url: url, headers: ["Authorization": "Bearer " + c.token,
                                                                           "Accept": "application/json"]), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        let level = ((response.json["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String ?? ""
        return current(kimiWindows(response.json), plan: KimiBilling.planNames[level] ?? level)
    }

    static func kimiWindows(_ data: [String: Any]) -> [SubscriptionWindow] {
        func window(_ id: String, duration: Int?, _ w: [String: Any]) -> SubscriptionWindow? {
            guard let limit = subscriptionNumber(w["limit"]) else { return nil }
            guard let used = subscriptionNumber(w["used"])
                    ?? subscriptionNumber(w["remaining"]).map({ limit - $0 }) else { return nil }
            return SubscriptionWindow(id: id, duration: duration, usedPercent: percent(used: used, of: limit),
                                      used: subscriptionDecimal(NSNumber(value: used)),
                                      limit: subscriptionDecimal(w["limit"]), unit: "requests",
                                      resetsAt: subscriptionDate(w["resetTime"] ?? w["reset_time"]))
        }
        var windows: [SubscriptionWindow] = []
        for (index, item) in (data["limits"] as? [[String: Any]] ?? []).enumerated() {
            guard let detail = item["detail"] as? [String: Any] else { continue }
            let span = item["window"] as? [String: Any] ?? [:]
            var duration = subscriptionNumber(span["duration"]).map { Int($0) }
            let unit = (span["timeUnit"] as? String ?? "").uppercased()
            if let d = duration {
                duration = unit.contains("HOUR") ? d * 3600 : unit.contains("DAY") ? d * 86_400
                    : unit.contains("SECOND") ? d : d * 60
            }
            if let w = window("limit-\(index)", duration: duration, detail) { windows.append(w) }
        }
        if let usage = data["usage"] as? [String: Any], let w = window("usage", duration: 604_800, usage) {
            windows.append(w)
        }
        return windows
    }

    // -------------------------------------------------------- OpenCode Go ----

    static func go(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let response = send(.go, SubscriptionRequest(url: URL(string: GoBilling.quotaURL)!, headers: [
            "Authorization": "Bearer " + c.token, "User-Agent": GoBilling.browserUA,
            "Accept": "application/json, text/plain, */*"]), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        let usage = response.json["usage"] as? [String: Any] ?? [:]
        let windows = [("rolling", 18_000), ("weekly", 604_800), ("monthly", 2_592_000)].compactMap { key, span -> SubscriptionWindow? in
            guard let w = usage[key] as? [String: Any], let pct = subscriptionNumber(w["percent"]) else { return nil }
            return SubscriptionWindow(id: key, duration: span, usedPercent: pct, resetsAt: subscriptionDate(w["resetsAt"]))
        }
        return current(windows, plan: "OpenCode Go")
    }

    // --------------------------------------------------------- DeepSeek ----

    /// 官方 GET /user/balance（https://api-docs.deepseek.com/api/get-user-balance/）。
    static func deepseek(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let response = send(.deepseek, SubscriptionRequest(url: URL(string: "https://api.deepseek.com/user/balance")!,
                                                           headers: ["Authorization": "Bearer " + c.token,
                                                                     "Accept": "application/json"]), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        guard let rows = response.json["balance_infos"] as? [[String: Any]] else { return .failure(.failed, .malformed) }
        let balances = rows.compactMap { row -> SubscriptionBalance? in
            guard let currency = row["currency"] as? String, !currency.isEmpty else { return nil }
            return SubscriptionBalance(currency: currency, total: subscriptionDecimal(row["total_balance"]),
                                       granted: subscriptionDecimal(row["granted_balance"]),
                                       toppedUp: subscriptionDecimal(row["topped_up_balance"]))
        }
        var snapshot = SubscriptionSnapshot(status: .current, balances: balances)
        if (response.json["is_available"] as? Bool) == false { snapshot.problem = .balanceUnavailable }
        return snapshot
    }

    // ---------------------------------------------------------- Copilot ----

    static func copilot(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let response = send(.copilot, SubscriptionRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!, headers: [
            "Authorization": "token " + c.token, "Accept": "application/json",
            "Editor-Version": "vscode/1.99.0", "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7", "X-Github-Api-Version": "2025-04-01"]), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        let data = response.json
        let reset = subscriptionDate(data["quota_reset_date_utc"]) ?? copilotDay(data["quota_reset_date"])
            ?? copilotDay(data["limited_user_reset_date"])
        var windows: [SubscriptionWindow] = []
        let snapshots = data["quota_snapshots"] as? [String: Any] ?? [:]
        let order = ["premium_interactions", "chat", "completions"]
        for key in snapshots.keys.sorted(by: { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }) {
            guard let w = snapshots[key] as? [String: Any], (w["unlimited"] as? Bool) != true else { continue }
            var used: Double?
            if let remaining = subscriptionNumber(w["percent_remaining"]) { used = 100 - remaining }
            else if let total = subscriptionNumber(w["entitlement"]), let left = subscriptionNumber(w["remaining"]) {
                used = percent(used: total - left, of: total)
            }
            guard let used else { continue }
            windows.append(SubscriptionWindow(id: key, name: key, duration: 2_592_000, usedPercent: used,
                                              limit: subscriptionDecimal(w["entitlement"]), unit: "requests", resetsAt: reset))
        }
        // 免费版：monthly_quotas 为总额，limited_user_quotas 为剩余。
        if windows.isEmpty, let monthly = data["monthly_quotas"] as? [String: Any],
           let left = data["limited_user_quotas"] as? [String: Any] {
            for key in monthly.keys.sorted() {
                guard let total = subscriptionNumber(monthly[key]), let remaining = subscriptionNumber(left[key]) else { continue }
                windows.append(SubscriptionWindow(id: key, name: key, duration: 2_592_000,
                                                  usedPercent: percent(used: total - remaining, of: total),
                                                  limit: subscriptionDecimal(monthly[key]), unit: "requests", resetsAt: reset))
            }
        }
        let login = data["login"] as? String
        return current(windows, plan: (data["copilot_plan"] as? String ?? "").capitalized,
                       accountKey: login.map { subscriptionHash("copilot|" + $0.lowercased()) })
    }

    static func copilotDay(_ value: Any?) -> Date? {
        guard let s = value as? String, s.count == 10 else { return subscriptionDate(value) }
        return subscriptionDate(s + "T00:00:00Z")
    }

    // ----------------------------------------------------------- Gemini ----

    static func gemini(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        guard c.kind == .oauth else { return .failure(.unsupported, .apiKeyOnly) }
        let base = "https://cloudcode-pa.googleapis.com/v1internal:"
        let headers = ["Authorization": "Bearer " + c.token, "Content-Type": "application/json",
                       "Accept": "application/json"]
        let load = send(.gemini, SubscriptionRequest(url: URL(string: base + "loadCodeAssist")!, method: "POST", headers: headers,
                                                     body: jsonBody(["metadata": ["ideType": "IDE_UNSPECIFIED",
                                                                                   "platform": "PLATFORM_UNSPECIFIED",
                                                                                   "pluginType": "GEMINI"]])), ctx)
        guard load.status == 200 else { return failure(load, ctx) }
        let projectValue = load.json["cloudaicompanionProject"]
        let project = projectValue as? String ?? (projectValue as? [String: Any])?["id"] as? String
            ?? ctx.env["GOOGLE_CLOUD_PROJECT"]
        let tier = (load.json["paidTier"] as? [String: Any])?["name"] as? String
            ?? (load.json["currentTier"] as? [String: Any])?["name"] as? String ?? ""
        guard let project, !project.isEmpty else { return .failure(.failed, .noWindows) }
        let quota = send(.gemini, SubscriptionRequest(url: URL(string: base + "retrieveUserQuota")!, method: "POST",
                                                      headers: headers, body: jsonBody(["project": project])), ctx)
        guard quota.status == 200 else { return failure(quota, ctx) }
        var seen = Set<String>()
        let windows = (quota.json["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> SubscriptionWindow? in
            guard let model = bucket["modelId"] as? String, !model.isEmpty, !seen.contains(model),
                  let fraction = subscriptionNumber(bucket["remainingFraction"]) else { return nil }
            seen.insert(model)
            return SubscriptionWindow(id: model, name: model, duration: 86_400, usedPercent: (1 - fraction) * 100,
                                      resetsAt: subscriptionDate(bucket["resetTime"]))
        }
        return current(windows.sorted { $0.id < $1.id }, plan: tier)
    }

    // ---------------------------------------------------------- MiniMax ----

    static func minimax(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let host = c.extra["host"] ?? "api.minimax.io"
        guard let url = URL(string: "https://\(host)/v1/token_plan/remains") else { return .failure(.failed, .untrustedEndpoint) }
        let response = send(.minimax, SubscriptionRequest(url: url, headers: ["Authorization": "Bearer " + c.token,
                                                                              "Accept": "application/json"]), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        let base = response.json["base_resp"] as? [String: Any] ?? [:]
        let code = subscriptionNumber(base["status_code"]) ?? 0
        if code == 1004 || code == 1001 { return .failure(.expired, .unauthorized) }
        if code == 2062 { return .failure(.forbidden, .noSubscription) }
        if code != 0 { return .failure(.failed, .malformed) }
        let windows = (response.json["model_remains"] as? [[String: Any]] ?? []).enumerated().compactMap { index, row -> SubscriptionWindow? in
            // current_interval_usage_count 的含义在官方各版本间不一致，只采信剩余百分比。
            guard let remaining = subscriptionNumber(row["current_interval_remaining_percent"]) else { return nil }
            let start = subscriptionNumber(row["start_time"]), end = subscriptionNumber(row["end_time"])
            var duration: Int?
            if let start, let end, end > start { duration = Int((end - start) / (end > 1e12 ? 1000 : 1)) }
            return SubscriptionWindow(id: "remains-\(index)", name: row["model_name"] as? String, duration: duration,
                                      usedPercent: 100 - remaining,
                                      limit: subscriptionDecimal(row["current_interval_total_count"]),
                                      unit: "requests", resetsAt: subscriptionDate(row["end_time"]))
        }
        return current(windows, plan: "Token Plan")
    }

    // ------------------------------------------------------------- Grok ----

    static func grok(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let response = send(.grok, SubscriptionRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
                                                       headers: ["Authorization": "Bearer " + c.token,
                                                                 "Accept": "application/json"]), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        let config = response.json["config"] as? [String: Any] ?? [:]
        let spans = ["DAILY": 86_400, "WEEKLY": 604_800, "MONTHLY": 2_592_000]
        var duration: Int?
        var end = config["billingPeriodEnd"]
        if let period = config["currentPeriod"] as? [String: Any] {
            let type = (period["type"] as? String ?? "").replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "")
            duration = spans[type]
            end = period["end"] ?? end
        }
        var windows: [SubscriptionWindow] = []
        if let pct = subscriptionNumber(config["creditUsagePercent"]) {
            windows.append(SubscriptionWindow(id: "credits", name: duration == nil ? "credits" : nil, duration: duration,
                                              usedPercent: pct, resetsAt: subscriptionDate(end)))
        }
        let cap = subscriptionNumber((config["onDemandCap"] as? [String: Any])?["val"]) ?? 0
        if cap > 0, let used = subscriptionNumber((config["onDemandUsed"] as? [String: Any])?["val"]) {
            windows.append(SubscriptionWindow(id: "on-demand", name: "on-demand", usedPercent: percent(used: used, of: cap),
                                              resetsAt: subscriptionDate(end)))
        }
        return current(windows)
    }

    // -------------------------------------------------------- WorkBuddy ----

    static func workbuddy(_ provider: SubscriptionProvider, _ c: SubscriptionCredential,
                          _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        let host = provider == .workbuddy ? "copilot.tencent.com" : "www.workbuddy.ai"
        var headers = ["Authorization": "Bearer " + c.token, "Content-Type": "application/json",
                       "Accept": "application/json", "User-Agent": "WorkBuddy/5.5.6",
                       "X-User-Id": c.extra["uid"] ?? "", "X-Domain": c.extra["domain"] ?? host,
                       "X-Product": "SaaS", "X-IDE-Type": "WorkBuddy"]
        if let enterprise = c.extra["enterprise"] {
            headers["X-Enterprise-Id"] = enterprise
            headers["X-Tenant-Id"] = enterprise
        }
        let response = send(provider, SubscriptionRequest(url: URL(string: "https://\(host)/billing/meter/get-user-resource-summary")!,
                                                          method: "POST", headers: headers, body: Data("{}".utf8)), ctx)
        guard response.status == 200 else { return failure(response, ctx) }
        if let code = subscriptionNumber(response.json["code"]), code != 0 { return .failure(.forbidden, .forbidden) }
        let data = response.json["data"] as? [String: Any] ?? [:]
        let plan = (data["IsPaidUser"] as? Bool) == true ? "Pro" : "Free"
        var total = Decimal(0), used = Decimal(0)
        for package in data["Packages"] as? [[String: Any]] ?? [] {
            let t = package["CycleTotalCapacity"], u = package["CycleUsedCapacity"]
            // 空值视为 0（WorkBuddy 自己的口径）；非数字则整体不可信。
            guard let pt = isBlank(t) ? 0 : subscriptionDecimal(t),
                  let pu = isBlank(u) ? 0 : subscriptionDecimal(u) else { return .failure(.failed, .malformed) }
            total += pt
            used += pu
        }
        guard total > 0 else {
            return (data["Packages"] as? [Any])?.isEmpty != false
                ? SubscriptionSnapshot(status: .unsupported, plan: plan, problem: .enterpriseUnsupported)
                : .failure(.failed, .noWindows)
        }
        let pct = NSDecimalNumber(decimal: used / total * 100).doubleValue
        return current([SubscriptionWindow(id: "credits", name: "credits", usedPercent: pct, used: used, limit: total,
                                           unit: "credits")], plan: plan)
    }

    static func isBlank(_ value: Any?) -> Bool {
        value == nil || value is NSNull || (value as? String)?.isEmpty == true
    }

    // ------------------------------------------------------------ ZCode ----

    static func zcode(_ c: SubscriptionCredential, _ ctx: SubscriptionFetchContext) -> SubscriptionSnapshot {
        var windows: [SubscriptionWindow] = []
        var plan = ""
        var lastFailure: SubscriptionSnapshot?
        // GLM Coding Plan：Key 直接查 /api/monitor/usage/quota/limit（Authorization 不带 Bearer）。
        if let key = c.extra["key"], let root = c.extra["root"], let url = URL(string: root + "/api/monitor/usage/quota/limit") {
            let response = send(.zcode, SubscriptionRequest(url: url, headers: ["Authorization": key, "Accept": "application/json"]), ctx)
            if response.status == 200, let data = zaiData(response.json) {
                windows += zcodeLimitWindows(data)
                if let level = data["level"] as? String, !level.isEmpty { plan = "GLM Coding " + level.capitalized }
            } else if response.status == 200 {
                // 未开通 Coding Plan 时 Z.ai 返回 code=500 与说明文字，不是格式错误。
                let message = response.json["msg"] as? String ?? ""
                lastFailure = message.lowercased().contains("coding plan")
                    ? .failure(.forbidden, .noSubscription) : .failure(.failed, .malformed)
            } else {
                lastFailure = failure(response, ctx)
            }
        }
        // ZCode 赠送套餐：zcode.z.ai 的 billing/balance。
        if let jwt = c.extra["jwt"] {
            if let exp = subscriptionNumber(subscriptionJWTClaims(jwt)["exp"]), Date(timeIntervalSince1970: exp) <= ctx.now {
                lastFailure = lastFailure ?? .failure(.expired, .credentialExpired)
            } else {
                let response = send(.zcode, SubscriptionRequest(
                    url: URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=3.14.3")!,
                    headers: ["Authorization": "Bearer " + jwt, "Accept": "application/json",
                              "User-Agent": "ZCode/3.14.3", "X-Device-Mid": c.extra["device"] ?? ""]), ctx)
                if response.status == 200, let data = zaiData(response.json) {
                    let gift = zcodeGiftWindows(data, now: ctx.now)
                    windows += gift.windows
                    if plan.isEmpty { plan = gift.plan }
                    if gift.windows.isEmpty, lastFailure == nil || lastFailure?.problem == .noSubscription {
                        lastFailure = .failure(.forbidden, .noSubscription)
                    }
                } else {
                    lastFailure = response.status == 200 ? .failure(.failed, .malformed) : failure(response, ctx)
                }
            }
        }
        if windows.isEmpty, let lastFailure { return lastFailure }
        return current(windows, plan: plan)
    }

    /// Z.ai 的 {code, msg, data} 包装：code 为 0/200 才算成功。
    static func zaiData(_ json: [String: Any]) -> [String: Any]? {
        if let code = json["code"], !(code is NSNull) {
            let text = String(describing: code)
            guard text == "0" || text == "200" else { return nil }
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    static func zcodeLimitWindows(_ data: [String: Any]) -> [SubscriptionWindow] {
        let units = [1: 60, 3: 3600, 4: 86_400, 5: 2_592_000, 6: 604_800]
        return (data["limits"] as? [[String: Any]] ?? []).enumerated().compactMap { index, limit -> SubscriptionWindow? in
            // TIME_LIMIT 是每月 MCP 调用次数，不限制模型；usage=0 表示无上限。
            if (limit["type"] as? String ?? "").uppercased() == "TIME_LIMIT" { return nil }
            let total = subscriptionNumber(limit["usage"])
            if total == 0 { return nil }
            let unit = Int(subscriptionNumber(limit["unit"]) ?? 0)
            var count = Int(subscriptionNumber(limit["number"]) ?? 0)
            if unit == 3, count <= 0 { count = 5 }
            let duration = units[unit].map { $0 * max(count, 1) }
            var pct = subscriptionNumber(limit["percentage"])
            var used: Double?
            if let total, total > 0 {
                if let remaining = subscriptionNumber(limit["remaining"]) { used = total - remaining }
                else { used = subscriptionNumber(limit["currentValue"]) }
                if let used, pct == nil || subscriptionNumber(limit["remaining"]) != nil { pct = percent(used: used, of: total) }
            }
            guard let pct else { return nil }
            return SubscriptionWindow(id: "limit-\(index)", duration: duration, usedPercent: pct,
                                      used: used.flatMap { subscriptionDecimal(NSNumber(value: $0)) },
                                      limit: subscriptionDecimal(limit["usage"]), unit: "credits",
                                      resetsAt: subscriptionDate(limit["nextResetTime"]))
        }
    }

    static func zcodeGiftWindows(_ data: [String: Any], now: Date) -> (plan: String, windows: [SubscriptionWindow]) {
        let serverNow = subscriptionNumber(data["server_time"]).flatMap { $0 > 0 ? $0 : nil } ?? now.timeIntervalSince1970
        let plans = (data["plans"] as? [[String: Any]] ?? []).filter { plan in
            let end = subscriptionNumber(plan["ends_at"]) ?? 0
            return (plan["status"] as? String ?? "").lowercased() == "active" && !(end > 0 && end <= serverNow)
        }
        func same(_ bucket: [String: Any], _ plan: [String: Any]) -> Bool {
            let a = bucket["user_plan_id"] as? String ?? "", b = plan["user_plan_id"] as? String ?? ""
            if !a.isEmpty, !b.isEmpty { return a == b }
            return String(describing: bucket["plan_id"] ?? "") == String(describing: plan["plan_id"] ?? "")
        }
        var windows: [SubscriptionWindow] = []
        for (index, bucket) in (data["balances"] as? [[String: Any]] ?? []).enumerated() {
            guard plans.contains(where: { same(bucket, $0) }) else { continue }
            let expires = subscriptionNumber(bucket["expires_at"]) ?? 0
            if expires > 0, expires <= serverNow { continue }
            guard let total = subscriptionNumber(bucket["total_units"]), total > 0 else { continue }
            let used = subscriptionNumber(bucket["used_units"])
                ?? subscriptionNumber(bucket["remaining_units"]).map { total - $0 }
            guard let used else { continue }
            let models = (bucket["capabilities"] as? [String] ?? []).filter { $0.hasPrefix("model:") || !$0.contains(":") }
                .map { $0.replacingOccurrences(of: "model:", with: "") }
            let name = (bucket["show_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (models.isEmpty ? "credits" : models.joined(separator: ", "))
            windows.append(SubscriptionWindow(id: "gift-\(index)", name: name, usedPercent: percent(used: used, of: total),
                                              used: subscriptionDecimal(NSNumber(value: used)),
                                              limit: subscriptionDecimal(bucket["total_units"]), unit: "credits",
                                              resetsAt: expires > 0 ? Date(timeIntervalSince1970: expires) : nil))
        }
        return (plans.first?["name"] as? String ?? "Start Plan", windows)
    }
}
