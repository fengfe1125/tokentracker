//
//  BillingContext.swift
//  TokenTrackerCore
//
//  四家官方配额抓取共用的注入上下文（对应 Python 测试里 patch 的
//  os.environ / time.time / _http_json / _disk_path / 钥匙串等）。
//

import Foundation

public struct BillingContext {
    public var home: String
    public var env: [String: String]
    public var clock: () -> Double
    public var http: BillingHTTP
    public var cliResolver: (String) -> String?

    /// 钥匙串读写（默认走 security CLI；测试注入内存实现）
    public var keychainRead: () -> [String: Any]?
    public var keychainWrite: ([String: Any]) -> Bool

    public init(home: String = NSHomeDirectory(),
                env: [String: String] = ProcessInfo.processInfo.environment,
                clock: (() -> Double)? = nil,
                http: @escaping BillingHTTP = BillingNet.httpJSON,
                cliResolver: ((String) -> String?)? = nil) {
        self.home = home
        self.env = env
        self.clock = clock ?? { Date().timeIntervalSince1970 }
        self.http = http
        self.cliResolver = cliResolver ?? CliFind.resolve
        self.keychainRead = { Self.defaultKeychainRead() }
        self.keychainWrite = { Self.defaultKeychainWrite($0) }
    }

    // ------------------------------------------------------------ 钥匙串 ----

    static let claudeKCService = "Claude Code-credentials"

    /// macOS 钥匙串读 Claude Code 登录态（整个 JSON，含 mcpOAuth 等其他顶层键）。
    static func defaultKeychainRead() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", claudeKCService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["claudeAiOauth"] != nil else { return nil }
        return dict
    }

    /// 整体回写钥匙串条目（保留 mcpOAuth 等键）。账号名从条目属性读，读不到就不写。
    static func defaultKeychainWrite(_ data: [String: Any]) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        probe.arguments = ["find-generic-password", "-g", "-s", claudeKCService]
        let outPipe = Pipe()
        let errPipe = Pipe()
        probe.standardOutput = outPipe
        probe.standardError = errPipe
        do { try probe.run() } catch { return false }
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard let errText = String(data: errData, encoding: .utf8),
              let match = try? NSRegularExpression(
                pattern: #""acct"<blob>="([^"]+)""#)
                .firstMatch(in: errText, range: NSRange(errText.startIndex..., in: errText)),
              let acctRange = Range(match.range(at: 1), in: errText)
        else { return false }
        let acct = String(errText[acctRange])
        guard !acct.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: data),
              let jsonText = String(data: json, encoding: .utf8) else { return false }
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        write.arguments = ["add-generic-password", "-U", "-a", acct,
                           "-s", claudeKCService, "-w", jsonText]
        write.standardOutput = FileHandle.nullDevice
        write.standardError = FileHandle.nullDevice
        do { try write.run() } catch { return false }
        write.waitUntilExit()
        return write.terminationStatus == 0
    }
}

/// 原子写 JSON 文件（tmp + rename，0600）。对齐 billing.py 的 os.replace。
public func atomicWriteJSON(_ path: String, _ object: [String: Any], permissions: Int = 0o600) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tmp = path + ".tmp"
    guard FileManager.default.createFile(atPath: tmp, contents: data) else { return }
    // chmod 后 rename（rename 保留 tmp 的 inode 属性，os.replace 同款语义）
    chmod(tmp, mode_t(permissions))
    if rename(tmp, path) != 0 {
        try? FileManager.default.removeItem(atPath: tmp)
    }
}
