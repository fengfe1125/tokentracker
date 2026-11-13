//
//  PortControl.swift
//  TokenTrackerCore
//
//  结束占用端口的进程、拼出在终端里启动项目的命令。
//  结束进程只发信号，不提权；系统进程和别的用户的进程一律拒绝。
//

import Foundation

public struct PortControl: Sendable {
    /// 发信号（默认 Darwin.kill；测试注入）
    public var signal: @Sendable (Int32, Int32) -> Int32
    public var currentUID: Int
    public var ownPID: Int32

    public init(signal: (@Sendable (Int32, Int32) -> Int32)? = nil,
                currentUID: Int = Int(getuid()),
                ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.signal = signal ?? { pid, sig in kill(pid, sig) }
        self.currentUID = currentUID
        self.ownPID = ownPID
    }

    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    /// 系统自带的常驻进程（隔空播放接收器等）：只显示，不提供关闭。
    public static func isSystem(_ port: ListeningPort) -> Bool {
        guard let executable = port.executable else { return false }
        return systemPrefixes.contains { executable.hasPrefix($0) }
    }

    /// 各 Agent 的命令行名字。它们常驻在项目目录里并监听本地端口，但不是项目的开发服务器。
    static let agentNames: Set<String> = Set(Resume.resumePrefix.values.compactMap(\.first))

    /// 占用端口的是不是某个 Agent 自己（进程名或可执行路径里有它的名字）。
    /// 这类端口仍归到项目下显示，但「停止项目」不会结束它们。
    public static func isAgent(_ port: ListeningPort) -> Bool {
        func matches(_ component: Substring) -> Bool {
            var name = component.lowercased()
            if name.hasSuffix(".app") { name.removeLast(4) }
            return agentNames.contains(name)
        }
        if matches(Substring(port.process)) { return true }
        return (port.executable ?? "").split(separator: "/").contains(where: matches)
    }

    public func canTerminate(_ port: ListeningPort) -> Bool {
        !port.pids.isEmpty && port.uid == currentUID && !Self.isSystem(port)
            && port.pids.allSatisfy { $0 > 1 && $0 != ownPID }
    }

    /// 向这些端口的进程发 SIGTERM（force 时 SIGKILL）。返回没能发出信号的 PID。
    @discardableResult
    public func terminate(_ ports: [ListeningPort], force: Bool = false) -> [Int32] {
        var failed: [Int32] = []
        var seen: Set<Int32> = []
        for port in ports {
            guard canTerminate(port) else {
                failed.append(contentsOf: port.pids.filter { seen.insert($0).inserted })
                continue
            }
            for pid in port.pids where seen.insert(pid).inserted {
                if signal(pid, force ? SIGKILL : SIGTERM) != 0 { failed.append(pid) }
            }
        }
        return failed
    }

    /// 命令会原样交给用户的 shell：只拦掉换行和 NUL，长度不超过 500。
    public static func isValidCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && command.count <= 500
            && !command.contains(where: { $0.isNewline || $0 == "\0" })
    }

    /// 在终端里执行的整行：先进项目目录再跑启动命令。目录按不可信内容转义。
    public static func startLine(directory: String, command: String) -> String? {
        guard directory.hasPrefix("/"), !directory.contains("\0"), isValidCommand(command) else { return nil }
        return "cd \(Resume.shlexQuote(directory)) && \(command.trimmingCharacters(in: .whitespaces))"
    }
}
