//
//  BillingContext.swift
//  TokenTrackerCore
//
//  Codex 账号切换等本地功能共用的注入上下文（home / 环境变量 / 时钟 / HTTP / CLI 解析），
//  测试注入临时目录即可隔离。官方配额只走 Subscriptions/ 的 TokenTracker 账号库，
//  这里不读取也不回写其他工具的钥匙串或凭据文件。
//

import Foundation

public struct BillingContext {
    public var home: String
    public var env: [String: String]
    public var clock: () -> Double
    public var http: BillingHTTP
    public var cliResolver: (String) -> String?

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
    }
}

/// 原子写 JSON 文件：同目录唯一临时文件以目标权限创建（不会出现短暂的全局可读窗口），
/// 写满并 fsync 后 rename 覆盖。
public func atomicWriteJSON(_ path: String, _ object: [String: Any], permissions: Int = 0o600) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tmp = path + ".tmp-\(getpid())-\(UUID().uuidString.prefix(8))"
    let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(permissions))
    guard fd >= 0 else { return }
    // umask 可能去掉部分位；显式设回，保证与请求的权限一致。
    _ = fchmod(fd, mode_t(permissions))
    let written = data.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
            let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    let synced = written && fsync(fd) == 0
    close(fd)
    if !synced || rename(tmp, path) != 0 {
        unlink(tmp)
    }
}
