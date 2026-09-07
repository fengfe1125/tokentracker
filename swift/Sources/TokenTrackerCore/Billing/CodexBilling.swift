//
//  CodexBilling.swift
//  TokenTrackerCore
//
//  移植 billing.py 的 Codex 部分：主路 chatgpt.com/backend-api/wham/usage
//  （复用 ~/.codex/auth.json，401 自动刷新并原子写回；refresh token 轮换，
//  不写回会把 Codex CLI 登出），`codex app-server` JSON-RPC 兑底。
//

import Foundation

public struct CodexBilling {
    static let whamURL = "https://chatgpt.com/backend-api/wham/usage"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let cliUA = "codex_cli_rs/0.150.1"

    static let winByMin = [300: "5h", 10_080: "7d", 43_200: "month", 44_640: "month"]
    static let winBySec = [18_000: "5h", 604_800: "7d", 2_592_000: "month", 2_678_400: "month"]

    public let ctx: BillingContext

    public init(ctx: BillingContext) {
        self.ctx = ctx
    }

    // ------------------------------------------------------------ 凭据 ----

    private var authPath: String {
        let home = ctx.env["CODEX_HOME"] ?? (ctx.home + "/.codex")
        return expandPath(home) + "/auth.json"
    }

    /// 读 auth.json → (tokens, writeBack)；写回保留文件里的全部键。
    func credentials() -> (tokens: [String: Any], save: ([String: Any]) -> Void)? {
        let path = authPath
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = parsed["tokens"] as? [String: Any],
              tokens["access_token"] != nil else { return nil }
        return (tokens, { newTokens in
            var updated = parsed
            updated["tokens"] = newTokens
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            fmt.timeZone = .current
            updated["last_refresh"] = fmt.string(from: Date())
            atomicWriteJSON(path, updated)
        })
    }

    private func refresh(_ refreshToken: String) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        let (status, data) = ctx.http(Self.tokenURL,
                                      ["Content-Type": "application/json"], body, "POST")
        guard status == 200, data["access_token"] != nil else {
            throw SQLiteError(message: "HTTP \(status)")
        }
        return data
    }

    // ------------------------------------------------------------ wham ----

    /// GET wham/usage（CodexBar/headroom 同款端点）。401 时用 refresh_token
    /// 换新并原子写回 auth.json。
    func usageWham() -> [String: Any] {
        guard var (tokens, save) = credentials() else {
            return ["error": "no_credentials", "detail": "未找到 ~/.codex/auth.json 登录态"]
        }
        func call(_ tok: String) -> (Int, [String: Any]) {
            var headers = ["Authorization": "Bearer \(tok)",
                           "Accept": "application/json",
                           "User-Agent": Self.cliUA]
            if let account = tokens["account_id"] as? String {
                headers["ChatGPT-Account-Id"] = account
            }
            return ctx.http(Self.whamURL, headers, nil, "GET")
        }

        var (status, data) = call(tokens["access_token"] as? String ?? "")
        if status == 401, let refreshToken = tokens["refresh_token"] as? String {
            do {
                let refreshed = try refresh(refreshToken)
                tokens["access_token"] = refreshed["access_token"]
                if let rt = refreshed["refresh_token"] as? String {
                    tokens["refresh_token"] = rt
                }
                if let idToken = refreshed["id_token"] as? String {
                    tokens["id_token"] = idToken
                }
                save(tokens)
                (status, data) = call(tokens["access_token"] as? String ?? "")
            } catch {
                return ["error": "refresh_failed",
                        "detail": "Codex token 刷新失败(\(error))，请运行 codex 重新登录"]
            }
        }
        guard status == 200 else {
            return ["error": "http_\(status)", "detail": "wham/usage 返回 \(status)",
                    "_retry_after": data["_retry_after"] as Any]
        }
        let rl = data["rate_limit"] as? [String: Any] ?? [:]
        var windows: [String: Any] = [:]
        for w in [rl["primary_window"], rl["secondary_window"]] {
            guard let window = w as? [String: Any] else { continue }
            let secs = (window["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
            guard let key = Self.winBySec[secs],
                  let pct = window["used_percent"] else { continue }
            var resets: Any = NSNull()
            if let resetAt = (window["reset_at"] as? NSNumber)?.doubleValue {
                resets = resetAt < 1e12 ? Int64(resetAt * 1000) : Int64(resetAt)
            }
            windows[key] = ["pct": (pct as? NSNumber)?.doubleValue ?? 0,
                            "resets_at": resets]
        }
        if windows.isEmpty {
            return ["error": "no_windows", "detail": "wham/usage 无窗口数据"]
        }
        let credits = data["credits"] as? [String: Any] ?? [:]
        return ["windows": windows, "plan": data["plan_type"] ?? "", "_via": "wham",
                "extra": ["balance": credits["balance"] as Any,
                          "unlimited": credits["unlimited"] as Any,
                          "spend_reached": (data["spend_control"] as? [String: Any])?["reached"] as Any]]
    }

    // -------------------------------------------------------- RPC 兑底 ----

    /// JSON-RPC over stdio 调 codex app-server。
    private func rpc(_ binPath: String) throws -> [String: Any] {
        // 图形化启动 PATH 极简：补齐常见安装位置（对齐 _spawn_env）
        var env = ProcessInfo.processInfo.environment
        let home = ctx.home
        var dirs = ["\(home)/.npm-global/bin", "\(home)/.local/bin", "\(home)/.volta/bin",
                    "\(home)/.bun/bin", "\(home)/Library/pnpm", "\(home)/.yarn/bin",
                    "/opt/homebrew/bin", "/usr/local/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: nvm),
           let latest = vers.sorted().last {
            dirs.insert("\(nvm)/\(latest)/bin", at: 0)
        }
        let existing = dirs.filter { FileManager.default.fileExists(atPath: $0) }
        env["PATH"] = (existing + [env["PATH"] ?? ""]).joined(separator: ":")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        var stdoutBuffer = Data()
        func send(_ obj: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: obj) {
                stdinPipe.fileHandleForWriting.write(data + Data("\n".utf8))
            }
        }
        func recv(_ wantID: Int, timeout: Double) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !process.isRunning {
                    let errText = String(data: stderrPipe.fileHandleForReading
                        .readDataToEndOfFile(), encoding: .utf8) ?? ""
                    throw SQLiteError(message:
                        "codex 进程提前退出(code=\(process.terminationStatus))："
                        + errText.trimmingCharacters(in: .whitespacesAndNewlines)
                            .prefix(200).description)
                }
                // select 0.5s 等价：poll 间隔读取
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if !chunk.isEmpty {
                    stdoutBuffer.append(chunk)
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = stdoutBuffer[..<nl]
                    stdoutBuffer.removeFirst(nl + 1)
                    guard let obj = try? JSONSerialization.jsonObject(with: line)
                            as? [String: Any] else { continue }
                    guard (obj["id"] as? NSNumber)?.intValue == wantID else { continue }
                    if let error = obj["error"] as? [String: Any] {
                        throw SQLiteError(message: error["message"] as? String ?? "rpc error")
                    }
                    return obj["result"] as? [String: Any] ?? [:]
                }
            }
            throw SQLiteError(message: "codex app-server 无响应")
        }

        defer {
            process.terminate()
            process.waitUntilExit()
        }
        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "tokentracker", "version": "0.1"]]])
        _ = try recv(1, timeout: 15)
        send(["method": "initialized", "params": [:] as [String: Any]])
        send(["id": 2, "method": "account/rateLimits/read", "params": [:] as [String: Any]])
        return try recv(2, timeout: 15)
    }

    private func usageRPC() -> [String: Any] {
        guard let bin = ctx.cliResolver("codex") else {
            return ["error": "no_binary", "detail": "未找到 codex 命令"]
        }
        let data: [String: Any]
        do {
            data = try rpc(bin)
        } catch {
            debugLog(error, binPath: bin)
            return ["error": "rpc_failed",
                    "detail": "Codex RPC 失败：\(error)（请确认已登录 codex）"]
        }
        guard let rl = data["rateLimits"] as? [String: Any], !rl.isEmpty else {
            return ["error": "no_limits", "detail": "Codex 未返回限额数据"]
        }
        var windows: [String: Any] = [:]
        for w in [rl["primary"], rl["secondary"]] {
            guard let window = w as? [String: Any] else { continue }
            let mins = (window["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            guard let key = Self.winByMin[mins],
                  let pct = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            var resets: Any = NSNull()
            if let resetAt = (window["resetsAt"] as? NSNumber)?.doubleValue {
                resets = resetAt < 1e12 ? Int64(resetAt * 1000) : Int64(resetAt)
            }
            windows[key] = ["pct": pct, "resets_at": resets]
        }
        if windows.isEmpty {
            return ["error": "no_windows", "detail": "Codex 无窗口数据"]
        }
        let credits = rl["credits"] as? [String: Any] ?? [:]
        return ["windows": windows, "plan": rl["planType"] ?? "", "_via": "rpc",
                "extra": ["balance": credits["balance"] as Any,
                          "unlimited": credits["unlimited"] as Any,
                          "spend_reached": rl["spendControlReached"] as Any]]
    }

    /// 失败诊断落盘：~/.tokentracker/codex_debug.log
    private func debugLog(_ error: Error, binPath: String) {
        let path = ctx.home + "/.tokentracker/codex_debug.log"
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let lines = "[\(fmt.string(from: Date()))] \(String(describing: error))\n"
            + "  bin=\(binPath)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(lines.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(lines.utf8))
        }
    }

    // ------------------------------------------------------------ 入口 ----

    /// wham/usage 为主，app-server RPC 兑底（结果带 _via 标明走的那条路）。
    public func usage() -> [String: Any] {
        let result = usageWham()
        if result["error"] == nil || result["error"] as? String == "http_429" {
            return result
        }
        let whamErr = result
        let rpcResult = usageRPC()
        if rpcResult["error"] == nil {
            return rpcResult
        }
        // 两条路都挂：报主路错误，附上兑底原因
        return ["error": whamErr["error"] as Any,
                "detail": "\(whamErr["detail"] ?? "")；RPC 兑底也失败：\(rpcResult["detail"] ?? "")",
                "_retry_after": whamErr["_retry_after"] as Any]
    }
}
