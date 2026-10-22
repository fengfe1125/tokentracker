//
//  SubscriptionAuth.swift
//  TokenTrackerCore
//
//  TokenTracker 自己的登录与续期。每家走官方登录页，得到 TokenTracker 独立的
//  会话（与 Claude Code、Codex、Magpie 等互不影响），由 TokenTracker 自行刷新。
//
//  - 粘贴授权码：Claude、Gemini（PKCE）
//  - 设备码：Codex、Kimi、GitHub Copilot、Grok
//  - 浏览器登录后自动轮询：WorkBuddy、WorkBuddy AI、ZCode
//
//  登录与刷新请求只发往各家登记的认证域名；令牌只写入 SubscriptionAccountStore。
//

import Foundation
import CryptoKit

public enum SubscriptionAuthError: Error, Equatable, Sendable {
    case cancelled
    case timedOut
    case declined
    case invalidCode
    case invalidInput
    case unsupported
    case http(Int)
    case network
    case malformed
}

/// 一次进行中的登录。start 只发起；complete 阻塞直到完成（只在后台线程调用）。
public final class SubscriptionLoginFlow: @unchecked Sendable {
    public enum Prompt: Equatable, Sendable {
        /// 打开 url，输入 userCode 确认；TokenTracker 自动等待完成。
        case deviceCode(userCode: String, url: URL)
        /// 打开 url 授权后，把页面给出的授权码粘贴回来。
        case pasteCode(url: URL)
        /// 打开 url 登录；TokenTracker 自动等待完成。
        case browser(url: URL)
    }

    public let provider: SubscriptionProvider
    public let prompt: Prompt
    let finish: (_ pasted: String?, _ cancelled: @escaping () -> Bool) throws -> StoredSubscriptionAccount

    init(provider: SubscriptionProvider, prompt: Prompt,
         finish: @escaping (_ pasted: String?, _ cancelled: @escaping () -> Bool) throws -> StoredSubscriptionAccount) {
        self.provider = provider
        self.prompt = prompt
        self.finish = finish
    }

    public var needsPastedCode: Bool {
        if case .pasteCode = prompt { return true }
        return false
    }

    public func complete(pastedCode: String? = nil,
                         isCancelled: @escaping () -> Bool = { false }) throws -> StoredSubscriptionAccount {
        try finish(pastedCode, isCancelled)
    }
}

public enum SubscriptionAuth {
    /// 支持 TokenTracker 自己登录的供应商（顺序即菜单顺序）。
    public static let loginProviders: [SubscriptionProvider] = [
        .claude, .codex, .kimi, .gemini, .copilot, .grok, .workbuddy, .workbuddyAI, .zcode,
    ]

    /// 需要选择区域/站点的供应商及选项（第一个为默认）。
    public static func regions(for provider: SubscriptionProvider) -> [String] {
        switch provider {
        case .kimi: return ["cn", "global"]
        case .zcode: return ["zai", "bigmodel"]
        default: return []
        }
    }

    static let authHosts: [SubscriptionProvider: Set<String>] = [
        .claude: ["platform.claude.com", "api.anthropic.com"],
        .codex: ["auth.openai.com"],
        .kimi: ["auth.kimi.com", "auth.kimi.ai"],
        .gemini: ["oauth2.googleapis.com"],
        .copilot: ["github.com", "api.github.com"],
        .grok: ["auth.x.ai"],
        .workbuddy: ["copilot.tencent.com"],
        .workbuddyAI: ["www.workbuddy.ai"],
        .zcode: ["zcode.z.ai"],
    ]

    // ------------------------------------------------------------ 常量 ----

    static let claudeClientID = ClaudeBilling.clientID
    static let codexClientID = CodexBilling.clientID
    static let kimiClientID = KimiBilling.clientID
    static let geminiClientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    /// Gemini CLI 公开发布的已安装应用密钥（非机密，见 google-gemini/gemini-cli）。
    static let geminiClientSecret = "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"
    static let copilotClientID = "Iv1.b507a08c87ecfe98"
    static let grokClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let refreshMargin: TimeInterval = 5 * 60

    // ------------------------------------------------------------ 公共 ----

    static func send(_ provider: SubscriptionProvider, _ url: String, method: String = "POST",
                     headers: [String: String] = [:], body: Data? = nil,
                     _ transport: SubscriptionTransport) throws -> SubscriptionResponse {
        guard let endpoint = URL(string: url),
              SubscriptionHTTP.permits(endpoint, hosts: (authHosts[provider] ?? []).union(SubscriptionAdapters.hosts[provider] ?? [])) else {
            throw SubscriptionAuthError.malformed
        }
        var all = ["Accept": "application/json"]
        all.merge(headers) { $1 }
        let response = transport(SubscriptionRequest(url: endpoint, method: method, headers: all, body: body))
        if response.failure != nil { throw SubscriptionAuthError.network }
        return response
    }

    static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&").utf8)
    }

    static let formHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
    static let jsonHeaders = ["Content-Type": "application/json"]

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func randomURLSafe(_ bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents 不编码 "+"，授权服务器会把它当空格。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func expiry(_ data: [String: Any], now: Date) -> Date? {
        subscriptionNumber(data["expires_in"]).flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil }
    }

    /// 轮询直到 step 返回结果；step 返回 nil 表示仍在等待。
    static func poll<T>(interval: TimeInterval, deadline: Date, cancelled: () -> Bool,
                        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                        clock: () -> Date = Date.init,
                        _ step: (inout TimeInterval) throws -> T?) throws -> T {
        var wait = max(1, interval)
        while true {
            if cancelled() { throw SubscriptionAuthError.cancelled }
            if clock() > deadline { throw SubscriptionAuthError.timedOut }
            if let result = try step(&wait) { return result }
            var slept: TimeInterval = 0
            while slept < wait {
                if cancelled() { throw SubscriptionAuthError.cancelled }
                sleep(min(0.5, wait - slept))
                slept += 0.5
            }
        }
    }

    // ------------------------------------------------------------ 发起 ----

    public static func start(_ provider: SubscriptionProvider, region: String? = nil,
                             transport: @escaping SubscriptionTransport = SubscriptionHTTP.live,
                             now: @escaping () -> Date = Date.init,
                             sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> SubscriptionLoginFlow {
        switch provider {
        case .claude: return claudeStart(transport, now)
        case .gemini: return geminiStart(transport, now)
        case .codex: return try codexStart(transport, now, sleep)
        case .kimi: return try kimiStart(region == "global" ? "global" : "cn", transport, now, sleep)
        case .copilot: return try copilotStart(transport, now, sleep)
        case .grok: return try grokStart(transport, now, sleep)
        case .workbuddy, .workbuddyAI: return try workbuddyStart(provider, transport, now, sleep)
        case .zcode: return try zcodeStart(region == "bigmodel" ? "bigmodel" : "zai", transport, now, sleep)
        default: throw SubscriptionAuthError.unsupported
        }
    }

    // ---------------------------------------------------------- Claude ----

    static let claudeRedirect = "https://platform.claude.com/oauth/code/callback"

    static func claudeStart(_ transport: @escaping SubscriptionTransport, _ now: @escaping () -> Date) -> SubscriptionLoginFlow {
        let verifier = randomURLSafe(), state = randomURLSafe()
        let link = url("https://claude.com/cai/oauth/authorize", [
            ("code", "true"), ("client_id", claudeClientID), ("response_type", "code"),
            ("redirect_uri", claudeRedirect), ("scope", "user:profile user:inference user:sessions:claude_code"),
            ("code_challenge", challenge(verifier)), ("code_challenge_method", "S256"), ("state", state)])
        return SubscriptionLoginFlow(provider: .claude, prompt: .pasteCode(url: link)) { pasted, _ in
            // 页面给出 "code#state"。
            let parts = (pasted ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
            guard let code = parts.first.map(String.init), !code.isEmpty else { throw SubscriptionAuthError.invalidCode }
            if parts.count == 2, String(parts[1]) != state { throw SubscriptionAuthError.invalidCode }
            let response = try send(.claude, "https://platform.claude.com/v1/oauth/token", headers: jsonHeaders, body: json([
                "grant_type": "authorization_code", "code": code, "redirect_uri": claudeRedirect,
                "client_id": claudeClientID, "code_verifier": verifier, "state": state]), transport)
            guard response.status == 200, let access = response.json["access_token"] as? String else {
                throw response.status == 400 || response.status == 401 ? SubscriptionAuthError.invalidCode
                    : SubscriptionAuthError.http(response.status)
            }
            var account = response.json["account"] as? [String: Any] ?? [:]
            if account["uuid"] == nil {
                let profile = try? send(.claude, "https://api.anthropic.com/api/oauth/profile", method: "GET",
                                        headers: ["Authorization": "Bearer " + access, "anthropic-beta": "oauth-2025-04-20"], transport)
                account = profile?.json["account"] as? [String: Any] ?? [:]
            }
            return StoredSubscriptionAccount(
                provider: .claude, label: (account["email_address"] ?? account["email"]) as? String ?? "",
                kind: .oauth, origin: .login, token: access, refreshToken: response.json["refresh_token"] as? String,
                expiresAt: expiry(response.json, now: now()), accountID: account["uuid"] as? String)
        }
    }

    // ---------------------------------------------------------- Gemini ----

    static let geminiRedirect = "https://codeassist.google.com/authcode"

    static func geminiStart(_ transport: @escaping SubscriptionTransport, _ now: @escaping () -> Date) -> SubscriptionLoginFlow {
        let verifier = randomURLSafe(), state = randomURLSafe()
        let link = url("https://accounts.google.com/o/oauth2/v2/auth", [
            ("client_id", geminiClientID), ("redirect_uri", geminiRedirect), ("response_type", "code"),
            ("scope", "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"),
            ("access_type", "offline"), ("prompt", "consent"),
            ("code_challenge", challenge(verifier)), ("code_challenge_method", "S256"), ("state", state)])
        return SubscriptionLoginFlow(provider: .gemini, prompt: .pasteCode(url: link)) { pasted, _ in
            let code = (pasted ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { throw SubscriptionAuthError.invalidCode }
            let response = try send(.gemini, "https://oauth2.googleapis.com/token", headers: formHeaders, body: form([
                ("code", code), ("client_id", geminiClientID), ("client_secret", geminiClientSecret),
                ("redirect_uri", geminiRedirect), ("grant_type", "authorization_code"), ("code_verifier", verifier)]), transport)
            guard response.status == 200, let access = response.json["access_token"] as? String else {
                throw response.status == 400 ? SubscriptionAuthError.invalidCode : SubscriptionAuthError.http(response.status)
            }
            let claims = subscriptionJWTClaims(response.json["id_token"] as? String ?? "")
            return StoredSubscriptionAccount(
                provider: .gemini, label: claims["email"] as? String ?? "", kind: .oauth, origin: .login,
                token: access, refreshToken: response.json["refresh_token"] as? String,
                expiresAt: expiry(response.json, now: now()), accountID: claims["sub"] as? String)
        }
    }

    // ----------------------------------------------------------- Codex ----

    static func codexStart(_ transport: @escaping SubscriptionTransport, _ now: @escaping () -> Date,
                           _ sleep: @escaping (TimeInterval) -> Void) throws -> SubscriptionLoginFlow {
        let issuer = "https://auth.openai.com"
        let start = try send(.codex, issuer + "/api/accounts/deviceauth/usercode", headers: jsonHeaders,
                             body: json(["client_id": codexClientID]), transport)
        guard start.status == 200, let deviceID = start.json["device_auth_id"] as? String,
              let userCode = (start.json["user_code"] ?? start.json["usercode"]) as? String else {
            throw SubscriptionAuthError.http(start.status)
        }
        let interval = subscriptionNumber(start.json["interval"]) ?? 5
        let deadline = subscriptionDate(start.json["expires_at"]) ?? now().addingTimeInterval(15 * 60)
        return SubscriptionLoginFlow(provider: .codex, prompt: .deviceCode(userCode: userCode, url: URL(string: issuer + "/codex/device")!)) { _, cancelled in
            let grant: [String: Any] = try poll(interval: interval, deadline: deadline, cancelled: cancelled, sleep: sleep, clock: now) { _ in
                let r = try send(.codex, issuer + "/api/accounts/deviceauth/token", headers: jsonHeaders,
                                 body: json(["device_auth_id": deviceID, "user_code": userCode]), transport)
                if r.status == 200 { return r.json }
                if r.status == 403 || r.status == 404 { return nil }
                throw SubscriptionAuthError.http(r.status)
            }
            guard let code = grant["authorization_code"] as? String, let verifier = grant["code_verifier"] as? String else {
                throw SubscriptionAuthError.malformed
            }
            let token = try send(.codex, issuer + "/oauth/token", headers: formHeaders, body: form([
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", issuer + "/deviceauth/callback"),
                ("client_id", codexClientID), ("code_verifier", verifier)]), transport)
            guard token.status == 200, let access = token.json["access_token"] as? String else {
                throw SubscriptionAuthError.http(token.status)
            }
            return codexAccount(token.json, access: access, origin: .login, now: now())
        }
    }

    static func codexAccount(_ data: [String: Any], access: String, origin: StoredSubscriptionAccount.Origin,
                             now: Date) -> StoredSubscriptionAccount {
        let claims = subscriptionJWTClaims(access)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let idClaims = subscriptionJWTClaims(data["id_token"] as? String ?? "")
        let idAuth = idClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let account = auth["chatgpt_account_id"] as? String ?? idAuth["chatgpt_account_id"] as? String
        let user = auth["chatgpt_user_id"] as? String ?? auth["user_id"] as? String ?? idAuth["chatgpt_user_id"] as? String
        let expires = subscriptionNumber(claims["exp"]).map { Date(timeIntervalSince1970: $0) } ?? expiry(data, now: now)
        return StoredSubscriptionAccount(
            provider: .codex, label: idClaims["email"] as? String ?? "", kind: .oauth, origin: origin,
            token: access, refreshToken: data["refresh_token"] as? String, expiresAt: expires,
            extra: account.map { ["account": $0] } ?? [:],
            accountID: account.map { $0 + (user.map { ":" + $0 } ?? "") })
    }

    // ------------------------------------------------------------ Kimi ----

    static func kimiHosts(_ region: String) -> (auth: String, api: String) {
        region == "global" ? ("https://auth.kimi.ai", "api.kimi.ai") : ("https://auth.kimi.com", "api.kimi.com")
    }

    static func kimiHeaders(_ device: String) -> [String: String] {
        ["X-Msh-Platform": "kimi_code", "X-Msh-Version": TokenTrackerCore.version, "X-Msh-Device-Id": device,
         "X-Msh-Device-Name": "TokenTracker", "X-Msh-Device-Model": "macOS"]
    }

    static func kimiStart(_ region: String, _ transport: @escaping SubscriptionTransport, _ now: @escaping () -> Date,
                          _ sleep: @escaping (TimeInterval) -> Void) throws -> SubscriptionLoginFlow {
        let hosts = kimiHosts(region)
        let device = UUID().uuidString.lowercased()
        let headers = formHeaders.merging(kimiHeaders(device)) { $1 }
        let start = try send(.kimi, hosts.auth + "/api/oauth/device_authorization", headers: headers,
                             body: form([("client_id", kimiClientID)]), transport)
        guard start.status == 200, let userCode = start.json["user_code"] as? String,
              let deviceCode = start.json["device_code"] as? String,
              let link = ((start.json["verification_uri_complete"] ?? start.json["verification_uri"]) as? String).flatMap(URL.init) else {
            throw SubscriptionAuthError.http(start.status)
        }
        let deadline = now().addingTimeInterval(subscriptionNumber(start.json["expires_in"]) ?? 600)
        return SubscriptionLoginFlow(provider: .kimi, prompt: .deviceCode(userCode: userCode, url: link)) { _, cancelled in
            let data = try deviceTokenPoll(.kimi, hosts.auth + "/api/oauth/token", headers: headers,
                                           fields: [("client_id", kimiClientID), ("device_code", deviceCode)],
                                           interval: subscriptionNumber(start.json["interval"]) ?? 5, deadline: deadline,
                                           cancelled: cancelled, sleep: sleep, clock: now, transport)
            guard let access = data["access_token"] as? String else { throw SubscriptionAuthError.malformed }
            let claims = subscriptionJWTClaims(access)
            return StoredSubscriptionAccount(
                provider: .kimi, label: "", kind: .oauth, origin: .login, token: access,
                refreshToken: data["refresh_token"] as? String, expiresAt: expiry(data, now: now()),
                extra: ["host": hosts.api, "authHost": hosts.auth, "device": device],
                accountID: (claims["user_id"] ?? claims["sub"]) as? String)
        }
    }

    /// RFC 8628 设备码轮询：authorization_pending 继续、slow_down 加 5 秒。
    static func deviceTokenPoll(_ provider: SubscriptionProvider, _ endpoint: String, headers: [String: String],
                                fields: [(String, String)], interval: TimeInterval, deadline: Date,
                                cancelled: () -> Bool, sleep: @escaping (TimeInterval) -> Void, clock: () -> Date,
                                _ transport: @escaping SubscriptionTransport) throws -> [String: Any] {
        try poll(interval: interval, deadline: deadline, cancelled: cancelled, sleep: sleep, clock: clock) { wait in
            let r = try send(provider, endpoint, headers: headers,
                             body: form(fields + [("grant_type", "urn:ietf:params:oauth:grant-type:device_code")]), transport)
            if r.status == 200, r.json["access_token"] != nil { return r.json }
            switch r.json["error"] as? String {
            case "authorization_pending"?: return nil
            case "slow_down"?: wait += 5; return nil
            case "access_denied"?: throw SubscriptionAuthError.declined
            case "expired_token"?: throw SubscriptionAuthError.timedOut
            default: throw SubscriptionAuthError.http(r.status)
            }
        }
    }

    // --------------------------------------------------------- Copilot ----

    static func copilotStart(_ transport: @escaping SubscriptionTransport, _ now: @escaping () -> Date,
                             _ sleep: @escaping (TimeInterval) -> Void) throws -> SubscriptionLoginFlow {
        let start = try send(.copilot, "https://github.com/login/device/code", headers: formHeaders,
                             body: form([("client_id", copilotClientID), ("scope", "read:user")]), transport)
        guard start.status == 200, let userCode = start.json["user_code"] as? String,
              let deviceCode = start.json["device_code"] as? String,
              let link = (start.json["verification_uri"] as? String).flatMap(URL.init) else {
            throw SubscriptionAuthError.http(start.status)
        }
        let deadline = now().addingTimeInterval(subscriptionNumber(start.json["expires_in"]) ?? 900)
        return SubscriptionLoginFlow(provider: .copilot, prompt: .deviceCode(userCode: userCode, url: link)) { _, cancelled in
            let data = try deviceTokenPoll(.copilot, "https://github.com/login/oauth/access_token", headers: formHeaders,
                                           fields: [("client_id", copilotClientID), ("device_code", deviceCode)],
                                           interval: subscriptionNumber(start.json["interval"]) ?? 5, deadline: deadline,
                                           cancelled: cancelled, sleep: sleep, clock: now, transport)
            guard let access = data["access_token"] as? String else { throw SubscriptionAuthError.malformed }
            let user = try? send(.copilot, "https://api.github.com/user", method: "GET",
                                 headers: ["Authorization": "token " + access, "User-Agent": "TokenTracker"], transport)
            let id = (user?.json["id"] as? NSNumber)?.stringValue
            return StoredSubscriptionAccount(provider: .copilot, label: user?.json["login"] as? String ?? "",
                                             kind: .oauth, origin: .login, token: access,
                                             refreshToken: data["refresh_token"] as? String,
                                             expiresAt: expiry(data, now: now()), accountID: id)
        }
    }

    // ------------------------------------------------------------ Grok ----

    static func grokStart(_ transport: @escaping SubscriptionTransport, _ now: @escaping () -> Date,
                          _ sleep: @escaping (TimeInterval) -> Void) throws -> SubscriptionLoginFlow {
        let start = try send(.grok, "https://auth.x.ai/oauth2/device/code", headers: formHeaders, body: form([
            ("client_id", grokClientID), ("scope", "openid profile email offline_access grok-cli:access api:access")]), transport)
        guard start.status == 200, let userCode = start.json["user_code"] as? String,
              let deviceCode = start.json["device_code"] as? String,
              let link = ((start.json["verification_uri_complete"] ?? start.json["verification_uri"]) as? String).flatMap(URL.init) else {
            throw SubscriptionAuthError.http(start.status)
        }
        let deadline = now().addingTimeInterval(subscriptionNumber(start.json["expires_in"]) ?? 600)
        return SubscriptionLoginFlow(provider: .grok, prompt: .deviceCode(userCode: userCode, url: link)) { _, cancelled in
            let data = try deviceTokenPoll(.grok, "https://auth.x.ai/oauth2/token", headers: formHeaders,
                                           fields: [("client_id", grokClientID), ("device_code", deviceCode)],
                                           interval: subscriptionNumber(start.json["interval"]) ?? 5, deadline: deadline,
                                           cancelled: cancelled, sleep: sleep, clock: now, transport)
            guard let access = data["access_token"] as? String else { throw SubscriptionAuthError.malformed }
            let claims = subscriptionJWTClaims(data["id_token"] as? String ?? access)
            return StoredSubscriptionAccount(provider: .grok, label: claims["email"] as? String ?? "", kind: .oauth,
                                             origin: .login, token: access, refreshToken: data["refresh_token"] as? String,
                                             expiresAt: expiry(data, now: now()),
                                             accountID: (claims["sub"] ?? subscriptionJWTClaims(access)["sub"]) as? String)
        }
    }

    // ------------------------------------------------------- WorkBuddy ----

    static func workbuddyEndpoint(_ provider: SubscriptionProvider) -> String {
        provider == .workbuddy ? "https://copilot.tencent.com" : "https://www.workbuddy.ai"
    }

    static let workbuddyHeaders = ["Content-Type": "application/json", "User-Agent": "WorkBuddy/5.5.6"]

    /// WorkBuddy 的 {code, msg, data} 包装：返回 (code, data)。
    static func workbuddyCall(_ provider: SubscriptionProvider, _ method: String, _ path: String,
                              headers: [String: String], _ transport: @escaping SubscriptionTransport) throws -> (Int, [String: Any]) {
        let r = try send(provider, workbuddyEndpoint(provider) + path, method: method,
                         headers: workbuddyHeaders.merging(headers) { $1 }, body: method == "POST" ? Data("{}".utf8) : nil, transport)
        let code = Int(subscriptionNumber(r.json["code"]) ?? 0)
        if r.status != 200, code == 0 { throw SubscriptionAuthError.http(r.status) }
        return (code, r.json["data"] as? [String: Any] ?? [:])
    }

    static func workbuddyTokens(_ data: [String: Any], now: Date, into account: inout StoredSubscriptionAccount) {
        if let access = data["accessToken"] as? String { account.token = access }
        if let refresh = data["refreshToken"] as? String, !refresh.isEmpty { account.refreshToken = refresh }
        if let domain = data["domain"] as? String, !domain.isEmpty { account.extra["domain"] = domain }
        if let at = subscriptionNumber(data["expiresAt"]), at > 0 { account.expiresAt = subscriptionDate(NSNumber(value: at)) }
        else if let seconds = subscriptionNumber(data["expiresIn"]), seconds > 0 { account.expiresAt = now.addingTimeInterval(seconds) }
    }

    static func workbuddyStart(_ provider: SubscriptionProvider, _ transport: @escaping SubscriptionTransport,
                               _ now: @escaping () -> Date, _ sleep: @escaping (TimeInterval) -> Void) throws -> SubscriptionLoginFlow {
        let platform = provider == .workbuddy ? "workbuddy" : "workbuddy-ai"
        let (code, state) = try workbuddyCall(provider, "POST", "/v2/plugin/auth/state?platform=" + platform, headers: [
            "X-No-Authorization": "true", "X-No-User-Id": "true", "X-No-Enterprise-Id": "true",
            "X-No-Department-Info": "true"], transport)
        guard code == 0, let key = state["state"] as? String, let auth = state["authUrl"] as? String,
              var components = URLComponents(string: auth), components.scheme == "https" else {
            throw SubscriptionAuthError.malformed
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "version", value: "2.0.0"),
                                                                 URLQueryItem(name: "loginSessionId", value: randomURLSafe(16))]
        guard let link = components.url else { throw SubscriptionAuthError.malformed }
        let query = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        let deadline = now().addingTimeInterval(5 * 60)
        return SubscriptionLoginFlow(provider: provider, prompt: .browser(url: link)) { _, cancelled in
            var account = StoredSubscriptionAccount(provider: provider, kind: .oauth, origin: .login, token: "")
            let tokens: [String: Any] = try poll(interval: 1, deadline: deadline, cancelled: cancelled, sleep: sleep, clock: now) { _ in
                let (code, data) = try workbuddyCall(provider, "GET", "/v2/plugin/auth/token?state=" + query, headers: [:], transport)
                if code == 11217 || (code == 0 && data.isEmpty) { return nil }
                guard code == 0 else { throw SubscriptionAuthError.http(code) }
                return data
            }
            workbuddyTokens(tokens, now: now(), into: &account)
            guard !account.token.isEmpty else { throw SubscriptionAuthError.malformed }
            let host = URL(string: workbuddyEndpoint(provider))!.host!
            let who: [String: Any] = try poll(interval: 1, deadline: deadline, cancelled: cancelled, sleep: sleep, clock: now) { _ in
                let (code, data) = try workbuddyCall(provider, "GET", "/v2/plugin/login/account?state=" + query, headers: [
                    "Authorization": "Bearer " + account.token, "X-Domain": account.extra["domain"] ?? host,
                    "X-No-User-Id": "true", "X-No-Enterprise-Id": "true"], transport)
                if code == 12151 || (code == 0 && data.isEmpty) { return nil }
                guard code == 0 else { throw SubscriptionAuthError.http(code) }
                return data
            }
            let uid = who["uid"] as? String ?? ""
            account.extra["uid"] = uid
            account.accountID = uid.isEmpty ? nil : uid
            account.label = (who["nickname"] ?? who["phoneNumber"]) as? String ?? ""
            return account
        }
    }

    // ----------------------------------------------------------- ZCode ----

    static func zcodeStart(_ site: String, _ transport: @escaping SubscriptionTransport, _ now: @escaping () -> Date,
                           _ sleep: @escaping (TimeInterval) -> Void) throws -> SubscriptionLoginFlow {
        let base = "https://zcode.z.ai"
        let pollAuth = "Bearer " + randomURLSafe(32)
        let device = UUID().uuidString.lowercased()
        let headers = ["Content-Type": "application/json", "User-Agent": "ZCode/3.14.3",
                       "Authorization": pollAuth, "X-Device-Mid": device]
        let start = try send(.zcode, base + "/api/v1/oauth/cli/init", headers: headers, body: json(["provider": site]), transport)
        guard start.status == 200, let data = SubscriptionAdapters.zaiData(start.json),
              let flow = data["flow_id"] as? String, let auth = data["authorize_url"] as? String,
              var components = URLComponents(string: auth), components.scheme == "https" else {
            throw SubscriptionAuthError.http(start.status)
        }
        // Z.ai / BigModel 登录后回到 ZCode 的回调页，由它完成授权（与 ZCode 自身一致）。
        let back = url(base + "/app/oauth/login", [("redirect", "zcode://oauth/callback"), ("app_version", "3.14.3")]).absoluteString
        let name = site == "bigmodel" ? "redirect" : "redirect_uri"
        components.queryItems = (components.queryItems ?? []).filter { $0.name != name } + [URLQueryItem(name: name, value: back)]
        guard let link = components.url else { throw SubscriptionAuthError.malformed }
        let interval = max(1, subscriptionNumber(data["poll_interval_sec"]) ?? 2)
        let deadline = subscriptionDate(data["expires_at"]) ?? now().addingTimeInterval(5 * 60)
        let flowPath = flow.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? flow
        return SubscriptionLoginFlow(provider: .zcode, prompt: .browser(url: link)) { _, cancelled in
            let got: [String: Any] = try poll(interval: interval, deadline: deadline, cancelled: cancelled, sleep: sleep, clock: now) { _ in
                let r = try send(.zcode, base + "/api/v1/oauth/cli/poll/" + flowPath, method: "GET", headers: headers, transport)
                if r.status == 408 || r.status == 429 || r.status >= 500 { return nil }
                guard r.status == 200, let d = SubscriptionAdapters.zaiData(r.json) else { throw SubscriptionAuthError.http(r.status) }
                switch d["status"] as? String {
                case "ready"?: return d
                case "failed"?: throw SubscriptionAuthError.declined
                default: return nil
                }
            }
            guard let jwt = got["token"] as? String, !jwt.isEmpty else { throw SubscriptionAuthError.malformed }
            let user = got["user"] as? [String: Any] ?? [:]
            let email = (user["email"] as? String ?? "").replacingOccurrences(of: "@phone.local", with: "")
            let claims = subscriptionJWTClaims(jwt)
            return StoredSubscriptionAccount(
                provider: .zcode, label: email.isEmpty ? user["name"] as? String ?? "" : email, kind: .oauth, origin: .login,
                token: jwt, expiresAt: subscriptionNumber(claims["exp"]).map { Date(timeIntervalSince1970: $0) },
                extra: ["jwt": jwt, "device": device, "site": site],
                accountID: (user["user_id"] as? String) ?? (claims["sub"] as? String) ?? (email.isEmpty ? nil : email))
        }
    }

    // ------------------------------------------------------------ 续期 ----

    public enum RefreshResult: Equatable, Sendable {
        case notNeeded
        case refreshed
        /// 刷新令牌被拒（需重新登录）。
        case rejected
        /// 网络等临时问题，稍后再试。
        case failed
    }

    static func needsRefresh(_ account: StoredSubscriptionAccount, now: Date) -> Bool {
        guard let expiry = account.expiresAt else { return false }
        return expiry.timeIntervalSince(now) < refreshMargin
    }

    /// 用 TokenTracker 自己的刷新令牌换新会话。只改动传入的账号记录。
    static func refresh(_ account: inout StoredSubscriptionAccount, now: Date,
                        transport: @escaping SubscriptionTransport) -> RefreshResult {
        guard account.kind == .oauth, let refresh = account.refreshToken, !refresh.isEmpty else { return .notNeeded }
        do {
            let response: SubscriptionResponse
            switch account.provider {
            case .claude:
                response = try send(.claude, "https://platform.claude.com/v1/oauth/token", headers: jsonHeaders, body: json([
                    "grant_type": "refresh_token", "refresh_token": refresh, "client_id": claudeClientID]), transport)
            case .codex:
                response = try send(.codex, "https://auth.openai.com/oauth/token", headers: jsonHeaders, body: json([
                    "client_id": codexClientID, "grant_type": "refresh_token", "refresh_token": refresh,
                    "scope": "openid profile email"]), transport)
            case .kimi:
                let host = account.extra["authHost"] ?? "https://auth.kimi.com"
                response = try send(.kimi, host + "/api/oauth/token",
                                    headers: formHeaders.merging(kimiHeaders(account.extra["device"] ?? account.id)) { $1 },
                                    body: form([("client_id", kimiClientID), ("grant_type", "refresh_token"),
                                                ("refresh_token", refresh)]), transport)
            case .gemini:
                response = try send(.gemini, "https://oauth2.googleapis.com/token", headers: formHeaders, body: form([
                    ("client_id", geminiClientID), ("client_secret", geminiClientSecret),
                    ("grant_type", "refresh_token"), ("refresh_token", refresh)]), transport)
            case .grok:
                response = try send(.grok, "https://auth.x.ai/oauth2/token", headers: formHeaders, body: form([
                    ("client_id", grokClientID), ("grant_type", "refresh_token"), ("refresh_token", refresh)]), transport)
            case .copilot:
                response = try send(.copilot, "https://github.com/login/oauth/access_token", headers: formHeaders, body: form([
                    ("client_id", copilotClientID), ("grant_type", "refresh_token"), ("refresh_token", refresh)]), transport)
            case .workbuddy, .workbuddyAI:
                let host = URL(string: workbuddyEndpoint(account.provider))!.host!
                let (code, data) = try workbuddyCall(account.provider, "POST", "/v2/plugin/auth/token/refresh", headers: [
                    "X-Refresh-Token": refresh, "X-Auth-Refresh-Source": "plugin",
                    "X-Domain": account.extra["domain"] ?? host], transport)
                guard code == 0, data["accessToken"] is String else { return code == 0 ? .failed : .rejected }
                workbuddyTokens(data, now: now, into: &account)
                return .refreshed
            default:
                return .notNeeded
            }
            guard response.status == 200, let access = response.json["access_token"] as? String else {
                return [400, 401, 403].contains(response.status) ? .rejected : .failed
            }
            account.token = access
            if let next = response.json["refresh_token"] as? String, !next.isEmpty { account.refreshToken = next }
            if account.provider == .codex {
                account.expiresAt = subscriptionNumber(subscriptionJWTClaims(access)["exp"]).map { Date(timeIntervalSince1970: $0) }
                    ?? expiry(response.json, now: now)
            } else {
                account.expiresAt = expiry(response.json, now: now) ?? account.expiresAt.map { _ in now.addingTimeInterval(3600) }
            }
            return .refreshed
        } catch {
            return .failed
        }
    }
}
