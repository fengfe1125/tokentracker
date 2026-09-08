//
//  Resume.swift
//  TokenTrackerCore
//
//  移植自 tokentracker/resume.py：按工具生成 resume 命令、解析工作目录、
//  在终端中打开。安全约定：所有进 shell / AppleScript 的片段一律转义——
//  session_id 与 project 虽来自本地库，仍按不可信处理。
//

import Foundation

public struct Resume {
    /// 工具 → resume 命令前缀（id 追加在最后）；DSH 无 CLI，不支持恢复
    public static let resumePrefix: [String: [String]] = [
        "claude": ["claude", "--resume"],
        "codex": ["codex", "resume"],
        "kimi": ["kimi", "--session"],
        "opencode": ["opencode", "--session"],
        "pi": ["pi", "--session"],
        "hermes": ["hermes", "--resume"],
    ]

    public static let terminalApps = ["auto", "terminal", "iterm", "wezterm", "ghostty"]
    static let autoOrder = ["iterm", "wezterm", "ghostty", "terminal"]  // Terminal 保底必在
    static let appNames = ["terminal": "Terminal", "iterm": "iTerm",
                           "wezterm": "WezTerm", "ghostty": "Ghostty"]

    // ------------------------------------------------------------ 注入缝 ----

    /// CLI 解析（默认 CliFind.resolve；测试注入）
    public var cliResolver: (String) -> String?
    /// 进程执行（默认 Process；测试注入记录调用）
    public var runner: ([String], Data?) throws -> Void
    /// 应用安装探测（默认 /Applications + ~/Applications）
    public var appInstalled: (String) -> Bool
    /// Claude 会话 jsonl 根目录（测试注入）
    public var claudeRoot: String?
    public var home: String

    public init(cliResolver: ((String) -> String?)? = nil,
                runner: (([String], Data?) throws -> Void)? = nil,
                appInstalled: ((String) -> Bool)? = nil,
                claudeRoot: String? = nil,
                home: String = NSHomeDirectory()) {
        self.cliResolver = cliResolver ?? CliFind.resolve
        self.runner = runner ?? { args, input in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            if let input {
                let pipe = Pipe()
                process.standardInput = pipe
                try process.run()
                pipe.fileHandleForWriting.write(input)
                try? pipe.fileHandleForWriting.close()
            } else {
                try process.run()
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SQLiteError(message: "\(args.first ?? "") 退出码 \(process.terminationStatus)")
            }
        }
        self.appInstalled = appInstalled ?? { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: "/Applications/\(name).app",
                                                  isDirectory: &isDir)
                || FileManager.default.fileExists(
                    atPath: NSHomeDirectory() + "/Applications/\(name).app", isDirectory: &isDir)
        }
        self.claudeRoot = claudeRoot
        self.home = home
    }

    // ------------------------------------------------------------ 命令 ----

    /// kimi CLI 的会话 ID 带 session_ 前缀（扫描器存的是剥掉前缀的裸 uuid）。
    static func resumeID(tool: String, sessionID: String) -> String {
        if tool == "kimi" && !sessionID.isEmpty && !sessionID.hasPrefix("session_") {
            return "session_" + sessionID
        }
        return sessionID
    }

    /// 工具不支持或无会话 ID → nil。
    public func resumeArgv(_ tool: String, _ sessionID: String) -> [String]? {
        guard let prefix = Self.resumePrefix[tool], !sessionID.isEmpty else { return nil }
        return prefix + [Self.resumeID(tool: tool, sessionID: sessionID)]
    }

    /// CLI 解析不到时返回可执行文件名，否则 nil。
    public func cliMissing(_ argv: [String]) -> String? {
        cliResolver(argv[0]) == nil ? argv[0] : nil
    }

    /// shlex.quote 移植：安全字符原样；其余单引号包裹 + '\'' 转义。
    public static func shlexQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.allSatisfy {
            $0.isLetter || $0.isNumber || "@%_+=:,./-".contains($0)
        }
        if safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // ------------------------------------------------------------ 目录 ----

    /// claude 的 project 是 slug（含连字符的路径不可逆），jsonl 首行的 cwd 才可靠。
    private func claudeCwdFromJSONL(_ sessionID: String) -> String? {
        let root = claudeRoot ?? home + "/.claude/projects"
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root)
        else { return nil }
        for proj in projects {
            let path = "\(root)/\(proj)/\(sessionID).jsonl"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            for (_, obj) in iterJSONL(path) {
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    return cwd
                }
            }
        }
        return nil
    }

    /// claude 的会话记录文件在不在（~/.claude/projects/<slug>/<id>.jsonl）。
    /// `claude --resume` 读的就是它，文件不在必然恢复失败——库里的子代理伪会话
    /// （project=subagents、id 形如 agent-xxx）和已清理的会话都属于这种。
    /// 根目录本身读不到时返回 nil（CLAUDE_CONFIG_DIR 换过位置，不下判断）。
    public func claudeSessionMissing(_ sessionID: String) -> Bool? {
        let root = claudeRoot ?? home + "/.claude/projects"
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root)
        else { return nil }
        return !projects.contains {
            FileManager.default.fileExists(atPath: "\(root)/\($0)/\(sessionID).jsonl")
        }
    }

    /// 恢复会话前 cd 的目录；解析不到或目录已不存在 → nil。
    public func resolveCwd(_ tool: String, _ sessionID: String, _ project: String = "") -> String? {
        var candidates: [String] = []
        if tool == "claude" {
            if let cwd = claudeCwdFromJSONL(sessionID) {
                candidates.append(cwd)
            }
            if project.hasPrefix("-") {   // slug 启发式兜底
                candidates.append("/" + project.dropFirst().replacingOccurrences(of: "-", with: "/"))
            }
        }
        if project.hasPrefix("/") {
            candidates.append(project)
        }
        var isDir: ObjCBool = false
        return candidates.first {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// 返回 (终端里执行的整行, 不可用原因)。每段 shlex.quote；目录存在才加 cd。
    /// CLI 用绝对路径（App 与 Terminal 两侧都不再依赖 PATH）。
    public func shellLine(_ tool: String, _ sessionID: String, _ project: String = "",
                          cwdOverride: String? = nil) -> (String?, String?) {
        guard let argv = resumeArgv(tool, sessionID) else {
            let reason = Self.resumePrefix[tool] != nil ? "缺少会话 ID" : "\(tool) 不支持恢复会话"
            return (nil, reason)
        }
        guard let exe = cliResolver(argv[0]) else {
            return (nil, "未找到命令 \(argv[0])（未安装或不在常见路径）")
        }
        var cmd = ([exe] + argv.dropFirst()).map(Self.shlexQuote).joined(separator: " ")
        var cwd: String?
        var isDir: ObjCBool = false
        if let cwdOverride,
           FileManager.default.fileExists(atPath: cwdOverride, isDirectory: &isDir),
           isDir.boolValue {
            cwd = cwdOverride
        } else if cwdOverride == nil {
            cwd = resolveCwd(tool, sessionID, project)
        }
        if let cwd {
            cmd = "cd \(Self.shlexQuote(cwd)) && \(cmd)"
        }
        return (cmd, nil)
    }

    /// Sendable：UI 把 info() 丢到后台线程算（解析 jsonl + 查 CLI 不能占主线程）
    public struct ResumeInfo: Equatable, Sendable {
        public var ok: Bool
        public var reason: String
        public var command: String
        public var cwd: String
        public var cwdMissing: Bool
    }

    /// 前端按钮可用性 + 展示用命令。
    public func info(_ tool: String, _ sessionID: String, _ project: String = "") -> ResumeInfo {
        guard resumeArgv(tool, sessionID) != nil else {
            let reason = Self.resumePrefix[tool] != nil ? "缺少会话 ID" : "该工具不支持恢复会话"
            return ResumeInfo(ok: false, reason: reason, command: "", cwd: "", cwdMissing: false)
        }
        let (cmd, reason) = shellLine(tool, sessionID, project)
        guard let cmd else {
            return ResumeInfo(ok: false, reason: reason ?? "", command: "", cwd: "",
                              cwdMissing: false)
        }
        // CLI 存在但会话记录已经没了 → 与其给一个必定失败的按钮，不如直说
        if tool == "claude", claudeSessionMissing(sessionID) == true {
            return ResumeInfo(ok: false,
                              reason: "找不到这个会话的记录文件，claude --resume 无法恢复"
                                  + "（子代理会话、以及已被清理的会话都会这样）",
                              command: "", cwd: "", cwdMissing: false)
        }
        let cwd = resolveCwd(tool, sessionID, project)
        return ResumeInfo(ok: true, reason: "", command: cmd,
                          cwd: cwd ?? "", cwdMissing: cwd == nil)
    }

    // ------------------------------------------------------------ 终端 ----

    /// 显式偏好但应用已卸载时回退 Terminal。
    public func pickTerminal(_ pref: String = "auto") -> String {
        if !pref.isEmpty && pref != "auto" {
            return appInstalled(Self.appNames[pref] ?? "") ? pref : "terminal"
        }
        for key in Self.autoOrder {
            if appInstalled(Self.appNames[key] ?? "") { return key }
        }
        return "terminal"
    }

    static func applescriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 按偏好在终端新窗口执行 cmd（cmd 必须是已 quote 的整行）。失败返回 false。
    @discardableResult
    public func openTerminal(_ cmd: String, pref: String = "auto") -> Bool {
        let key = pickTerminal(pref)
        do {
            if key == "terminal" || key == "iterm" {
                let app = Self.appNames[key]!
                let body: String
                if key == "terminal" {
                    body = "activate\n  do script \"\(Self.applescriptEscape(cmd))\""
                } else {
                    body = "create window with default profile command "
                        + "\"\(Self.applescriptEscape(cmd))\""
                }
                try runner(["osascript", "-e",
                            "tell application \"\(app)\"\n  \(body)\nend tell"], nil)
            } else if key == "wezterm" {
                try runner(["open", "-na", "WezTerm", "--args", "start",
                            "--always-new-process", "--", "/bin/bash", "-lc", cmd], nil)
            } else {  // ghostty
                try runner(["open", "-na", "Ghostty", "--args",
                            "-e", "/bin/bash", "-lc", cmd], nil)
            }
            return true
        } catch {
            return false
        }
    }

    /// 终端打开失败的降级：复制命令到剪贴板。
    @discardableResult
    public func copyToClipboard(_ text: String) -> Bool {
        do {
            try runner(["pbcopy"], Data(text.utf8))
            return true
        } catch {
            return false
        }
    }
}
