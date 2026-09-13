//
//  OfficialCache.swift
//  TokenTrackerCore
//
//  移植 billing.py 的缓存/退避层：_cached / _cached_result / 磁盘兜底。
//  - 成功 120s、失败 120s 退避；429 遵守 Retry-After（force 手动刷新也不绕过）
//  - 成功与失败尝试分开保留；成功的兜底结果最长 24h，并标记过期（_stale_min）
//  - 磁盘缓存跨进程共享（flock + 唯一临时文件 + 原子替换），只存配额数字
//

import Foundation

/// 一次 provider 抓取的可变缓存状态（进程内）。
final class ProviderCacheState: @unchecked Sendable {
    let lock = NSLock()   // 对齐 Python `with state.lock`（请求合并依赖它）
    var generation = 0
    var attempt: (Double, [String: Any])?      // (ts, data) 最近尝试（含失败）
    var success: (Double, [String: Any])?      // (ts, data) 最近成功
    var retryUntil: Double = 0
    var rateLimitUntil: Double = 0
    var sourceVersion: [AnyHashable?]?         // kimi 凭据文件版本（见 versionFn）
}

public final class OfficialCache {
    public static let ttlOK = 120.0
    public static let ttlErr = 120.0
    public static let staleMax: Double = 24 * 3600

    private var states: [String: ProviderCacheState] = [:]
    private let statesLock = NSLock()

    public let diskPath: String
    public var clock: () -> Double

    public init(diskPath: String? = nil, clock: (() -> Double)? = nil) {
        self.diskPath = diskPath ?? NSHomeDirectory() + "/.tokentracker/official_cache.json"
        self.clock = clock ?? { Date().timeIntervalSince1970 }
    }

    // ------------------------------------------------------------ 磁盘 ----

    /// 读磁盘缓存的成功结果 → (ts, data)？仅接受 24h 内的无错误成功结果。
    public func diskLoad(_ key: String) -> (Double, [String: Any])? {
        guard let data = FileManager.default.contents(atPath: diskPath),
              let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = store[key] as? [Any], record.count == 2,
              let ts = (record[0] as? NSNumber)?.doubleValue,
              let payload = record[1] as? [String: Any], payload["error"] == nil
        else { return nil }
        let age = clock() - ts
        guard 0 <= age, age <= OfficialCache.staleMax else { return nil }
        return (ts, payload)
    }

    /// 成功结果落盘（跨进程共享，限流时互为兜底）；flock 串行化 + 原子替换。
    public func diskStore(_ key: String, ts: Double, data: [String: Any]) {
        let path = diskPath
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let lockPath = path + ".lock"
        guard let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644) as Int32? else { return }
        guard flock(lockFD, LOCK_EX) == 0 else { close(lockFD); return }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }

        var store: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            store = loaded
        }
        store[key] = [ts, data]
        guard let encoded = try? JSONSerialization.data(withJSONObject: store) else { return }
        let tmp = (directory as NSString)
            .appendingPathComponent(".official_cache.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp, contents: encoded) else { return }
        // fsync 后原子替换
        if let fd = try? FileHandle(forWritingTo: URL(fileURLWithPath: tmp)) {
            try? fd.synchronize()
            try? fd.close()
        }
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                   withItemAt: URL(fileURLWithPath: tmp))
        try? FileManager.default.removeItem(atPath: tmp)   // replaceItemAt 已消费/不存在时无害
    }

    // ------------------------------------------------------------ 语义 ----

    private func cachedResult(_ key: String, state: ProviderCacheState,
                              now: Double) -> [String: Any] {
        guard let attempt = state.attempt else { return ["error": "unknown"] }
        var data = attempt.1
        if data["_ok"] as? Bool == true {
            if now - attempt.0 < OfficialCache.ttlOK {
                return data
            }
            // 成功兜底也可能带上游限流：普通 TTL 结束后它是旧的，不是整个退避期都新鲜
            data = ["error": "http_429", "detail": "官方接口限流，等待 Retry-After", "_ok": false]
        }
        var stale = state.success
        if let existing = stale, !(0...OfficialCache.staleMax).contains(now - existing.0) {
            state.success = nil
            stale = nil
        }
        if stale == nil, let disk = diskLoad(key) {
            state.success = disk
            stale = disk
        }
        if let stale {
            var result = stale.1
            result["_stale_min"] = max(1, Int((now - stale.0) / 60))
            result["_err"] = (data["detail"] as? String) ?? (data["error"] as? String) ?? ""
            return result
        }
        return data
    }

    /// 合并同 provider 请求；成功与失败尝试分开保留。
    /// force 跳过普通 TTL，绝不跳过服务端限流。versionFn：来源文件版本（如 Kimi
    /// 凭据更新后下轮轮询重读，不必等失败退避；仍不绕过 429）。
    public func cached(_ key: String, force: Bool = false,
                       versionFn: (() -> [AnyHashable?])? = nil,
                       fn: () throws -> [String: Any]) -> [String: Any] {
        statesLock.lock()
        let state = states[key] ?? ProviderCacheState()
        states[key] = state
        // generation 必须在进入 state.lock 之前读取（对齐 Python：cache_lock →
        // state.lock 两层），否则同时 force 的调用方会逐个重复发请求
        let generation = state.generation
        statesLock.unlock()

        // 对齐 Python `with state.lock`：同一 provider 的并发调用方共享同一次请求
        state.lock.lock()
        defer { state.lock.unlock() }

        let now = clock()
        let effectiveForce = force && generation == state.generation
        let version = versionFn?()
        let sourceChanged = version != nil && state.sourceVersion != nil && version != state.sourceVersion
            || (version == nil) != (state.sourceVersion == nil)
        if state.attempt != nil,
           now < state.rateLimitUntil
            || (!effectiveForce && !sourceChanged && now < state.retryUntil) {
            return cachedResult(key, state: state, now: now)
        }
        // 先记版本再读凭据：并发 CLI 写入会在下轮轮询被注意到
        state.sourceVersion = version

        var data: [String: Any]
        do {
            data = try fn()
            data["_ok"] = data["error"] == nil
        } catch {
            data = ["error": "network", "detail": String(describing: error), "_ok": false]
        }
        let finishedAt = clock()
        if data["_ok"] as? Bool == true { data["_sampled_at"] = finishedAt }
        state.attempt = (finishedAt, data)
        var retryAfter = 0.0
        if let ra = data["_retry_after"] {
            if let n = ra as? NSNumber { retryAfter = max(0, n.doubleValue) }
            else if let s = ra as? String { retryAfter = max(0, Double(s) ?? 0) }
        }
        if !retryAfter.isFinite { retryAfter = 0 }
        if data["_ok"] as? Bool == true {
            state.success = (finishedAt, data)
            state.retryUntil = finishedAt + max(OfficialCache.ttlOK, retryAfter)
            diskStore(key, ts: finishedAt, data: data)
        } else {
            state.retryUntil = finishedAt + max(OfficialCache.ttlErr, retryAfter)
        }
        state.rateLimitUntil = (retryAfter > 0 || (data["error"] as? String) == "http_429")
            ? state.retryUntil : 0
        let result = cachedResult(key, state: state, now: finishedAt)
        state.generation += 1
        return result
    }
}
