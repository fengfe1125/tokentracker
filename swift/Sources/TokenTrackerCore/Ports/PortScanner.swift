//
//  PortScanner.swift
//  TokenTrackerCore
//
//  本机监听端口：用系统自带的 lsof / ps 读出端口、监听地址、进程、命令行、
//  内存占用、工作目录（含父进程回退）和运行时长。
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
    /// 父进程工作目录（子进程 cwd 为 / 或缺失时的匹配回退）
    public var parentCwd: String?
    /// 可执行文件路径或 ps 报告的命令名
    public var executable: String?
    /// 完整启动命令行（只在内存中展示，不持久化、不上传）
    public var commandLine: String?
    /// 已运行秒数；读不到时为 nil
    public var uptime: Int?
    /// 常驻内存（字节）；读不到时为 nil
    public var memoryBytes: Int64?
    /// 父进程 PID
    public var parentPID: Int32?
    /// 监听绑定地址（如 127.0.0.1、::1、*、0.0.0.0）
    public var addresses: [String]
    /// 识别出的开发框架/服务简称（如 vite、next、wrangler、uvicorn）
    public var serviceLabel: String?
    /// 匹配到的开发项目（PortMatcher 填入）
    public var projectID: String?
    public var projectName: String?

    public var id: Int { port }
    public var pid: Int32 { pids.first ?? 0 }

    /// 全部绑定地址均为本机回环地址（127.x / ::1 / localhost）
    public var isLocalOnly: Bool {
        guard !addresses.isEmpty else { return true }
        return addresses.allSatisfy { addr in
            let low = addr.lowercased()
            return low == "127.0.0.1" || low == "::1" || low == "localhost" || low.hasPrefix("127.")
        }
    }

    /// 紧凑展示的监听范围标签
    public var bindDisplay: String {
        if addresses.isEmpty { return "localhost" }
        if addresses.contains("*") || addresses.contains("0.0.0.0") || addresses.contains("::") {
            return "0.0.0.0"
        }
        return addresses.first ?? "localhost"
    }

    /// 展示名：对 node/python 等通用运行时优先标出识别到的框架
    public var displayName: String {
        if let serviceLabel, !serviceLabel.isEmpty, serviceLabel.lowercased() != process.lowercased() {
            return "\(serviceLabel) (\(process))"
        }
        return process
    }

    public init(port: Int, pids: [Int32], process: String, uid: Int, user: String,
                cwd: String? = nil, parentCwd: String? = nil, executable: String? = nil,
                commandLine: String? = nil, uptime: Int? = nil, memoryBytes: Int64? = nil,
                parentPID: Int32? = nil, addresses: [String] = [], serviceLabel: String? = nil,
                projectID: String? = nil, projectName: String? = nil) {
        self.port = port; self.pids = pids; self.process = process
        self.uid = uid; self.user = user; self.cwd = cwd; self.parentCwd = parentCwd
        self.executable = executable; self.commandLine = commandLine
        self.uptime = uptime; self.memoryBytes = memoryBytes; self.parentPID = parentPID
        self.addresses = addresses; self.serviceLabel = serviceLabel
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
        let detailRaw = run(["/bin/ps", "-o", "pid=,ppid=,etime=,rss=,comm=", "-p", pidList])
        let details = Self.parseProcessDetails(detailRaw)
        let argsRaw = run(["/bin/ps", "-ww", "-o", "pid=,args=", "-p", pidList])
        let commandLines = Self.parseCommandLines(argsRaw)

        // 子进程 cwd 为 nil 或 "/" 时，批量补查一次父进程 cwd 以便准确归属到项目
        let parentPIDs = Set(listeners.compactMap { listener -> Int32? in
            let cwd = cwds[listener.pid]
            guard cwd == nil || cwd == "/" else { return nil }
            guard let ppid = details[listener.pid]?.ppid, ppid > 1 else { return nil }
            return ppid
        })
        let parentCwds: [Int32: String] = parentPIDs.isEmpty ? [:] : Self.parseCwd(
            run(["/usr/sbin/lsof", "-a", "-d", "cwd", "-Fpn", "-p",
                 parentPIDs.sorted().map(String.init).joined(separator: ",")]))

        var byPort: [Int: ListeningPort] = [:]
        for listener in listeners.sorted(by: { $0.pid < $1.pid }) {
            let info = details[listener.pid]
            let cmdLine = commandLines[listener.pid]
            let parentCwd = info?.ppid.flatMap { parentCwds[$0] }
            let service = Self.detectService(process: listener.command, commandLine: cmdLine)
            for port in listener.ports {
                let addrs = listener.addressesByPort[port] ?? []
                if var existing = byPort[port] {
                    if !existing.pids.contains(listener.pid) { existing.pids.append(listener.pid) }
                    let merged = Set(existing.addresses).union(addrs).sorted()
                    existing.addresses = merged
                    if existing.cwd == nil || existing.cwd == "/", let cwd = cwds[listener.pid], cwd != "/" {
                        existing.cwd = cwd
                    }
                    if existing.parentCwd == nil, let parentCwd { existing.parentCwd = parentCwd }
                    if existing.serviceLabel == nil, let service { existing.serviceLabel = service }
                    byPort[port] = existing
                } else {
                    byPort[port] = ListeningPort(
                        port: port, pids: [listener.pid], process: listener.command,
                        uid: listener.uid, user: listener.user,
                        cwd: cwds[listener.pid], parentCwd: parentCwd,
                        executable: info?.command, commandLine: cmdLine,
                        uptime: info?.uptime, memoryBytes: info?.memoryBytes,
                        parentPID: info?.ppid, addresses: addrs.sorted(),
                        serviceLabel: service)
                }
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    // ------------------------------------------------------------ 解析 ----

    struct Listener: Equatable {
        var pid: Int32, command: String, uid: Int, user: String
        var ports: Set<Int>
        var addressesByPort: [Int: Set<String>] = [:]
    }

    struct ProcessDetail: Equatable {
        var ppid: Int32?
        var uptime: Int?
        var memoryBytes: Int64?
        var command: String
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
                // *:7000、127.0.0.1:3000、[::1]:3000、[fe80::1]:8080
                if let colon = value.lastIndex(of: ":"),
                   let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) {
                    current?.ports.insert(port)
                    var host = String(value[..<colon])
                    if host.hasPrefix("[") && host.hasSuffix("]") {
                        host = String(host.dropFirst().dropLast())
                    }
                    if !host.isEmpty {
                        current?.addressesByPort[port, default: []].insert(host)
                    }
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

    /// ps -o pid=,etime=,comm=：命令名可能带空格，取前两列之后的全部（保留兼容旧格式）。
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

    /// ps -o pid=,ppid=,etime=,rss=,comm=；自动兼容旧 3 列（pid etime comm）测试输出。
    static func parseProcessDetails(_ text: String) -> [Int32: ProcessDetail] {
        var result: [Int32: ProcessDetail] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts5 = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            if parts5.count >= 5,
               let pid = Int32(parts5[0]),
               let ppid = Int32(parts5[1]),
               let uptime = parseElapsed(String(parts5[2])),
               let rssKB = Int64(parts5[3]) {
                let command = parts5[4].trimmingCharacters(in: .whitespaces)
                result[pid] = ProcessDetail(ppid: ppid, uptime: uptime,
                                            memoryBytes: rssKB > 0 ? rssKB * 1024 : nil,
                                            command: command)
                continue
            }
            // 回退 3 列格式（pid etime comm）
            let parts3 = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts3.count >= 2, let pid = Int32(parts3[0]) else { continue }
            let command = parts3.count > 2 ? parts3[2].trimmingCharacters(in: .whitespaces) : ""
            result[pid] = ProcessDetail(ppid: nil, uptime: parseElapsed(String(parts3[1])),
                                        memoryBytes: nil, command: command)
        }
        return result
    }

    /// ps -ww -o pid=,args=：解析完整命令行。
    static func parseCommandLines(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let args = parts[1].trimmingCharacters(in: .whitespaces)
            // 忽略测试中把 `ps -o pid=,etime=,comm=` 复用到这里的误匹配行
            let firstToken = args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if parseElapsed(firstToken) != nil { continue }
            if !args.isEmpty { result[pid] = args }
        }
        return result
    }

    /// 为 node / python / ruby / java 等通用运行时识别实际开发的框架或服务名。
    static func detectService(process: String, commandLine: String?) -> String? {
        guard let commandLine, !commandLine.isEmpty else { return nil }
        let proc = process.lowercased()
        let genericRuntimes: Set<String> = [
            "node", "bun", "deno", "python", "python3", "python3.11", "python3.12", "python3.13",
            "ruby", "java", "php", "beam.smp", "dotnet", "tsx",
        ]
        guard genericRuntimes.contains(proc) || proc.hasPrefix("python3.") else { return nil }
        let low = commandLine.lowercased()
        let hints: [(needle: String, label: String)] = [
            ("next-server", "Next.js"), ("/next", "Next.js"), (" next ", "Next.js"),
            ("/vite", "Vite"), (" vite", "Vite"),
            ("/nuxt", "Nuxt"), (" nuxt", "Nuxt"),
            ("/astro", "Astro"), (" astro", "Astro"),
            ("/remix", "Remix"),
            ("wrangler", "Wrangler"),
            ("storybook", "Storybook"),
            ("webpack", "Webpack"),
            ("turbopack", "Turbopack"),
            ("esbuild", "esbuild"),
            ("uvicorn", "Uvicorn"),
            ("gunicorn", "Gunicorn"),
            ("fastapi", "FastAPI"),
            ("streamlit", "Streamlit"),
            ("manage.py", "Django"),
            ("flask", "Flask"),
            ("http.server", "http.server"),
            ("jupyter", "Jupyter"),
            ("rails", "Rails"),
            ("puma", "Puma"),
            ("artisan", "Laravel"),
            ("spring", "Spring"),
            ("gradle", "Gradle"),
            ("nodemon", "nodemon"),
            ("tsx", "tsx"),
        ]
        for hint in hints where low.contains(hint.needle) {
            return hint.label
        }
        return nil
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
