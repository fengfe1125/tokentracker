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

    /// 只接受普通命令名，避免拼进 shell 命令时被解释。
    static func isPlainCommandName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// 登录 shell 探测：拿到用户 .zprofile/.zshrc 里的真实 PATH。
    /// 读取在后台进行，超过 timeout 即终止 shell：rc 文件卡住也不会拖住调用方。
    static func probeLoginShell(_ name: String, shell: String = "/bin/zsh",
                                timeout: TimeInterval = 4) -> String? {
        guard isPlainCommandName(name), FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v \(name)"]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // 输出很短；用 readabilityHandler 增量收集，不在任何线程上阻塞读管道
        // （rc 里启动的后台子进程可能一直持有写端）。
        final class Output: @unchecked Sendable {
            let lock = NSLock(); var data = Data()
            func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
            var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let output = Output()
        let eof = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; eof.signal() } else { output.append(chunk) }
        }
        do { try process.run() } catch { reader.readabilityHandler = nil; return nil }
        defer { reader.readabilityHandler = nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        _ = eof.wait(timeout: .now() + 0.5)
        guard let text = String(data: output.snapshot, encoding: .utf8) else { return nil }
        // 取最后一行：rc 文件可能回显提示语；command -v 输出绝对路径
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: trimmed) {
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
    /// 探测期间不持锁：一个 CLI 的登录 shell 探测变慢不会阻塞其他 CLI 的解析。
    public static func resolve(_ name: String) -> String? {
        lock.lock()
        if let cached = cache[name] { lock.unlock(); return cached }
        lock.unlock()
        let path = which(name) ?? probeLoginShell(name) ?? probeCommonDirs(name)
        lock.lock()
        cache[name] = path
        lock.unlock()
        return path
    }

    public static func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
