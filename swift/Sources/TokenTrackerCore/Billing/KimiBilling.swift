//
//  KimiBilling.swift
//  TokenTrackerCore
//
//  移植 billing.py 的 Kimi 部分：只读现有凭据；access_token 过期时自刷新
//  （refresh_token 授权）并原子写回——refresh_token 每次刷新轮换，
//  kimi-code 刷新时从磁盘重读，写回才不会把它登出。flock 串行化多进程
//  刷新；遇并发轮换（旧 refresh_token 一用即废）重读磁盘兜底。
//  登录流程绝不触碰：无 refresh_token 时报错并提示 kimi login。
//

import Foundation

public struct KimiBilling {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"   // kimi-code 内置 public client
    static let planNames = ["LEVEL_BASIC": "基础版", "LEVEL_INTERMEDIATE": "中级版",
                            "LEVEL_PREMIUM": "高级版", "LEVEL_UNLIMITED": "无限版",
                            "LEVEL_PRO": "专业版"]

    public let ctx: BillingContext

    public init(ctx: BillingContext) {
        self.ctx = ctx
    }

    // ------------------------------------------------------------ 路径 ----

    public var credentialsPath: String {
        let root = ctx.env["KIMI_CODE_HOME"] ?? ctx.home + "/.kimi-code"
        return expandPath(root) + "/credentials/kimi-code.json"
    }

    /// 凭据文件版本（仅元数据，不含 token 值）：Kimi 凭据更新后下轮轮询重读。
    public func credentialsVersion() -> [AnyHashable?] {
        let path = credentialsPath
        var st = stat()
        guard stat(path, &st) == 0 else { return [path, nil] }
        return [path, Int64(st.st_ino), Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(st.st_mtimespec.tv_nsec),
                Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec),
                Int64(st.st_size)]
    }

    /// OAuth host：环境变量覆盖（与 kimi-code 同名）→ region 文件 → CN 默认。
    func oauthHost() -> String {
        if let env = ctx.env["KIMI_CODE_OAUTH_HOST"] ?? ctx.env["KIMI_OAUTH_HOST"],
           !env.isEmpty {
            return env.hasSuffix("/") ? String(env.dropLast()) : env
        }
        let root = ctx.env["KIMI_CODE_HOME"] ?? ctx.home + "/.kimi-code"
        let regionPath = expandPath(root) + "/region"
        if let text = try? String(contentsOfFile: regionPath, encoding: .utf8) {
            let region = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !region.isEmpty && region != "mainland-cn" {
                return "https://auth.kimi.ai"
            }
        }
        return "https://auth.kimi.com"
    }

    /// usages 等业务 API 前缀：与 OAuth host 同域族（auth.kimi.com ↔ api.kimi.com）。
    func apiBase() -> String {
        let host = oauthHost()
        if let match = try? NSRegularExpression(pattern: #"^(https://)auth\.(.+)$"#)
            .firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
           let r1 = Range(match.range(at: 1), in: host),
           let r2 = Range(match.range(at: 2), in: host) {
            return "\(host[r1])api.\(host[r2])/coding/v1"
        }
        return "https://api.kimi.com/coding/v1"
    }

    // ---------------------------------------------------------- 刷新锁 ----

    /// 刷新凭据的跨进程互斥。锁文件常驻不删，仅作 flock 载体。
    private func withRefreshLock<T>(timeout: Double, _ body: () throws -> T) throws -> T {
        let path = (credentialsPath as NSString).deletingLastPathComponent
            + "/.tokentracker-refresh.lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw SQLiteError(message: "无法打开 Kimi 刷新锁") }
        defer { flock(fd, LOCK_UN); close(fd) }
        let deadline = Date().timeIntervalSince1970 + timeout
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
            if Date().timeIntervalSince1970 >= deadline {
                throw SQLiteError(message: "等待 Kimi 刷新锁超时")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try body()
    }

    // ------------------------------------------------------------ 读写 ----

    /// 三态读取：文件缺失 / 解析失败或非对象 / 成功（对齐 Python 的 OSError vs
    /// ValueError vs 非 dict 分支）。
    private enum CredRead {
        case missing, invalid, ok([String: Any])
    }

    private func readCredentials() -> CredRead {
        guard let data = FileManager.default.contents(atPath: credentialsPath) else {
            return .missing
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return .invalid }
        guard let dict = obj as? [String: Any] else { return .invalid }
        return .ok(dict)
    }

    /// Python cred.get("access_token") 真值判定（空串视为缺失）。
    private static func nonEmptyToken(_ cred: [String: Any]) -> String? {
        guard let tok = cred["access_token"] as? String,
              !tok.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return tok
    }

    private func writeCredentials(_ cred: [String: Any]) {
        atomicWriteJSON(credentialsPath, cred)
    }

    /// refresh_token 换新凭据；失败返回 nil（并发刷新只有一个赢家）。
    private func refreshCredentials(_ cred: [String: Any]) -> [String: Any]? {
        guard let rt = cred["refresh_token"] as? String,
              !rt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: rt),
        ]
        // form 编码（queryItems 会自动 + → %20 等；refresh_token 为 URL 安全字符）
        let body = components.percentEncodedQuery?.data(using: .utf8)
        let (status, data) = ctx.http("\(oauthHost())/api/oauth/token",
                                      ["Content-Type": "application/x-www-form-urlencoded",
                                       "Accept": "application/json"], body, "POST")
        guard status == 200, let accessToken = data["access_token"] as? String else {
            return nil
        }
        var expiresIn = (data["expires_in"] as? NSNumber)?.doubleValue ?? 0
        if !expiresIn.isFinite || expiresIn <= 0 {
            expiresIn = 900   // 实测 TTL ~15min，响应缺省时按同寿命保守处理
        }
        var new = cred
        new["access_token"] = accessToken
        new["expires_at"] = ctx.clock() + expiresIn
        if let rt = data["refresh_token"] as? String {
            new["refresh_token"] = rt
        }
        if data["expires_in"] != nil {
            new["expires_in"] = data["expires_in"]
        }
        return new
    }

    /// 过期凭据自愈：加锁 → 锁内重读（可能刚被刷新）→ 自刷新 → 原子写回。
    /// 返回可用凭据；不可恢复返回 nil。
    func freshCredentials(timeout: Double = 5.0) -> [String: Any]? {
        do {
            return try withRefreshLock(timeout: timeout) {
                guard case .ok(let cred) = readCredentials() else { return nil }
                let exp = (cred["expires_at"] as? NSNumber)?.doubleValue ?? 0
                if exp > ctx.clock(), Self.nonEmptyToken(cred) != nil {
                    return cred   // 锁内重读已新鲜：别人刷好了，直接用
                }
                guard let new = refreshCredentials(cred) else {
                    // 可能输给并发刷新：赢家已把新凭据写盘，重读一次兜底。
                    if case .ok(let again) = readCredentials() {
                        let exp2 = (again["expires_at"] as? NSNumber)?.doubleValue ?? 0
                        if exp2 > ctx.clock(), Self.nonEmptyToken(again) != nil {
                            return again
                        }
                    }
                    return nil
                }
                writeCredentials(new)   // 写回失败：新 token 仍供本次使用，下轮重试
                return new
            }
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------------ 入口 ----

    public func usage() -> [String: Any] {
        var cred: [String: Any]
        switch readCredentials() {
        case .missing:
            return ["error": "no_credentials",
                    "detail": "无法读取 Kimi 凭据，请检查 KIMI_CODE_HOME 或打开 Kimi Code"]
        case .invalid:
            return ["error": "parse", "detail": "Kimi 凭据格式暂不可读，等待 Kimi Code 更新"]
        case .ok(let parsed):
            cred = parsed
        }
        guard let tokValue = cred["access_token"] else {
            return ["error": "no_token", "detail": "Kimi 凭据暂为空，等待 Kimi Code 更新登录态"]
        }
        guard var tok = tokValue as? String else {
            return ["error": "parse", "detail": "Kimi access_token 格式异常"]
        }
        if tok.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["error": "no_token", "detail": "Kimi 凭据暂为空，等待 Kimi Code 更新登录态"]
        }
        let expires = (cred["expires_at"] as? NSNumber)?.doubleValue ?? 0
        if !expires.isFinite || expires < 0 {
            return ["error": "parse", "detail": "Kimi 凭据有效期格式异常"]
        }
        if cred["expires_at"] is String {
            return ["error": "parse", "detail": "Kimi 凭据有效期格式异常"]
        }
        if expires > 0 && expires <= ctx.clock() {
            // 已过期：Kimi Code 仅活跃时才刷新，闲置期干等会让面板长期「暂时不可用」。
            if let fresh = freshCredentials(),
               let freshTok = fresh["access_token"] as? String,
               !freshTok.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cred = fresh
                tok = freshTok
            } else if cred["refresh_token"] == nil {
                return ["error": "expired",
                        "detail": "Kimi 访问令牌已过期且无 refresh_token，请运行 kimi login 重新登录"]
            } else {
                return ["error": "expired",
                        "detail": "Kimi 访问令牌过期且自动刷新失败（refresh_token 可能已轮换），"
                            + "请运行 kimi login 重新登录"]
            }
        }
        var (status, data) = ctx.http("\(apiBase())/usages",
                                      ["Authorization": "Bearer \(tok)",
                                       "Accept": "application/json"], nil, "GET")
        if status == 401 {
            // 磁盘 token 看着没过期却被拒（被别处轮换过）：走一次自愈，换新 token 重试一次。
            if let fresh = freshCredentials(),
               let freshTok = fresh["access_token"] as? String,
               !freshTok.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               freshTok != tok {
                tok = freshTok
                (status, data) = ctx.http("\(apiBase())/usages",
                                          ["Authorization": "Bearer \(tok)",
                                           "Accept": "application/json"], nil, "GET")
            }
        }
        if status == 401 {
            return ["error": "expired",
                    "detail": "Kimi 访问令牌已过期，请运行 kimi login 重新登录"]
        }
        guard status == 200 else {
            return ["error": "http_\(status)", "detail": "Kimi usages 接口返回 \(status)",
                    "_retry_after": data["_retry_after"] as Any]
        }
        // 周期配额（周/计划周期，按 resetTime 命名）；used 缺省时用 limit-remaining 反推
        var windows: [String: Any] = [:]
        if let usage = data["usage"] as? [String: Any],
           let lim = (usage["limit"] as? NSNumber)?.doubleValue {
            var used = (usage["used"] as? NSNumber)?.doubleValue
            if used == nil, let remaining = (usage["remaining"] as? NSNumber)?.doubleValue {
                used = lim - remaining
            }
            if let used {
                windows["7d"] = [
                      "pct": (lim == 0 ? NSNull() : (used / lim * 100)) as Any,
                    "resets_at": BillingNet.isoMs(usage["resetTime"]) as Any,
                    "used": used, "limit": lim, "unit": "requests",
                ]
            }
        }
        // 5 小时窗口（limits[0].duration=300 分钟）；同上反推
        for lt in data["limits"] as? [[String: Any]] ?? [] {
            guard let detail = lt["detail"] as? [String: Any],
                  let lim = (detail["limit"] as? NSNumber)?.doubleValue else { continue }
            var used = (detail["used"] as? NSNumber)?.doubleValue
            if used == nil, let remaining = (detail["remaining"] as? NSNumber)?.doubleValue {
                used = lim - remaining
            }
            guard let used else { continue }
            let win = lt["window"] as? [String: Any] ?? [:]
            let key = String(describing: win["duration"] ?? "") == "300" ? "5h" : "7d"
            windows[key] = [
                 "pct": (lim == 0 ? NSNull() : (used / lim * 100)) as Any,
                "resets_at": BillingNet.isoMs(detail["resetTime"]) as Any,
                "used": used, "limit": lim, "unit": "requests",
            ]
        }
        if windows.isEmpty {
            return ["error": "no_windows", "detail": "Kimi 接口未返回可用配额"]
        }
        let user = data["user"] as? [String: Any] ?? [:]
        let membership = user["membership"] as? [String: Any] ?? [:]
        let level = membership["level"] as? String
        return ["windows": windows,
                "plan": level.flatMap { Self.planNames[$0] } ?? level ?? "",
                "unit": "requests"]
    }
}
