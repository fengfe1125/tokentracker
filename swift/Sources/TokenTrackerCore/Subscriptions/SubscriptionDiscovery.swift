import Foundation

/// Bounded, read-only discovery. Config content is data, never executed.
public struct SubscriptionDiscovery {
    public let home: String
    public let env: [String: String]
    public var keychainRead: () -> [String: Any]?
    public init(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment,
                keychainRead: (() -> [String: Any]?)? = nil) {
        self.home = home; self.env = env
        self.keychainRead = keychainRead ?? { BillingContext.defaultKeychainRead() }
    }

    public func discover(extraDirectories: [String] = []) -> [SubscriptionAccount] {
        var found: [SubscriptionAccount] = []
        let magpie = root("MAGPIE_HOME", ".config/magpie")
        func add(_ provider: String, _ auth: [String: Any], source: String,
                 label: String = "", identity: String? = nil, active: Bool = false, plan: String = "") {
            let provider = Self.canonical(provider)
            guard provider != "", !provider.contains("|") else { return }
            var c: [String: String] = [:]
            for (key, names) in ["access": ["access", "access_token", "accessToken", "oauth_token"],
                                  "key": ["key", "api_key", "apiKey"], "account": ["account_id", "accountId"],
                                  "expires": ["expires", "expires_at", "expiresAt"], "uid": ["uid"], "domain": ["domain"]] {
                for name in names {
                    if let s = auth[name] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        c[key] = s; break
                    }
                    if let n = auth[name] as? NSNumber { c[key] = n.stringValue; break }
                }
            }
            // ZCode stores routing state as JSON; retain only fields used by the read-only adapter.
            if provider == "zcode", let text = auth["refresh"] as? String,
               let bytes = text.data(using: .utf8), let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                for name in ["base", "site", "device", "jwt", "key"] {
                    if let value = state[name] as? String { c[name] = value }
                }
            }
            let token = c["access"] ?? c["key"] ?? ""
            let claims = Self.claims(token)
            let openAI = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            let account = c["account"] ?? (provider == "codex" ? openAI["chatgpt_account_id"] as? String : nil)
            if let account { c["account"] = account }
            let stable = identity.flatMap { $0.isEmpty ? nil : $0 } ?? account
            let id = stable.map { "account-" + subscriptionHash($0) }
                ?? "credential-" + subscriptionHash(token.isEmpty ? source + ":" + provider + ":" + label : token)
            let email = claims["email"] as? String ?? ""
            found.append(SubscriptionAccount(provider: provider, identity: id,
                label: label.isEmpty ? email : label, plan: plan, sources: [source], active: active, credential: c))
        }
        func bundles(_ d: [String: Any], source: String, active: Bool) {
            if let tokens = d["tokens"] as? [String: Any] { add("codex", tokens, source: source, active: active) }
            if let oauth = d["claudeAiOauth"] as? [String: Any] {
                add("claude", oauth, source: source, active: active, plan: oauth["subscriptionType"] as? String ?? "")
            }
        }
        let codex = root("CODEX_HOME", ".codex")
        if let d = json(codex + "/auth.json") { bundles(d, source: codex + "/auth.json", active: true) }
        let claude = root("CLAUDE_CONFIG_DIR", ".claude")
        if let d = json(claude + "/.credentials.json") { bundles(d, source: claude + "/.credentials.json", active: true) }
        if let d = keychainRead() { bundles(d, source: "Keychain:Claude Code-credentials", active: true) }
        let kimi = root("KIMI_CODE_HOME", ".kimi-code")
        if let d = json(kimi + "/credentials/kimi-code.json") {
            var auth = d
            let region = (try? String(contentsOfFile: kimi + "/region", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            auth["domain"] = region == nil || region == "mainland-cn" ? "api.kimi.com" : "api.kimi.ai"
            add("kimi", auth, source: kimi, active: true)
        }
        let xdgConfig = env["XDG_CONFIG_HOME"].map(expandPath) ?? home + "/.config"
        let xdgData = env["XDG_DATA_HOME"].map(expandPath) ?? home + "/.local/share"
        for path in [xdgData + "/opencode/auth.json", xdgConfig + "/opencode/auth.json", home + "/.pi/agent/auth.json"] {
            if let d = json(path) {
                for name in d.keys.sorted() {
                    if let auth = d[name] as? [String: Any] { add(name, auth, source: path, active: true) }
                }
            }
        }
        // Previously saved TokenTracker accounts are read, never switched or refreshed.
        for account in CodexAccountStore(home: home).load() {
            if let tokens = account.bundle["tokens"] as? [String: Any] {
                add("codex", tokens, source: "TokenTracker saved account", label: account.email ?? account.name, identity: account.id)
            }
        }
        if let data = array(magpie + "/logins.json") {
            for item in data {
                guard let agent = item["agent"] as? String else { continue }
                let provider = Self.canonical(agent)
                let profile = item["profile"] as? [String: Any] ?? [:]
                let auth = item["auth"] as? [String: Any] ?? [:]
                let label = item["user"] as? String ?? ""
                if let tokens = auth["tokens"] as? [String: Any] {
                    add(provider, tokens, source: magpie + "/logins.json", label: label, plan: item["plan"] as? String ?? "")
                } else if let oauth = auth["claudeAiOauth"] as? [String: Any] {
                    // A Claude organization is the quota identity (different seats can share it).
                    add(provider, oauth, source: magpie + "/logins.json", label: label,
                        identity: profile["organizationUuid"] as? String, plan: item["plan"] as? String ?? "")
                } else {
                    add(provider, auth, source: magpie + "/logins.json", label: label, plan: item["plan"] as? String ?? "")
                }
            }
        }
        if let d = json(magpie + "/plugin-auth.json") {
            for name in d.keys.sorted() {
                guard let auth = d[name] as? [String: Any] else { continue }
                add(name, auth, source: magpie + "/plugin-auth.json", identity: auth["accountId"] as? String)
            }
        }
        if let d = json(magpie + "/providers.json"), let providers = d["providers"] as? [[String: Any]] {
            for p in providers {
                guard let name = p["preset"] as? String ?? p["name"] as? String, !name.isEmpty else { continue }
                // Do not send a key configured for a relay to a different origin.
                var auth = p
                if let endpoint = p["chat"] as? String { auth["configuredEndpoint"] = endpoint }
                let canonical = Self.canonical(name)
                if canonical == "deepseek", let endpoint = p["chat"] as? String,
                   !endpoint.isEmpty, URL(string: endpoint)?.host != "api.deepseek.com" {
                    auth.removeValue(forKey: "key")
                }
                add(canonical, auth, source: magpie + "/providers.json", label: p["name"] as? String ?? "")
            }
        }
        let variables = ["DEEPSEEK_API_KEY":"deepseek", "OPENCODE_GO_API_KEY":"go", "OPENCODE_API_KEY":"go",
                         "KIMI_API_KEY":"kimi", "MOONSHOT_API_KEY":"kimi", "GEMINI_API_KEY":"gemini",
                         "MINIMAX_API_KEY":"minimax", "ANTHROPIC_API_KEY":"anthropic-api", "OPENAI_API_KEY":"openai-api"]
        for name in variables.keys.sorted() {
            if let key = env[name], !key.isEmpty { add(variables[name]!, ["key":key], source: "Environment:" + name, active: true) }
        }
        // Bounded known JSON/TOML/YAML configs; no process or shell profile execution.
        let configs = [claude + "/settings.json", codex + "/config.toml", xdgConfig + "/opencode/opencode.json",
            xdgConfig + "/opencode/opencode.jsonc", home + "/.pi/agent/models.json", home + "/.hermes/config.yaml",
            home + "/.hermes/.env", home + "/.gemini/settings.json", home + "/.gemini/oauth_creds.json",
            home + "/.dsh/.credentials.yaml", home + "/.dsh/settings.yaml", home + "/.dsh/settings.yaml.imported",
            home + "/.dsh/profiles/desktop/settings.yaml", home + "/.dsh/profiles/desktop/.credentials.yaml"]
        for path in configs { readConfig(path, add: add) }
        for directory in extraDirectories {
            let dir = expandPath(directory)
            for name in ["auth.json", ".credentials.json", "credentials/kimi-code.json", "settings.json", "config.toml", "config.yaml", ".env", "providers.json", "models.json"] {
                let path = dir + "/" + name
                if let d = json(path) {
                    bundles(d, source: path, active: false)
                    if let token = d["access_token"] as? String { add("kimi", ["access":token], source: path) }
                    for (name, value) in d where value is [String: Any] {
                        if let a = value as? [String: Any], a["type"] != nil { add(name, a, source:path) }
                    }
                }
                readConfig(path, add: add)
            }
        }
        return Self.merge(found)
    }

    private func root(_ variable: String, _ fallback: String) -> String {
        env[variable].map(expandPath) ?? home + "/" + fallback
    }
    private func object(_ path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 4_194_304 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
    private func json(_ path: String) -> [String:Any]? { object(path) as? [String:Any] }
    private func array(_ path: String) -> [[String:Any]]? { object(path) as? [[String:Any]] }
    private func readConfig(_ path: String, add: (String,[String:Any],String,String,String?,Bool,String) -> Void) {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 4_194_304,
              let text = String(data: data, encoding: .utf8) else { return }
        let providers = ["deepseek", "gemini", "minimax", "kimi", "opencode-go", "anthropic", "openai"]
        if let d = try? JSONSerialization.jsonObject(with: data) as? [String:Any] {
            func walk(_ node: [String:Any], _ context: String, _ depth: Int) {
                guard depth < 6 else { return }
                for (key,value) in node {
                    if let child = value as? [String:Any] {
                        let matched = providers.first { key.lowercased().contains($0) }
                        let next = matched ?? context
                        if let p = matched { add(p, child, path, "", nil, false, "") }
                        walk(child, next, depth+1)
                    } else if let keyValue = value as? String {
                        let upper = key.uppercased()
                        if upper.contains("API_KEY"), let p = providers.first(where: { upper.lowercased().contains($0) }) {
                            add(p, ["key":keyValue], path, "", nil, false, "")
                        } else if ["apikey", "api_key"].contains(key.lowercased()), !context.isEmpty {
                            add(context, ["key":keyValue], path, "", nil, false, "")
                        }
                    }
                }
            }
            walk(d, "", 0)
        } else {
            // Only literal key assignments in known files. Interpolations are unresolved, not executed.
            var context = ""
            for line in text.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard !s.hasPrefix("#"), !s.hasPrefix("//") else { continue }
                if let p = providers.first(where: { s.lowercased().contains($0) }) { context = p }
                guard let split = s.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
                let field = String(s[..<split]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "").lowercased()
                guard field.contains("api_key") || field == "apikey" || field == "key" else { continue }
                let value = String(s[s.index(after: split)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"',"))
                guard !context.isEmpty, !value.isEmpty, !value.contains("${"), !value.contains("$("), !value.hasPrefix("{") else { continue }
                add(context, ["key":value], path, "", nil, false, "")
            }
        }
    }
    public static func canonical(_ name: String) -> String {
        let n = name.lowercased().replacingOccurrences(of: "plugin:", with: "")
        return ["anthropic":"claude", "openai-codex":"codex", "kimi-coding":"kimi", "kimi-for-coding":"kimi",
                "opencode-go":"go", "github-copilot":"copilot", "xai":"grok", "minimax-cn":"minimax",
                "google-gemini-cli":"gemini" ][n] ?? n
    }
    static func claims(_ token: String) -> [String:Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var s = String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded:s) else { return [:] }
        return (try? JSONSerialization.jsonObject(with:d)) as? [String:Any] ?? [:]
    }
    static func merge(_ accounts: [SubscriptionAccount]) -> [SubscriptionAccount] {
        var result: [SubscriptionAccount] = []
        for account in accounts {
            if let i = result.firstIndex(where: { $0.provider == account.provider && ($0.identity == account.identity || (!$0.credential.isEmpty && $0.fingerprint == account.fingerprint) ||
                (!($0.credential["access"] ?? $0.credential["key"] ?? "").isEmpty && ($0.credential["access"] ?? $0.credential["key"]) == (account.credential["access"] ?? account.credential["key"]))) }) {
                let old = result[i]
                // Prefer the active source; otherwise the newest expiration. Never merge by email.
                let replace = (!old.active && account.active) || (old.active == account.active && (Double(account.credential["expires"] ?? "0") ?? 0) > (Double(old.credential["expires"] ?? "0") ?? 0))
                if replace { result[i] = account }
                result[i].active = old.active || account.active
                result[i].sources = Array(Set(old.sources + account.sources)).sorted()
                if result[i].label.isEmpty { result[i].label = account.label.isEmpty ? old.label : account.label }
            } else { result.append(account) }
        }
        // Metadata-only Magpie login rows describe the same plugin source; they are not extra accounts.
        result = result.filter { a in !a.credential.isEmpty || !result.contains { $0.provider == a.provider && !$0.credential.isEmpty } }
        return result.sorted { ($0.provider, $0.identity) < ($1.provider, $1.identity) }
    }
}
