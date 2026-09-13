//
//  OfficialQuotaService.swift
//  TokenTrackerCore
//
//  四家官方配额抓取的入口：缓存合并（OfficialCache）+ 结果转 OfficialResult
//  （QuotaEstimator 的 officialProvider 缝）。对齐 quotas.py compute() 里
//  oauths 的并行抓取与 _cached(name, fn, force, version_fn) 调用方式。
//

import Foundation
import CryptoKit

public final class OfficialQuotaService: @unchecked Sendable {
    public let ctx: BillingContext
    public let cache: OfficialCache

    public init(ctx: BillingContext = BillingContext(), cache: OfficialCache = OfficialCache()) {
        self.ctx = ctx
        self.cache = cache
    }

    /// 原始抓取（无缓存）。name ∈ claude-oauth / kimi / codex / go。
    public func fetch(_ name: String) -> [String: Any] {
        switch name {
        case "claude-oauth": return ClaudeBilling(ctx: ctx).oauthUsage()
        case "kimi": return KimiBilling(ctx: ctx).usage()
        case "codex": return CodexBilling(ctx: ctx).usage()
        case "go": return GoBilling(ctx: ctx).usage()
        default: return ["error": "unknown_provider"]
        }
    }

    /// 带缓存的抓取（对齐 billing._cached；kimi 挂凭据文件版本）。
    public func cached(_ name: String, force: Bool = false) -> [String: Any] {
        let kimi = name == "kimi" ? KimiBilling(ctx: ctx) : nil
        var cacheKey = name
        if name == "codex" {
            let authPath = expandPath(ctx.env["CODEX_HOME"] ?? (ctx.home + "/.codex")) + "/auth.json"
            let object = FileManager.default.contents(atPath:authPath).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
            let account = (object?["tokens"] as? [String:Any])?["account_id"] as? String ?? "signed-out"
            cacheKey += ":" + SHA256.hash(data:Data(account.utf8)).map { String(format:"%02x",$0) }.joined()
        }
        return cache.cached(cacheKey, force: force,
                            versionFn: kimi.map { b in { b.credentialsVersion() } }) {
            self.fetch(name)
        }
    }

    /// QuotaEstimator 缝：官方结果 → OfficialResult。
    public func providerResult(_ name: String, force: Bool = false) -> OfficialResult? {
        let raw = cached(name, force: force)
        return Self.toOfficialResult(raw)
    }

    /// [String: Any]（Python 字典语义）→ OfficialResult。
    public static func toOfficialResult(_ raw: [String: Any]) -> OfficialResult {
        var windows: [String: OfficialWindow]?
        if let rawWindows = raw["windows"] as? [String: Any] {
            var parsed: [String: OfficialWindow] = [:]
            for (key, value) in rawWindows {
                guard let w = value as? [String: Any] else { continue }
                var used: Double?
                if let n = w["used"] as? NSNumber { used = n.doubleValue }
                var limit: Double?
                if let n = w["limit"] as? NSNumber { limit = n.doubleValue }
                var resetsAt: String?
                if let ms = (w["resets_at"] as? NSNumber)?.int64Value, ms > 0 {
                    resetsAt = ISO8601DateFormatter().string(
                        from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
                }
                parsed[key] = OfficialWindow(
                    pct: BillingNet.pct(w["pct"]),
                    used: used, limit: limit,
                    resetsAt: resetsAt,
                    unit: w["unit"] as? String)
            }
            windows = parsed
        }
        return OfficialResult(
            windows: windows,
            sampledAt: (raw["_sampled_at"] as? NSNumber)?.doubleValue,
            staleMin: (raw["_stale_min"] as? NSNumber)?.intValue,
            error: raw["error"] as? String,
            detail: raw["detail"] as? String ?? (raw["_err"] as? String),
            plan: raw["plan"] as? String,
            via: raw["_via"] as? String)
    }
}
