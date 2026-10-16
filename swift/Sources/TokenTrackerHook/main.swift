import Foundation
import AppKit
import TokenTrackerCore
import Darwin

func processArguments(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var count = 0
    guard sysctl(&mib, 3, nil, &count, nil, 0) == 0, count > 4, count <= 1_048_576 else { return [] }
    var bytes = [UInt8](repeating: 0, count: count)
    guard sysctl(&mib, 3, &bytes, &count, nil, 0) == 0 else { return [] }
    let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0, argc < 4096 else { return [] }
    var offset = 4
    while offset < count && bytes[offset] != 0 { offset += 1 }
    while offset < count && bytes[offset] == 0 { offset += 1 }
    var result: [String] = []
    for _ in 0..<argc {
        guard offset < count else { break }
        let start = offset
        while offset < count && bytes[offset] != 0 { offset += 1 }
        result.append(String(decoding: bytes[start..<offset], as: UTF8.self))
        offset += 1
    }
    return result
}

func clientSource(provider: TaskProvider, host: String?, environment: [String: String]) -> TaskClientSource {
    var pid = getppid()
    for _ in 0..<24 {
        var pathBytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count)) > 0 {
            let path = String(decoding: pathBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            let name = URL(fileURLWithPath: path).lastPathComponent
            if name == (provider == .codex ? "codex" : "claude") {
                let args = processArguments(pid)
                let mode = TaskClientSource.launchMode(provider: provider, arguments: args)
                let home = NSHomeDirectory()
                let root = environment[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"]
                    ?? home + (provider == .codex ? "/.codex" : "/.claude")
                return TaskClientSource.identify(provider: provider, enginePath: path, mode: mode,
                    entrypoint: environment["CLAUDE_CODE_ENTRYPOINT"], host: host,
                    configurationRoot: root.hasPrefix("/") ? root : nil, home: home)
            }
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_ppid > 1, info.pbi_ppid != UInt32(pid) else { break }
        pid = pid_t(info.pbi_ppid)
    }
    return TaskClientSource()
}

func sourceApplication() -> String? {
    var pid = getppid()
    for _ in 0..<16 {
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            return bundle
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_ppid > 1, info.pbi_ppid != UInt32(pid) else { return nil }
        pid = pid_t(info.pbi_ppid)
    }
    return nil
}
// A hook is never a reason to launch the App or interrupt the original tool.
func run() {
    var output = Data("{}".utf8)
    defer { FileHandle.standardOutput.write(output) }
    let args = CommandLine.arguments
    guard args.count >= 3, let provider = TaskProvider(rawValue: args[1]) else { return }
    let channel = args[2]
    guard let fd = try? TaskSocket.connect(path: TaskSocket.path(channel: channel)) else { return }
    defer { Darwin.close(fd) }
    var input = Data()
    // Bound stdin as well as the transport; never read a prompt/transcript from disk.
    while true {
        let part = FileHandle.standardInput.readData(ofLength: min(65_536, TaskSocket.maximumFrame + 1 - input.count))
        if part.isEmpty { break }
        input.append(part)
        if input.count > TaskSocket.maximumFrame { return }
    }
    let env = ProcessInfo.processInfo.environment
    let terminal = ["Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
                    "WezTerm": "com.github.wez.wezterm", "ghostty": "com.mitchellh.ghostty"]
    let source = sourceApplication() ?? terminal[env["TERM_PROGRAM"] ?? ""]
    guard var event = try? TaskHookEvent.parse(input, provider: provider, sourceApp: source) else { return }
    event.source = clientSource(provider: provider, host: source, environment: env)
    guard let data = try? JSONEncoder().encode(event) else { return }
    input.removeAll(keepingCapacity: false)
    do {
        try TaskSocket.send(data, fd: fd, deadline: Date().addingTimeInterval(1))
        let response = try TaskSocket.receive(fd, deadline: Date().addingTimeInterval(event.requiresReply ? 120 : 2))
        let reply = try JSONDecoder().decode(TaskHookReply.self, from: response)
        guard reply.id == event.id else { return }
        if event.requiresReply, reply.decision != .pass { output = reply.output() }
    } catch { /* Abstain: let the original permission flow continue. */ }
}
run()
