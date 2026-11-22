//
//  AntigravityLocalCredentials.swift
//  TokenTrackerCore
//
//  只读自动发现本机 Antigravity 登录凭据（不修改、不回写、不刷新原工具登录态）：
//  1. macOS 钥匙串（Antigravity 2.0 桌面 App / Antigravity CLI `agy`）：
//     service = "gemini", account = "antigravity"（go-keyring-base64 或 JSON）。
//  2. Antigravity IDE 全局状态库（只读 SQLite）：
//     ~/Library/Application Support/Antigravity*/User/globalStorage/state.vscdb
//     读取 antigravityAuthStatus / antigravityUnifiedStateSync.oauthToken /
//     jetskiStateSync.agentManagerInitState。
//
//  凭据只留在内存，不进入快照、缓存或日志。
//

import Foundation

public struct AntigravityLocalCredentials: Sendable {
    public var home: String
    var keychainRead: @Sendable () -> String?

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.keychainRead = { Self.defaultKeychainRead() }
    }

    init(home: String, keychainRead: @escaping @Sendable () -> String?) {
        self.home = home
        self.keychainRead = keychainRead
    }

    public func discover() -> [SubscriptionAccount] {
        var found: [SubscriptionAccount] = []
        let fallbackEmail = appStorageEmail()

        if let raw = keychainRead(), let account = parseKeychainPayload(raw, fallbackEmail: fallbackEmail) {
            found.append(account)
        }

        let vscdbPaths = [
            home + "/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
            home + "/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb",
        ]
        for path in vscdbPaths {
            if let account = readStateVSCDB(path: path, fallbackEmail: fallbackEmail) {
                if !found.contains(where: { Self.same($0, account) }) {
                    found.append(account)
                }
            }
        }
        return found
    }

    // ------------------------------------------------------------ 钥匙串 ----

    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"

    static func defaultKeychainRead() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// 解析 `go-keyring-base64:<base64>`、纯 JSON 或十六进制编码的 JSON。
    func parseKeychainPayload(_ raw: String, fallbackEmail: String?) -> SubscriptionAccount? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let dict = Self.decodeJSONContainer(trimmed) else { return nil }

        let tokenObj = dict["token"] as? [String: Any] ?? dict
        let access = Self.firstNonEmpty([
            tokenObj["access_token"] as? String,
            tokenObj["accessToken"] as? String,
            tokenObj["access"] as? String,
        ]) ?? ""
        let refresh = Self.firstNonEmpty([
            tokenObj["refresh_token"] as? String,
            tokenObj["refreshToken"] as? String,
            dict["refresh_token"] as? String,
            dict["refreshToken"] as? String,
        ])
        guard !access.isEmpty || refresh != nil else { return nil }

        let expiry = access.isEmpty
            ? Date.distantPast
            : subscriptionDate(tokenObj["expiry"] ?? tokenObj["expiry_date"] ?? tokenObj["expires_at"] ?? tokenObj["expires"])
        let idClaims = subscriptionJWTClaims((tokenObj["id_token"] ?? dict["id_token"]) as? String ?? "")
        let email = Self.firstNonEmpty([
            dict["id_token_email"] as? String,
            dict["email"] as? String,
            idClaims["email"] as? String,
            fallbackEmail,
        ]) ?? ""
        let identity = Self.firstNonEmpty([
            idClaims["sub"] as? String,
            dict["writer_id"] as? String,
            email.isEmpty ? nil : email.lowercased(),
        ])

        let credential = SubscriptionCredential(kind: .oauth, token: access, expiresAt: expiry, refreshToken: refresh)
        var account = SubscriptionAccount(
            provider: .antigravity,
            label: email,
            source: SubscriptionSource(tool: "Antigravity", location: "钥匙串"),
            isActive: true,
            isAutoDiscovered: true,
            credential: credential,
            providerAccountID: identity)
        account.id = Self.localAccountID(identity: identity, token: access.isEmpty ? (refresh ?? "") : access)
        return account
    }

    static func decodeJSONContainer(_ raw: String) -> [String: Any]? {
        if raw.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            return obj
        }
        let b64Text: String
        if raw.hasPrefix("go-keyring-base64:") {
            b64Text = String(raw.dropFirst("go-keyring-base64:".count))
        } else {
            b64Text = raw
        }
        if let decoded = decodeBase64Flexible(b64Text),
           let obj = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] {
            return obj
        }
        if let hexData = decodeHex(raw),
           let obj = try? JSONSerialization.jsonObject(with: hexData) as? [String: Any] {
            return obj
        }
        return nil
    }

    // -------------------------------------------------------- state.vscdb ----

    func readStateVSCDB(path: String, fallbackEmail: String?) -> SubscriptionAccount? {
        guard FileManager.default.fileExists(atPath: path),
              let conn = try? sqliteRO(path) else { return nil }
        let keys = [
            "antigravityUnifiedStateSync.oauthToken",
            "jetskiStateSync.agentManagerInitState",
            "antigravityAuthStatus",
        ]
        var values: [String: String] = [:]
        for key in keys {
            if let row = try? conn.queryOne("SELECT value FROM ItemTable WHERE key = ?", [key]),
               let value = row.stringOrNil("value"), !value.isEmpty {
                values[key] = value
            }
        }
        guard !values.isEmpty else { return nil }

        var email = fallbackEmail ?? ""
        var token: String?
        var refresh: String?
        var expiry: Date?

        if let statusText = values["antigravityAuthStatus"],
           let status = try? JSONSerialization.jsonObject(with: Data(statusText.utf8)) as? [String: Any] {
            if let e = status["email"] as? String, !e.isEmpty { email = e }
            if let apiKey = status["apiKey"] as? String, apiKey.hasPrefix("ya29.") {
                token = apiKey
            }
        }
        for protoKey in ["antigravityUnifiedStateSync.oauthToken", "jetskiStateSync.agentManagerInitState"] {
            guard token == nil || refresh == nil, let raw = values[protoKey] else { continue }
            if let extracted = Self.extractOAuthFromProtoBase64(raw) {
                if token == nil, let at = extracted.accessToken { token = at }
                if refresh == nil, let rt = extracted.refreshToken { refresh = rt }
                if expiry == nil { expiry = extracted.expiry }
                if email.isEmpty, let extractedEmail = extracted.email { email = extractedEmail }
            }
        }

        let access = token ?? ""
        guard !access.isEmpty || refresh != nil else { return nil }
        let identity = email.isEmpty ? nil : email.lowercased()
        let location = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let tool = path.contains("Antigravity IDE") ? "Antigravity IDE" : "Antigravity"
        var account = SubscriptionAccount(
            provider: .antigravity,
            label: email,
            source: SubscriptionSource(tool: tool, location: location),
            isActive: true,
            isAutoDiscovered: true,
            credential: SubscriptionCredential(kind: .oauth, token: access,
                                               expiresAt: access.isEmpty ? .distantPast : expiry,
                                               refreshToken: refresh),
            providerAccountID: identity)
        account.id = Self.localAccountID(identity: identity, token: access.isEmpty ? (refresh ?? "") : access)
        return account
    }

    /// 无 .proto schema 递归解析嵌套 base64/protobuf，提取 OAuth access token（`ya29.`）、refresh token（`1//`）与过期时间。
    static func extractOAuthFromProtoBase64(_ encoded: String) -> (accessToken: String?, refreshToken: String?, expiry: Date?, email: String?)? {
        guard let outer = decodeBase64Flexible(encoded) else { return nil }
        var accessToken: String?
        var refreshToken: String?
        var expiry: Date?
        var email: String?

        func scan(_ bytes: [UInt8], depth: Int) {
            guard depth < 6 else { return }
            var index = 0
            while index < bytes.count {
                guard let tag = readVarint(bytes, &index) else { return }
                let fieldNumber = tag >> 3
                let wireType = tag & 0x07
                guard fieldNumber > 0 else { return }
                switch wireType {
                case 0: // varint
                    guard let value = readVarint(bytes, &index) else { return }
                    // 合理的 Unix 秒或毫秒过期时间戳（2020..2100）
                    if expiry == nil, value >= 1_577_836_800 && value <= 4_102_444_800 {
                        expiry = Date(timeIntervalSince1970: Double(value))
                    } else if expiry == nil, value >= 1_577_836_800_000 && value <= 4_102_444_800_000 {
                        expiry = Date(timeIntervalSince1970: Double(value) / 1000.0)
                    }
                case 1: // 64-bit
                    guard index + 8 <= bytes.count else { return }
                    index += 8
                case 2: // length-delimited
                    guard let len64 = readVarint(bytes, &index), len64 <= UInt64(bytes.count - index) else { return }
                    let length = Int(len64)
                    let slice = Array(bytes[index..<(index + length)])
                    index += length
                    if let text = String(bytes: slice, encoding: .utf8) {
                        if accessToken == nil, text.hasPrefix("ya29."), text.count >= 20,
                           !text.contains(where: \.isWhitespace) {
                            accessToken = text
                            continue
                        }
                        if refreshToken == nil, text.hasPrefix("1//"), text.count >= 20,
                           !text.contains(where: \.isWhitespace) {
                            refreshToken = text
                            continue
                        }
                        if email == nil, text.contains("@"), text.count <= 128,
                           !text.contains(where: \.isWhitespace),
                           text.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil {
                            email = text
                        }
                        if expiry == nil, text.contains("T"), text.count <= 40, let parsed = subscriptionDate(text) {
                            expiry = parsed
                        }
                        // 嵌套 base64（如 oauthTokenInfoSentinelKey 的 value 字段）
                        if text.count >= 24, !text.contains(where: \.isWhitespace),
                           let nested = decodeBase64Flexible(text), nested.count >= 16 {
                            scan(Array(nested), depth: depth + 1)
                        }
                    }
                    if slice.count >= 8 {
                        scan(slice, depth: depth + 1)
                    }
                case 5: // 32-bit
                    guard index + 4 <= bytes.count else { return }
                    index += 4
                default:
                    return
                }
            }
        }

        scan(Array(outer), depth: 0)
        guard accessToken != nil || refreshToken != nil else { return nil }
        return (accessToken, refreshToken, expiry, email)
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count && shift < 64 {
            let b = bytes[index]
            index += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 { return result }
            shift += 7
        }
        return nil
    }

    // ------------------------------------------------------------ 辅助 ----

    private func appStorageEmail() -> String? {
        let path = home + "/Library/Application Support/Antigravity/app_storage.json"
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dict["jetski.onboarding.lastLoginUsername"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func localAccountID(identity: String?, token: String) -> String {
        let basis = identity.map { "local-account:" + $0 } ?? ("local-token:" + token)
        return SubscriptionProvider.antigravity.rawValue + ":local-" + String(subscriptionHash(basis).prefix(16))
    }

    private static func same(_ a: SubscriptionAccount, _ b: SubscriptionAccount) -> Bool {
        if let x = a.providerAccountID, let y = b.providerAccountID { return x == y }
        if let x = a.credential?.token, let y = b.credential?.token { return x == y }
        return false
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let s = value?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    static func decodeBase64Flexible(_ raw: String) -> Data? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem == 1 { return nil }
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s)
    }

    private static func decodeHex(_ raw: String) -> Data? {
        let chars = Array(raw)
        guard chars.count >= 4, chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String([chars[i], chars[i + 1]]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }
}
