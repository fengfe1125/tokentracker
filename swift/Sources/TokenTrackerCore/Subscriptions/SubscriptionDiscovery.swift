//
//  SubscriptionDiscovery.swift
//  TokenTrackerCore
//
//  本机账号发现：只解析约定位置的已知配置（JSON / .env / 简单 YAML 键值），
//  不遍历全盘、不读浏览器 Cookie、不执行配置脚本、不加载插件代码。
//  Magpie 只作为配置来源读取账号和凭据引用，不导入其配额缓存。
//
//  去重：同一供应商下，供应商账号 ID 相同或凭据完全相同才合并；
//  不凭邮箱猜测，不叠加多把 Key。
//

import Foundation

public struct SubscriptionDiscovery {
    public var home: String
    public var env: [String: String]
    var keychainRead: () -> [String: Any]?

    public init(home: String = NSHomeDirectory(),
                env: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(home: home, env: env, keychainRead: { BillingContext.defaultKeychainRead() })
    }

    init(home: String, env: [String: String], keychainRead: @escaping () -> [String: Any]?) {
        self.home = home
        self.env = env
        self.keychainRead = keychainRead
    }

    public func discover(extraDirectories: [String] = []) -> [SubscriptionAccount] {
        var found: [SubscriptionAccount] = []

        // Claude Code：钥匙串与 .credentials.json（当前登录）
        let claudeTool = "Claude Code"
        if let bundle = keychainRead(), let oauth = bundle["claudeAiOauth"] as? [String: Any] {
            found += claudeOAuth(oauth, SubscriptionSource(tool: claudeTool, location: "钥匙串"), active: true)
        }
        let claudeFile = root("CLAUDE_CONFIG_DIR", ".claude") + "/.credentials.json"
        if let oauth = json(claudeFile)?["claudeAiOauth"] as? [String: Any] {
            found += claudeOAuth(oauth, source(claudeTool, claudeFile), active: true)
        }

        // Codex CLI（当前登录）与 TokenTracker 保存的 Codex 账号
        let codexFile = root("CODEX_HOME", ".codex") + "/auth.json"
        if let tokens = json(codexFile)?["tokens"] as? [String: Any] {
            found += codexTokens(tokens, source("Codex", codexFile), active: true)
        }
        for saved in CodexAccountStore(home: home).load() {
            guard let tokens = saved.bundle["tokens"] as? [String: Any] else { continue }
            found += codexTokens(tokens, SubscriptionSource(tool: "TokenTracker", location: "已保存的 Codex 账号"),
                                 label: saved.email ?? saved.name)
        }

        // Kimi Code（当前登录）
        let kimiFile = root("KIMI_CODE_HOME", ".kimi-code") + "/credentials/kimi-code.json"
        if let cred = json(kimiFile) {
            found += kimiOAuth(cred, source("Kimi Code", kimiFile), host: kimiHost(), active: true)
        }

        // OpenCode：auth.json + opencode.json 里的自定义 baseURL
        let xdgData = env["XDG_DATA_HOME"].map(expandPath) ?? home + "/.local/share"
        let xdgConfig = env["XDG_CONFIG_HOME"].map(expandPath) ?? home + "/.config"
        let openCodeOverrides = openCodeBaseURLs([xdgConfig + "/opencode/opencode.json",
                                                  xdgConfig + "/opencode/opencode.jsonc"])
        for path in [xdgData + "/opencode/auth.json", xdgConfig + "/opencode/auth.json"] {
            if let entries = json(path) {
                found += authEntries(entries, source("OpenCode", path), owner: .go, baseURLs: openCodeOverrides)
            }
        }

        // Pi
        let piFile = (env["PI_CODING_AGENT_DIR"].map(expandPath) ?? home + "/.pi/agent") + "/auth.json"
        if let entries = json(piFile) { found += authEntries(entries, source("Pi", piFile)) }

        // Gemini CLI
        let geminiDir = home + "/.gemini"
        if let creds = json(geminiDir + "/oauth_creds.json") {
            found += geminiOAuth(creds, source("Gemini CLI", geminiDir + "/oauth_creds.json"),
                                 activeEmail: (json(geminiDir + "/google_accounts.json")?["active"] as? String))
        }
        found += envKeys(envFile(geminiDir + "/.env"), source("Gemini CLI", geminiDir + "/.env"))

        // Magpie（只读账号与凭据引用）
        found += magpie(root("MAGPIE_HOME", ".config/magpie"), tool: "Magpie")

        // DSH：.credentials.yaml 的 refs（不含 DSH 账号平台额度与第三方免费模型）
        let dsh = home + "/.dsh"
        var dshFiles = [dsh + "/.credentials.yaml"]
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: dsh + "/profiles") {
            dshFiles += profiles.sorted().map { dsh + "/profiles/" + $0 + "/.credentials.yaml" }
        }
        for path in dshFiles { found += envKeys(yamlBlock(path, "refs"), source("DSH", path)) }

        // Hermes
        let hermes = root("HERMES_HOME", ".hermes")
        found += envKeys(envFile(hermes + "/.env"), source("Hermes", hermes + "/.env"))

        // 进程环境变量（GUI 启动时通常为空；终端启动时生效）
        found += envKeys(env, nil)

        for directory in extraDirectories { found += customDirectory(expandPath(directory)) }
        return Self.merge(found)
    }

    // ------------------------------------------------------------ 路径 ----

    private func root(_ variable: String, _ fallback: String) -> String {
        env[variable].flatMap { $0.isEmpty ? nil : expandPath($0) } ?? home + "/" + fallback
    }

    private func source(_ tool: String, _ path: String) -> SubscriptionSource {
        SubscriptionSource(tool: tool, location: path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }

    private func data(_ path: String) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? Int, size <= 4 << 20 else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    private func json(_ path: String) -> [String: Any]? {
        data(path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    /// 带注释的 JSONC：去掉整行 // 注释后再解析（不处理字符串内的注释符）。
    private func jsonc(_ path: String) -> [String: Any]? {
        guard let text = data(path).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let stripped = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        return (try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) as? [String: Any]
    }

    /// KEY=VALUE（可带 export 与引号）。插值与命令替换不解析、不执行。
    func envFile(_ path: String) -> [String: String] {
        guard let text = data(path).flatMap({ String(data: $0, encoding: .utf8) }) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard let value = literal(String(line[line.index(after: eq)...])) else { continue }
            out[key] = value
        }
        return out
    }

    /// 读取简单 YAML 中某个顶层块下一级的 `NAME: value`。
    func yamlBlock(_ path: String, _ block: String) -> [String: String] {
        guard let text = data(path).flatMap({ String(data: $0, encoding: .utf8) }) else { return [:] }
        var out: [String: String] = [:]
        var inside = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indented = line.first == " " || line.first == "\t"
            if !indented { inside = trimmed == block + ":"; continue }
            guard inside, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon])
            if let value = literal(String(trimmed[trimmed.index(after: colon)...])) { out[key] = value }
        }
        return out
    }

    /// 去引号与行尾注释；空值、插值、命令替换、引用语法一律视为不可用。
    private func literal(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = String(value.dropFirst())
            guard let end = value.firstIndex(of: quote) else { return nil }
            value = String(value[..<end])
        } else if let hash = value.range(of: " #") {
            value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty, !value.contains("${"), !value.contains("$("), !value.hasPrefix("{"),
              !value.hasPrefix("["), !value.hasPrefix("!"), !value.contains(" ") else { return nil }
        return value
    }

    // ------------------------------------------------------ 各家凭据格式 ----

    private func claudeOAuth(_ oauth: [String: Any], _ source: SubscriptionSource, active: Bool = false,
                             label: String = "", accountID: String? = nil, plan: String? = nil) -> [SubscriptionAccount] {
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return [SubscriptionAccount(provider: .claude, label: label, source: source, isActive: active,
                                        credential: nil, providerAccountID: accountID)]
        }
        let subscription = oauth["subscriptionType"] as? String ?? plan ?? ""
        let credential = SubscriptionCredential(kind: .oauth, token: token, expiresAt: subscriptionDate(oauth["expiresAt"]),
                                                extra: subscription.isEmpty ? [:] : ["plan": subscription])
        return [SubscriptionAccount(provider: .claude, label: label,
                                    planHint: SubscriptionAdapters.claudePlan(subscription),
                                    source: source, isActive: active, credential: credential,
                                    providerAccountID: accountID)]
    }

    private func codexTokens(_ tokens: [String: Any], _ source: SubscriptionSource, active: Bool = false,
                             label: String? = nil) -> [SubscriptionAccount] {
        guard let token = (tokens["access_token"] ?? tokens["access"]) as? String, !token.isEmpty else { return [] }
        let claims = subscriptionJWTClaims(token)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let account = tokens["account_id"] as? String ?? tokens["accountId"] as? String
            ?? auth["chatgpt_account_id"] as? String
        let user = auth["chatgpt_user_id"] as? String ?? auth["user_id"] as? String
        let idClaims = subscriptionJWTClaims(tokens["id_token"] as? String ?? "")
        let email = label ?? idClaims["email"] as? String
            ?? (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String ?? ""
        let expiry = subscriptionNumber(claims["exp"]).map { Date(timeIntervalSince1970: $0) }
            ?? subscriptionDate(tokens["expires"])
        let credential = SubscriptionCredential(kind: .oauth, token: token, expiresAt: expiry,
                                                extra: account.map { ["account": $0] } ?? [:])
        // 同一 ChatGPT 工作区的不同成员各有额度：账号 ID + 用户 ID 才是额度身份。
        let identity = account.map { $0 + (user.map { ":" + $0 } ?? "") }
        return [SubscriptionAccount(provider: .codex, label: email, source: source, isActive: active,
                                    credential: credential, providerAccountID: identity)]
    }

    private func kimiHost() -> String {
        URL(string: KimiBilling(ctx: BillingContext(home: home, env: env)).apiBase())?.host ?? "api.kimi.com"
    }

    private func kimiOAuth(_ cred: [String: Any], _ source: SubscriptionSource, host: String,
                           active: Bool = false) -> [SubscriptionAccount] {
        guard let token = (cred["access_token"] ?? cred["access"]) as? String, !token.isEmpty else {
            return [SubscriptionAccount(provider: .kimi, source: source, isActive: active, credential: nil)]
        }
        let claims = subscriptionJWTClaims(token)
        let expiry = subscriptionDate(cred["expires_at"] ?? cred["expires"])
            ?? subscriptionNumber(claims["exp"]).map { Date(timeIntervalSince1970: $0) }
        let credential = SubscriptionCredential(kind: .oauth, token: token, expiresAt: expiry, extra: ["host": host])
        let user = claims["user_id"] as? String ?? claims["sub"] as? String
        return [SubscriptionAccount(provider: .kimi, source: source, isActive: active,
                                    credential: credential, providerAccountID: user)]
    }

    private func geminiOAuth(_ creds: [String: Any], _ source: SubscriptionSource,
                             activeEmail: String?) -> [SubscriptionAccount] {
        guard let token = (creds["access_token"] ?? creds["access"]) as? String, !token.isEmpty else { return [] }
        let idClaims = subscriptionJWTClaims(creds["id_token"] as? String ?? "")
        let credential = SubscriptionCredential(kind: .oauth, token: token,
                                                expiresAt: subscriptionDate(creds["expiry_date"] ?? creds["expires"]),
                                                extra: (creds["projectId"] as? String).map { ["project": $0] } ?? [:])
        return [SubscriptionAccount(provider: .gemini, label: idClaims["email"] as? String ?? activeEmail ?? "",
                                    source: source, isActive: true, credential: credential,
                                    providerAccountID: idClaims["sub"] as? String)]
    }

    /// OpenCode / Pi 风格的 auth.json：{ providerName: {type, key | access, refresh, expires} }。
    private func authEntries(_ entries: [String: Any], _ source: SubscriptionSource,
                             owner: SubscriptionProvider? = nil, baseURLs: [String: String] = [:]) -> [SubscriptionAccount] {
        var out: [SubscriptionAccount] = []
        for name in entries.keys.sorted() {
            guard let entry = entries[name] as? [String: Any] else { continue }
            out += authEntry(name.lowercased(), entry, source, owner: owner, baseURL: baseURLs[name.lowercased()])
        }
        return out
    }

    private func authEntry(_ name: String, _ entry: [String: Any], _ source: SubscriptionSource,
                           owner: SubscriptionProvider?, baseURL: String?) -> [SubscriptionAccount] {
        let key = (entry["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let access = (entry["access"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expires = subscriptionDate(entry["expires"])
        func apiKey(_ provider: SubscriptionProvider, extra: [String: String] = [:]) -> [SubscriptionAccount] {
            guard let key else { return [] }
            if let problem = relayProblem(provider, baseURL) {
                return [SubscriptionAccount(provider: provider, source: source, credential: nil, discoveryProblem: problem)]
            }
            return [SubscriptionAccount(provider: provider, source: source, isActive: owner == provider,
                                        credential: SubscriptionCredential(kind: .apiKey, token: key, extra: extra))]
        }
        switch name {
        case "anthropic", "claude":
            if access != nil {
                return claudeOAuth(["accessToken": access as Any, "expiresAt": entry["expires"] as Any], source)
            }
            return key.map { _ in [SubscriptionAccount(provider: .claude, source: source, credential: nil,
                                                      discoveryProblem: .apiKeyOnly)] } ?? []
        case "openai", "openai-codex", "codex":
            guard let access else { return [] }
            return codexTokens(["access_token": access, "accountId": entry["accountId"] as Any,
                                "expires": entry["expires"] as Any], source)
        case "kimi-for-coding", "kimi-coding", "kimi":
            if let access { return kimiOAuth(["access": access, "expires": entry["expires"] as Any], source, host: "api.kimi.com") }
            return apiKey(.kimi, extra: ["host": "api.kimi.com"])
        case "opencode-go":
            return apiKey(.go)
        case "deepseek":
            return apiKey(.deepseek)
        case "minimax", "minimax-cn":
            return apiKey(.minimax, extra: ["host": name == "minimax-cn" ? "api.minimaxi.com" : "api.minimax.io"])
        case "github-copilot", "copilot":
            // OpenCode 的 refresh 是 GitHub OAuth token，access 是短期 Copilot token；只用前者。
            let candidates = [entry["refresh"], entry["access"], entry["key"]].compactMap { $0 as? String }
            guard let token = candidates.first(where: Self.isGitHubToken) else { return [] }
            return [SubscriptionAccount(provider: .copilot, source: source,
                                        credential: SubscriptionCredential(kind: .oauth, token: token))]
        case "xai", "grok":
            guard let access else { return key.map { _ in [SubscriptionAccount(provider: .grok, source: source, credential: nil,
                                                                              discoveryProblem: .apiKeyOnly)] } ?? [] }
            let sub = subscriptionJWTClaims(access)["sub"] as? String
            return [SubscriptionAccount(provider: .grok, label: entry["accountId"] as? String ?? "", source: source,
                                        credential: SubscriptionCredential(kind: .oauth, token: access, expiresAt: expires),
                                        providerAccountID: sub)]
        case "google-gemini-cli", "gemini-cli":
            guard access != nil else { return [] }
            return geminiOAuth(["access": access as Any, "expires": entry["expires"] as Any,
                                "projectId": entry["projectId"] as Any], source, activeEmail: entry["email"] as? String)
                .map { var a = $0; a.isActive = false; return a }
        case "google", "gemini":
            return key.map { _ in [SubscriptionAccount(provider: .gemini, source: source, credential: nil,
                                                      discoveryProblem: .apiKeyOnly)] } ?? []
        default:
            return []
        }
    }

    static func isGitHubToken(_ token: String) -> Bool {
        ["gho_", "ghu_", "ghp_", "github_pat_"].contains { token.hasPrefix($0) }
    }

    /// 配置了非官方 baseURL 的 Key 属于中转服务，不发往官方域名。
    private func relayProblem(_ provider: SubscriptionProvider, _ baseURL: String?) -> SubscriptionProblem? {
        guard let baseURL, !baseURL.isEmpty else { return nil }
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return .relayEndpoint }
        let official = (SubscriptionAdapters.hosts[provider] ?? []).union(Self.inferenceHosts[provider] ?? [])
        return official.contains(host) ? nil : .relayEndpoint
    }

    static let inferenceHosts: [SubscriptionProvider: Set<String>] = [
        .kimi: ["api.kimi.com", "api.kimi.ai"], .deepseek: ["api.deepseek.com"],
        .minimax: ["api.minimaxi.com", "api.minimax.io"], .go: ["opencode.ai"],
    ]

    /// opencode.json(c)：provider.<name>.options.baseURL。
    private func openCodeBaseURLs(_ paths: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for path in paths {
            guard let providers = jsonc(path)?["provider"] as? [String: Any] else { continue }
            for (name, value) in providers {
                if let url = ((value as? [String: Any])?["options"] as? [String: Any])?["baseURL"] as? String {
                    out[name.lowercased()] = url
                }
            }
        }
        return out
    }

    /// 已知环境变量名（.env、DSH refs、进程环境）。同源 *_BASE_URL 指向非官方域名时视为中转。
    private func envKeys(_ values: [String: String], _ source: SubscriptionSource?) -> [SubscriptionAccount] {
        let known: [(String, SubscriptionProvider, [String: String])] = [
            ("DEEPSEEK_API_KEY", .deepseek, [:]),
            ("OPENCODE_GO_API_KEY", .go, [:]), ("OPENCODE_API_KEY", .go, [:]),
            ("KIMI_API_KEY", .kimi, ["host": "api.kimi.com"]),
            ("MINIMAX_CN_API_KEY", .minimax, ["host": "api.minimaxi.com"]),
            ("MINIMAX_API_KEY", .minimax, ["host": "api.minimax.io"]),
            ("GEMINI_API_KEY", .gemini, [:]),
        ]
        var out: [SubscriptionAccount] = []
        for (name, provider, extra) in known {
            guard let value = values[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  literal(value) != nil else { continue }
            // KIMI_API_KEY 也常用于 Moonshot 开放平台；只有 Kimi Code 的 Key 能读编程配额。
            if provider == .kimi, !value.hasPrefix("sk-kimi-") { continue }
            let src = source ?? SubscriptionSource(tool: "环境变量", location: name)
            let prefix = String(name.dropLast("_API_KEY".count))
            if provider == .gemini {
                out.append(SubscriptionAccount(provider: .gemini, source: src, credential: nil, discoveryProblem: .apiKeyOnly))
            } else if let problem = relayProblem(provider, values[prefix + "_BASE_URL"]) {
                out.append(SubscriptionAccount(provider: provider, source: src, credential: nil, discoveryProblem: problem))
            } else {
                out.append(SubscriptionAccount(provider: provider, source: src, isActive: source == nil && provider == .go,
                                               credential: SubscriptionCredential(kind: .apiKey, token: value, extra: extra)))
            }
        }
        return out
    }

    // ------------------------------------------------------------ Magpie ----

    private func magpie(_ dir: String, tool: String) -> [SubscriptionAccount] {
        var out: [SubscriptionAccount] = []
        if let rows = data(dir + "/logins.json").flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] {
            let src = source(tool, dir + "/logins.json")
            for row in rows {
                guard let agent = (row["agent"] as? String)?.lowercased() else { continue }
                let auth = row["auth"] as? [String: Any] ?? [:]
                let profile = row["profile"] as? [String: Any] ?? [:]
                let label = row["user"] as? String ?? profile["emailAddress"] as? String ?? ""
                switch agent {
                case "claude", "claude-code":
                    let oauth = auth["claudeAiOauth"] as? [String: Any] ?? [:]
                    out += claudeOAuth(oauth, src, label: label, accountID: profile["accountUuid"] as? String,
                                       plan: row["plan"] as? String)
                case "codex":
                    if let tokens = auth["tokens"] as? [String: Any] { out += codexTokens(tokens, src, label: label) }
                default:
                    out += authEntry(agent, auth, src, owner: nil, baseURL: nil)
                }
            }
        }
        if let plugins = json(dir + "/plugin-auth.json") {
            let src = source(tool, dir + "/plugin-auth.json")
            for name in plugins.keys.sorted() {
                guard let entry = plugins[name] as? [String: Any] else { continue }
                out += magpiePlugin(name.lowercased(), entry, src)
            }
        }
        if let providers = json(dir + "/providers.json")?["providers"] as? [[String: Any]] {
            let src = source(tool, dir + "/providers.json")
            for p in providers {
                let name = ((p["preset"] ?? p["id"]) as? String ?? "").lowercased()
                let endpoint = (p["chat"] ?? p["base"] ?? p["baseURL"] ?? p["url"]) as? String
                out += authEntry(name, ["key": p["key"] as Any], src, owner: nil, baseURL: endpoint)
            }
        }
        return out
    }

    private func magpiePlugin(_ name: String, _ entry: [String: Any], _ src: SubscriptionSource) -> [SubscriptionAccount] {
        let access = (entry["access"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let accountID = entry["accountId"] as? String ?? ""
        let expires = subscriptionDate(entry["expires"])
        switch name {
        case "grok":
            guard let access else { return [] }
            let sub = subscriptionJWTClaims(access)["sub"] as? String
            return [SubscriptionAccount(provider: .grok, label: accountID, source: src,
                                        credential: SubscriptionCredential(kind: .oauth, token: access, expiresAt: expires),
                                        providerAccountID: sub)]
        case "workbuddy", "workbuddy-ai":
            let provider: SubscriptionProvider = name == "workbuddy" ? .workbuddy : .workbuddyAI
            let uid = entry["uid"] as? String
            var extra: [String: String] = [:]
            extra["uid"] = uid
            extra["domain"] = (entry["domain"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            extra["enterprise"] = (entry["enterpriseId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return [SubscriptionAccount(provider: provider, label: accountID, source: src,
                                        credential: access.map { SubscriptionCredential(kind: .oauth, token: $0, expiresAt: expires, extra: extra) },
                                        providerAccountID: uid)]
        case "zcode":
            return zcodeState(entry, label: accountID, src)
        case "opencode-zen-free":
            return [SubscriptionAccount(provider: .zenFree, source: src, credential: nil, discoveryProblem: .freeModel)]
        default:
            return []
        }
    }

    /// ZCode 插件把路由状态以 JSON 存在 refresh 里：{site, device, jwt, key, base}。
    private func zcodeState(_ entry: [String: Any], label: String, _ src: SubscriptionSource) -> [SubscriptionAccount] {
        var state: [String: Any] = [:]
        if let text = entry["refresh"] as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { state = parsed }
        var extra: [String: String] = [:]
        if let jwt = state["jwt"] as? String, !jwt.isEmpty { extra["jwt"] = jwt }
        if let device = state["device"] as? String { extra["device"] = device }
        if let key = (state["key"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            let base = state["base"] as? String ?? ""
            let host = URL(string: base)?.host?.lowercased()
                ?? ((state["site"] as? String) == "bigmodel" ? "open.bigmodel.cn" : "api.z.ai")
            // 只对登记的 Z.ai / BigModel 域名查询 Coding 配额。
            if host == "api.z.ai" || host == "open.bigmodel.cn" {
                extra["key"] = key
                extra["root"] = "https://" + host
            }
        }
        guard !extra.isEmpty, extra["jwt"] != nil || extra["key"] != nil else {
            return [SubscriptionAccount(provider: .zcode, label: label, source: src, credential: nil)]
        }
        let token = extra["key"] ?? extra["jwt"] ?? ""
        let sub = extra["jwt"].flatMap { subscriptionJWTClaims($0)["sub"] as? String }
        return [SubscriptionAccount(provider: .zcode, label: label, source: src,
                                    credential: SubscriptionCredential(kind: .oauth, token: token, extra: extra),
                                    providerAccountID: sub.map { $0 } ?? (label.isEmpty ? nil : label))]
    }

    // ---------------------------------------------------------- 自定义目录 ----

    private func customDirectory(_ dir: String) -> [SubscriptionAccount] {
        let tool = "自定义目录"
        var out: [SubscriptionAccount] = []
        if let d = json(dir + "/auth.json") {
            if let tokens = d["tokens"] as? [String: Any] { out += codexTokens(tokens, source(tool, dir + "/auth.json")) }
            else { out += authEntries(d, source(tool, dir + "/auth.json")) }
        }
        if let oauth = json(dir + "/.credentials.json")?["claudeAiOauth"] as? [String: Any] {
            out += claudeOAuth(oauth, source(tool, dir + "/.credentials.json"))
        }
        if let cred = json(dir + "/credentials/kimi-code.json") {
            out += kimiOAuth(cred, source(tool, dir + "/credentials/kimi-code.json"), host: "api.kimi.com")
        }
        if let creds = json(dir + "/oauth_creds.json") {
            out += geminiOAuth(creds, source(tool, dir + "/oauth_creds.json"), activeEmail: nil)
                .map { var a = $0; a.isActive = false; return a }
        }
        out += envKeys(yamlBlock(dir + "/.credentials.yaml", "refs"), source(tool, dir + "/.credentials.yaml"))
        out += envKeys(envFile(dir + "/.env"), source(tool, dir + "/.env"))
        out += magpie(dir, tool: tool)
        return out
    }

    // ---------------------------------------------------------------- 合并 ----

    static func merge(_ accounts: [SubscriptionAccount]) -> [SubscriptionAccount] {
        var result: [SubscriptionAccount] = []
        for account in accounts {
            guard let index = result.firstIndex(where: { sameAccount($0, account) }) else {
                result.append(account)
                continue
            }
            result[index] = combine(result[index], account)
        }
        // 只有元数据（无凭据、无已知原因）的条目，在该供应商已有可查账号时不再单列。
        result = result.filter { account in
            account.credential != nil || account.discoveryProblem != nil
                || !result.contains { $0.provider == account.provider && $0.credential != nil }
        }
        return result.sorted { SubscriptionCard.ordered(SubscriptionCard(account: $0, snapshot: .init(status: .loading)),
                                                         SubscriptionCard(account: $1, snapshot: .init(status: .loading))) }
    }

    static func sameAccount(_ a: SubscriptionAccount, _ b: SubscriptionAccount) -> Bool {
        guard a.provider == b.provider else { return false }
        if let x = a.providerAccountID, let y = b.providerAccountID { return x == y }
        if let x = a.credential, let y = b.credential { return x.token == y.token }
        // 两条都只有原因、没有凭据（如同一 API Key 只能列出）：按原因合并为一行。
        return a.credential == nil && b.credential == nil && a.discoveryProblem == b.discoveryProblem
            && a.label == b.label
    }

    static func combine(_ a: SubscriptionAccount, _ b: SubscriptionAccount) -> SubscriptionAccount {
        func rank(_ x: SubscriptionAccount) -> (Int, Int, Double) {
            (x.credential == nil ? 0 : 1, x.isActive ? 1 : 0, x.credential?.expiresAt?.timeIntervalSince1970 ?? 0)
        }
        var merged = rank(b) > rank(a) ? b : a
        let other = rank(b) > rank(a) ? a : b
        merged.sources = Array(Set(a.sources + b.sources)).sorted()
        merged.isActive = a.isActive || b.isActive
        if merged.label.isEmpty { merged.label = other.label }
        if merged.planHint.isEmpty { merged.planHint = other.planHint }
        merged.providerAccountID = merged.providerAccountID ?? other.providerAccountID
        if merged.credential != nil { merged.discoveryProblem = nil }
        merged.id = SubscriptionAccount.makeID(provider: merged.provider, accountID: merged.providerAccountID,
                                               credential: merged.credential, source: merged.sources[0])
        return merged
    }
}
