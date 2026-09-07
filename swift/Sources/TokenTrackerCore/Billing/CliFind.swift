//
//  CliFind.swift
//  TokenTrackerCore
//
//  移植 clifind.py：CLI 绝对路径三级兜底（进程 PATH → 登录 shell 探测 →
//  常见安装目录），进程内缓存。打包 App 的 PATH 极简化（launchd 只给
//  /usr/bin），用户级 CLI 装在 ~/.npm-global/bin 等处。
//

import Foundation

public enum CliFind {
    static let commonDirs = [
        "~/.local/bin", "~/.npm-global/bin", "~/.kimi-code/bin", "~/.opencode/bin",
        "~/.volta/bin", "~/.bun/bin", "~/.deno/bin", "~/.asdf/shims", "~/.cargo/bin",
        "~/.local/share/mise/shims", "/opt/homebrew/bin", "/usr/local/bin",
    ]

    private static nonisolated(unsafe) var cache: [String: String?] = [:]
    private static let lock = NSLock()

    /// 登录 shell 探测：拿到用户 .zprofile/.zshrc 里的真实 PATH。
    private static func probeLoginShell(_ name: String) -> String? {
        guard FileManager.default.fileExists(atPath: "/bin/zsh") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        var data = Data()
        while Date() < deadline {
            data.append(pipe.fileHandleForReading.availableData)
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // 取最后一行：rc 文件可能回显提示语；command -v 输出绝对路径
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
                return trimmed
            }
        }
        return nil
    }

    private static func probeCommonDirs(_ name: String) -> String? {
        for dir in commonDirs {
            let path = expandPath(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// 解析 CLI 绝对路径；找不到返回 nil。结果进程内缓存。
    public static func resolve(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let path = which(name) ?? probeLoginShell(name) ?? probeCommonDirs(name)
        cache[name] = path
        return path
    }

    public static func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
