//
//  PublicStatsPublisher.swift
//  TokenTrackerCore
//
//  把公开载荷 PUT 到统计服务。三道闸决定「这次到底发不发」：
//  内容去重 → 最小间隔 → 失败退避。缺一不可 ——
//  ScanScheduler 默认 60 秒触发一次 onFinish，一天 1440 次，
//  而 Cloudflare 免费档 KV 每天只有 1000 次写、D1 每天 10 万行。
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

// ------------------------------------------------------------ 决策 ----

public enum PublishDecision: Equatable, Sendable {
    case publish
    case skipDisabled
    case skipUnconfigured
    case skipUnchanged
    case skipThrottled
    case skipBackoff
}

public enum PublishThrottle {
    /// 客户端最小间隔。常量而非设置项 —— 不给用户一个能把额度打爆的旋钮。
    /// 服务端另有 10 分钟的 CAS 下限兜底。
    public static let minInterval: Double = 900
    public static let maxBackoff: Double = 21600

    public static func backoff(failures: Int) -> Double {
        guard failures > 0 else { return 0 }
        return min(60 * pow(2, Double(failures - 1)), maxBackoff)
    }
}

/// 纯函数：无时钟、无网络、无 IO，全部分支可单测。
public func publishDecision(enabled: Bool, configured: Bool,
                            lastHash: String, newHash: String,
                            lastOkAt: Double, failures: Int, now: Double) -> PublishDecision {
    if !enabled { return .skipDisabled }
    if !configured { return .skipUnconfigured }
    if failures > 0 {
        // 退避从「上次尝试」起算；lastOkAt 在失败时也会被推进
        if now - lastOkAt < PublishThrottle.backoff(failures: failures) { return .skipBackoff }
    }
    // 内容一致就不发。空闲机器上这一条就把写入压到接近 0。
    if !lastHash.isEmpty && lastHash == newHash { return .skipUnchanged }
    if now - lastOkAt < PublishThrottle.minInterval { return .skipThrottled }
    return .publish
}

// ------------------------------------------------------------ 状态 ----

/// 轮转状态单独存文件，不进 settings.json：
/// AppState 每 5 秒轮询设置文件并 diff 指纹，每次发布都变的哈希会让 UI 空转。
public struct PublishState: Equatable, Sendable {
    public var lastHash = ""
    public var lastOkAt: Double = 0
    public var lastError = ""
    public var consecutiveFailures = 0
    public var tzFirstSeen = ""

    public static func load(path: String) -> PublishState {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return PublishState() }
        var state = PublishState()
        state.lastHash = obj["last_hash"] as? String ?? ""
        state.lastOkAt = (obj["last_ok_at"] as? NSNumber)?.doubleValue ?? 0
        state.lastError = obj["last_error"] as? String ?? ""
        state.consecutiveFailures = (obj["consecutive_failures"] as? NSNumber)?.intValue ?? 0
        state.tzFirstSeen = obj["tz_first_seen"] as? String ?? ""
        return state
    }

    public func save(path: String) {
        atomicWriteJSON(path, [
            "version": 1,
            "last_hash": lastHash,
            "last_ok_at": lastOkAt,
            "last_error": lastError,
            "consecutive_failures": consecutiveFailures,
            "tz_first_seen": tzFirstSeen,
        ], permissions: 0o600)
    }
}

// -------------------------------------------------------- token 存储 ----

public protocol PublishTokenStore: Sendable {
    func read(handle: String) -> String?
    @discardableResult func write(handle: String, token: String) -> Bool
}

/// 钥匙串优先。解析顺序：环境变量 → 钥匙串 → ~/.tokentracker/publish_token(0600)。
/// 环境变量是无头自部署与 CI 的出路；文件是钥匙串不可用时的兜底。
///
/// 走 Security 框架而不是 /usr/bin/security：后者的 `-w` 带值会把密钥暴露在 argv 里
/// （ps 可见），不带值又是从 TTY 交互读并要求重输一次，管道喂不进去。
/// 框架 API 两个毛病都没有。
public struct KeychainPublishTokenStore: PublishTokenStore {
    public static let service = "com.tokentracker.publish"
    public let fallbackPath: String

    public init(fallbackPath: String = NSHomeDirectory() + "/.tokentracker/publish_token") {
        self.fallbackPath = fallbackPath
    }

    public func read(handle: String) -> String? {
        if let env = ProcessInfo.processInfo.environment["TOKENTRACKER_PUBLISH_TOKEN"],
           !env.isEmpty { return env }
        #if canImport(Security)
        if !handle.isEmpty {
            var item: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: handle,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        #endif
        if let text = try? String(contentsOfFile: fallbackPath, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// 写入钥匙串；不可用时退回 0600 文件，并如实返回写到了哪里。
    @discardableResult
    public func write(handle: String, token: String) -> Bool {
        writeReportingLocation(handle: handle, token: token) != nil
    }

    public enum Location: String, Sendable { case keychain, file }

    public func writeReportingLocation(handle: String, token: String) -> Location? {
        #if canImport(Security)
        if !handle.isEmpty {
            let query = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: handle,
            ] as [String: Any]
            let data = Data(token.utf8)
            var status = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                status = SecItemAdd(add as CFDictionary, nil)
            }
            if status == errSecSuccess { return .keychain }
        }
        #endif
        let dir = (fallbackPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: fallbackPath, contents: Data(token.utf8))
        else { return nil }
        chmod(fallbackPath, 0o600)
        return .file
    }
}

// ------------------------------------------------------------ 发布 ----

public struct PublishOutcome: Equatable, Sendable {
    public var decision: PublishDecision
    public var status: Int = 0
    public var error: String = ""
    public var bytes: Int = 0
}

public final class PublicStatsPublisher: @unchecked Sendable {
    let statePath: String
    let settings: SettingsStore
    let tokens: PublishTokenStore
    let http: BillingHTTP
    let now: () -> Double

    public init(settings: SettingsStore = SettingsStore(),
                statePath: String = NSHomeDirectory() + "/.tokentracker/publish_state.json",
                tokens: PublishTokenStore = KeychainPublishTokenStore(),
                http: @escaping BillingHTTP = BillingNet.httpJSON,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.settings = settings
        self.statePath = statePath
        self.tokens = tokens
        self.http = http
        self.now = now
    }

    /// 内容哈希：剔除 generated_at 后再算，否则每次载荷都不同，去重形同虚设。
    public static func contentHash(_ payload: PublicStatsPayload) -> String {
        var copy = payload
        copy.generatedAt = ""
        guard let data = try? copy.encoded() else { return "" }
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return String(data.count)
        #endif
    }

    /// 绝不抛错、绝不阻塞扫描：所有失败归到 publish_state.json.last_error。
    @discardableResult
    public func publishIfNeeded(store: UsageStore, force: Bool = false) -> PublishOutcome {
        let config = settings.effective()
        let enabled = (config["publish_enabled"] as? NSNumber)?.boolValue ?? false
        let endpoint = (config["publish_endpoint"] as? String ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let handle = config["publish_handle"] as? String ?? ""
        let days = (config["publish_days"] as? NSNumber)?.intValue ?? 365
        var state = PublishState.load(path: statePath)

        guard let payload = try? PublicStatsBuilder.build(store: store, days: days) else {
            state.lastError = "载荷生成失败"
            state.save(path: statePath)
            return PublishOutcome(decision: .skipDisabled, error: state.lastError)
        }
        let hash = Self.contentHash(payload)
        let decision = force ? .publish : publishDecision(
            enabled: enabled, configured: !endpoint.isEmpty && !handle.isEmpty,
            lastHash: state.lastHash, newHash: hash,
            lastOkAt: state.lastOkAt, failures: state.consecutiveFailures, now: now())
        guard decision == .publish else { return PublishOutcome(decision: decision) }

        guard let token = tokens.read(handle: handle), !token.isEmpty else {
            state.lastError = "找不到发布 token（钥匙串 / TOKENTRACKER_PUBLISH_TOKEN / publish_token 文件）"
            state.consecutiveFailures += 1
            state.lastOkAt = now()
            state.save(path: statePath)
            return PublishOutcome(decision: .publish, error: state.lastError)
        }
        guard let body = try? payload.encoded() else {
            return PublishOutcome(decision: .publish, error: "载荷序列化失败")
        }

        let url = endpoint + "/v1/stats/" + handle
        let (status, response) = http(url, [
            "authorization": "Bearer " + token,
            "content-type": "application/json",
        ], body, "PUT")

        if status == 200 {
            state.lastHash = hash
            state.lastOkAt = now()
            state.lastError = ""
            state.consecutiveFailures = 0
            if state.tzFirstSeen.isEmpty { state.tzFirstSeen = payload.tz }
            state.save(path: statePath)
            return PublishOutcome(decision: .publish, status: status, bytes: body.count)
        }

        let detail = (response["detail"] as? String) ?? (response["error"] as? String)
            ?? (response["_body"] as? String) ?? "HTTP \(status)"
        state.lastError = "HTTP \(status): \(detail)"
        state.consecutiveFailures += 1
        state.lastOkAt = now()
        state.save(path: statePath)
        return PublishOutcome(decision: .publish, status: status, error: state.lastError,
                              bytes: body.count)
    }
}
