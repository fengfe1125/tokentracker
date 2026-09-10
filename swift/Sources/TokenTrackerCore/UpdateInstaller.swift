//
//  UpdateInstaller.swift
//  TokenTrackerCore
//
//  应用内更新：拉 GitHub 最新 release → 下载 dmg → 校验 → 挂载 → 换掉自身
//  bundle → 重启。Swift 版独有（Python 版只有 updatecheck 的检查部分），
//  不碰 ~/.tokentracker/update_check.json 的格式，两版缓存仍然通用。
//
//  ⚠️ 签名现状：仓库目前是 ad-hoc 签名、未公证。从网上下回来的 dmg 带
//  com.apple.quarantine，ad-hoc 的包过不了 Gatekeeper 评估，所以安装的最后
//  一步必须清掉 quarantine 属性，否则换完直接起不来。这是在给自己开后门，
//  因此清之前必须全部通过：GitHub API（HTTPS）给出的 sha256、codesign 校验、
//  bundle id 一致。正经解法是 Developer ID 签名 + 公证，那样这一步就能删掉。
//

import CryptoKit
import Foundation

public struct ReleaseAsset: Equatable, Sendable {
    public var name: String
    public var downloadURL: String
    public var size: Int64
    /// GitHub API 的 digest 字段，形如 "sha256:abc..."；老 release 可能没有
    public var sha256: String?
}

public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var htmlURL: String
    public var dmg: ReleaseAsset?
}

public enum UpdateInstallError: LocalizedError, Equatable {
    case noRelease
    case noAsset
    case badJSON
    case checksumMismatch(expected: String, actual: String)
    case notAnAppBundle(String)
    case appNotFoundInDMG
    case bundleIDMismatch(expected: String, actual: String)
    case commandFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .noRelease: return "没有查到发布版本"
        case .noAsset: return "这个版本没有提供 .dmg 安装包"
        case .badJSON: return "GitHub 返回的内容无法解析"
        case .checksumMismatch(let e, let a):
            return "下载校验失败（期望 \(e.prefix(12))…，实际 \(a.prefix(12))…）"
        case .notAnAppBundle(let p): return "当前不是以 .app 方式运行（\(p)），无法自我更新"
        case .appNotFoundInDMG: return "安装包里找不到 TokenTracker.app"
        case .bundleIDMismatch(let e, let a):
            return "安装包的标识不匹配（期望 \(e)，实际 \(a)）"
        case .commandFailed(let cmd, let code): return "\(cmd) 失败（退出码 \(code)）"
        }
    }
}

public struct UpdateInstaller: Sendable {
    public static let bundleID = "com.tokentracker.desktop.v2"

    /// 注入缝：抓 JSON（测试注入）
    public var fetch: @Sendable (String) throws -> Data
    /// 注入缝：下载文件到本地（测试注入）。progress 取值 0…1
    public var downloadFile: @Sendable (String, @escaping @Sendable (Double) -> Void) throws -> URL
    /// 注入缝：跑外部命令，返回 stdout（测试注入，避免真的挂载/替换）
    public var run: @Sendable ([String]) throws -> String

    public init(fetch: (@Sendable (String) throws -> Data)? = nil,
                downloadFile: (@Sendable (String, @escaping @Sendable (Double) -> Void) throws -> URL)? = nil,
                run: (@Sendable ([String]) throws -> String)? = nil) {
        self.fetch = fetch ?? Self.defaultFetch
        self.downloadFile = downloadFile ?? Self.defaultDownload
        self.run = run ?? Self.defaultRun
    }

    // ------------------------------------------------------------ 查询 ----

    /// 解析 GitHub releases/latest 的响应；挑第一个 .dmg 资产。
    public static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateInstallError.badJSON
        }
        let tag = obj["tag_name"] as? String ?? ""
        guard !tag.isEmpty else { throw UpdateInstallError.noRelease }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String ?? "").hasSuffix(".dmg") }.map {
            ReleaseAsset(name: $0["name"] as? String ?? "",
                         downloadURL: $0["browser_download_url"] as? String ?? "",
                         size: ($0["size"] as? NSNumber)?.int64Value ?? 0,
                         sha256: ($0["digest"] as? String)?
                             .replacingOccurrences(of: "sha256:", with: ""))
        }
        return ReleaseInfo(tag: tag, htmlURL: obj["html_url"] as? String ?? "", dmg: dmg)
    }

    public func latestRelease() throws -> ReleaseInfo {
        try Self.parseRelease(
            fetch("https://api.github.com/repos/\(UpdateChecker.repo)/releases/latest"))
    }

    // ------------------------------------------------------------ 校验 ----

    public static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// release 没给 digest 时跳过（老版本没有这个字段），给了就必须对上。
    public static func verifyChecksum(_ file: URL, expected: String?) throws {
        guard let expected, !expected.isEmpty else { return }
        let actual = try sha256Hex(of: file)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw UpdateInstallError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    // ------------------------------------------------------------ 安装 ----

    /// hdiutil attach 的输出里挑出挂载点（最后一列是路径）。
    public static func mountPoint(fromAttachOutput output: String) -> String? {
        for line in output.split(separator: "\n").reversed() {
            guard let range = line.range(of: "\t/") ?? line.range(of: "  /") else { continue }
            let path = line[range.lowerBound...].trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    /// 下载 → 校验 → 挂载 → 校验签名与 bundle id → 就地替换 → 卸载。
    /// 返回被替换的 .app 路径。中途任何一步失败都不会动原来的 bundle。
    @discardableResult
    public func install(dmg: URL, into appPath: String, expectedSHA256: String? = nil) throws
        -> String {
        guard appPath.hasSuffix(".app") else {
            throw UpdateInstallError.notAnAppBundle(appPath)
        }
        try Self.verifyChecksum(dmg, expected: expectedSHA256)

        let attach = try run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly",
                              "-mountrandom", "/tmp", dmg.path])
        guard let mount = Self.mountPoint(fromAttachOutput: attach) else {
            throw UpdateInstallError.appNotFoundInDMG
        }
        defer { _ = try? run(["/usr/bin/hdiutil", "detach", mount, "-quiet"]) }

        let newApp = mount + "/TokenTracker.app"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newApp, isDirectory: &isDir),
              isDir.boolValue else {
            throw UpdateInstallError.appNotFoundInDMG
        }
        // 签名完整（没被中途篡改）
        _ = try run(["/usr/bin/codesign", "--verify", "--strict", newApp])
        // 身份一致（不是别的 app 冒名）
        let gotID = try run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier",
                             newApp + "/Contents/Info.plist"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard gotID == Self.bundleID else {
            throw UpdateInstallError.bundleIDMismatch(expected: Self.bundleID, actual: gotID)
        }

        // 先拷到目标同卷的临时位置，成功后再换——中途失败原 bundle 原封不动
        let staging = appPath + ".incoming"
        _ = try? run(["/bin/rm", "-rf", staging])
        _ = try run(["/bin/cp", "-R", newApp, staging])
        // 见文件头说明：ad-hoc 签名 + 网络下载 = 过不了 Gatekeeper，
        // 上面三道校验都过了才走到这里
        _ = try? run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", staging])

        let backup = appPath + ".old"
        _ = try? run(["/bin/rm", "-rf", backup])
        _ = try run(["/bin/mv", appPath, backup])
        do {
            _ = try run(["/bin/mv", staging, appPath])
        } catch {
            _ = try? run(["/bin/mv", backup, appPath])   // 回滚
            throw error
        }
        _ = try? run(["/bin/rm", "-rf", backup])
        return appPath
    }

    /// 等当前进程退出后把新版本拉起来（自身 bundle 已被换掉，只能靠外部进程）。
    public func scheduleRelaunch(appPath: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/open \(Resume.shlexQuote(appPath))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
    }

    // ------------------------------------------------------------ 默认实现 ----

    private static let defaultFetch: @Sendable (String) throws -> Data = { url in
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("TokenTracker-update-check", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        final class Box: @unchecked Sendable {
            var result: Result<Data, Error> = .failure(SQLiteError(message: "no response"))
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data { box.result = .success(data) }
            else { box.result = .failure(error ?? SQLiteError(message: "unknown")) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return try box.result.get()
    }

    private static let defaultDownload:
        @Sendable (String, @escaping @Sendable (Double) -> Void) throws -> URL = { url, progress in
        final class Box: @unchecked Sendable {
            var result: Result<URL, Error> = .failure(SQLiteError(message: "no response"))
            var observation: NSKeyValueObservation?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: URL(string: url)!) { temp, _, error in
            if let temp {
                // 回调返回后系统会删掉 temp，先挪到自己的位置
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tokentracker-update-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: temp, to: dest)
                    box.result = .success(dest)
                } catch {
                    box.result = .failure(error)
                }
            } else {
                box.result = .failure(error ?? SQLiteError(message: "unknown"))
            }
            semaphore.signal()
        }
        box.observation = task.progress.observe(\.fractionCompleted) { p, _ in
            progress(p.fractionCompleted)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 300)
        box.observation?.invalidate()
        return try box.result.get()
    }

    private static let defaultRun: @Sendable ([String]) throws -> String = { args in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.commandFailed(
                (args[0] as NSString).lastPathComponent, process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
