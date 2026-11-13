//
//  PortScanner.swift
//  TokenTrackerCore
//
//  本机监听端口：用系统自带的 lsof / ps 读出端口、进程、工作目录和运行时长。
//  只读、只在内存里，不写入用量库，也不进入任何公开统计。
//

import Foundation

/// 一个正在监听的 TCP 端口，以及占用它的进程。
public struct ListeningPort: Identifiable, Sendable, Equatable {
    public var port: Int
    /// 占用这个端口的进程；多个进程共用时按 PID 升序，第一个通常是父进程
    public var pids: [Int32]
    public var process: String
    public var uid: Int
    public var user: String
    /// 进程工作目录；读不到时为 nil
    public var cwd: String?
    /// 可执行文件路径或 ps 报告的命令名
    public var executable: String?
    /// 已运行秒数；读不到时为 nil
    public var uptime: Int?
    /// 匹配到的开发项目（PortMatcher 填入）
    public var projectID: String?
    public var projectName: String?

    public var id: Int { port }
    public var pid: Int32 { pids.first ?? 0 }

    public init(port: Int, pids: [Int32], process: String, uid: Int, user: String,
                cwd: String? = nil, executable: String? = nil, uptime: Int? = nil,
                projectID: String? = nil, projectName: String? = nil) {
        self.port = port; self.pids = pids; self.process = process
        self.uid = uid; self.user = user; self.cwd = cwd
        self.executable = executable; self.uptime = uptime
        self.projectID = projectID; self.projectName = projectName
    }
}

public struct PortScanner: Sendable {
    /// 执行命令并返回标准输出；失败返回空串（测试注入）
    public var run: @Sendable ([String]) -> String

    public init(run: (@Sendable ([String]) -> String)? = nil) {
        self.run = run ?? PortScanner.execute
    }

    public func scan() -> [ListeningPort] {
        let listeners = Self.parseListeners(
            run(["/usr/sbin/lsof", "+c0", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcuLn"]))
        guard !listeners.isEmpty else { return [] }
        let pidList = Set(listeners.map(\.pid)).sorted().map(String.init).joined(separator: ",")
        let cwds = Self.parseCwd(run(["/usr/sbin/lsof", "-a", "-d", "cwd", "-Fpn", "-p", pidList]))
        let processes = Self.parseProcesses(run(["/bin/ps", "-o", "pid=,etime=,comm=", "-p", pidList]))

        var byPort: [Int: ListeningPort] = [:]
        for listener in listeners.sorted(by: { $0.pid < $1.pid }) {
            for port in listener.ports {
                if var existing = byPort[port] {
                    if !existing.pids.contains(listener.pid) { existing.pids.append(listener.pid) }
                    byPort[port] = existing
                } else {
                    let info = processes[listener.pid]
                    byPort[port] = ListeningPort(
                        port: port, pids: [listener.pid], process: listener.command,
                        uid: listener.uid, user: listener.user, cwd: cwds[listener.pid],
                        executable: info?.command, uptime: info?.uptime)
                }
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    // ------------------------------------------------------------ 解析 ----

    struct Listener: Equatable {
        var pid: Int32, command: String, uid: Int, user: String, ports: Set<Int>
    }

    /// lsof -F pcuLn：每个进程以 p 行开头，随后是 c/u/L，再是若干 f/n 行。
    static func parseListeners(_ text: String) -> [Listener] {
        var result: [Listener] = []
        var current: Listener?
        func flush() {
            if let current, !current.ports.isEmpty { result.append(current) }
        }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                current = Int32(value).map { Listener(pid: $0, command: "", uid: -1, user: "", ports: []) }
            case "c": current?.command = value
            case "u": current?.uid = Int(value) ?? -1
            case "L": current?.user = value
            case "n":
                // *:7000、127.0.0.1:3000、[::1]:3000
                if let colon = value.lastIndex(of: ":"),
                   let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) {
                    current?.ports.insert(port)
                }
            default: break
            }
        }
        flush()
        return result
    }

    /// lsof -a -d cwd -Fpn：p 行后跟 fcwd 和 n<目录>。
    static func parseCwd(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" { pid = Int32(value) }
            else if tag == "n", let pid, value.hasPrefix("/") { result[pid] = value }
        }
        return result
    }

    /// ps -o pid=,etime=,comm=：命令名可能带空格，取前两列之后的全部。
    static func parseProcesses(_ text: String) -> [Int32: (uptime: Int?, command: String)] {
        var result: [Int32: (uptime: Int?, command: String)] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let command = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            result[pid] = (parseElapsed(String(parts[1])), command)
        }
        return result
    }

    /// ps 的 etime：[[dd-]hh:]mm:ss
    static func parseElapsed(_ text: String) -> Int? {
        var days = 0
        var clock = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            guard let d = Int(text[..<dash]) else { return nil }
            days = d
            clock = text[text.index(after: dash)...]
        }
        let fields = clock.split(separator: ":").map { Int($0) }
        guard (2...3).contains(fields.count), !fields.contains(nil) else { return nil }
        let values = fields.compactMap { $0 }
        let seconds = values.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }

    // ------------------------------------------------------------ 执行 ----

    /// 默认执行器：5 秒超时，退出码不为 0 时仍返回已有输出（lsof 遇到已退出的 PID 会返回 1）。
    static func execute(_ argv: [String]) -> String {
        guard let path = argv.first, FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(argv.dropFirst())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}
