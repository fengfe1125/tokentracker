//
//  SessionSourceResolver.swift
//  TokenTrackerCore
//
//  会话来源文件与工作目录解析：复用已有数据库记录（project_sources、
//  usage_events.src_key / source_scope、scan_state 游标）与本地数据源根目录，
//  在不修改数据库 schema 或重写历史事件的前提下，为每个 Agent 会话解析出
//  真实的源文件路径与工作文件夹。
//

import Foundation

/// 把用户主目录前缀缩写为 `~`（例如 `/Users/alice/.claude/...` → `~/.claude/...`）。
public func abbreviateHomePath(_ path: String, home: String = NSHomeDirectory()) -> String {
    guard !path.isEmpty, !home.isEmpty else { return path }
    let normalizedHome = home.count > 1 && home.hasSuffix("/")
        ? String(home.dropLast()) : home
    if path == normalizedHome { return "~" }
    if path.hasPrefix(normalizedHome + "/") {
        return "~" + path.dropFirst(normalizedHome.count)
    }
    return path
}

public enum SessionSourceResolver {
    public struct SessionHints: Sendable {
        public var tool: String
        public var sessionID: String
        public var project: String
        public var workspacePath: String
        public var sourceScopePath: String
        public var pathSrcKey: String
        public var fileSrcKey: String
        public var hasCodexSQLite: Bool
        public var activitySrcKeyPath: String

        public init(tool: String, sessionID: String, project: String = "",
                    workspacePath: String = "", sourceScopePath: String = "",
                    pathSrcKey: String = "", fileSrcKey: String = "",
                    hasCodexSQLite: Bool = false, activitySrcKeyPath: String = "") {
            self.tool = tool
            self.sessionID = sessionID
            self.project = project
            self.workspacePath = workspacePath
            self.sourceScopePath = sourceScopePath
            self.pathSrcKey = pathSrcKey
            self.fileSrcKey = fileSrcKey
            self.hasCodexSQLite = hasCodexSQLite
            self.activitySrcKeyPath = activitySrcKeyPath
        }
    }

    public struct CursorIndex {
        public var claudeByFilename: [String: [String]] = [:]
        public var codexPaths: [String] = []
        public var codexLogsDBPath: String?
        public var kimiByFilename: [String: [String]] = [:]
        public var piByFilename: [String: [String]] = [:]
        public var dshByParentDir: [String: [String]] = [:]
        public var dshPaths: [String] = []
        public var antigravityBySessionID: [String: [String]] = [:]
        public var antigravityWorkspaces: [String: String] = [:]

        public init() {}

        public static func load(from store: UsageStore, tools: Set<String>,
                                roots: ScanRoots? = nil) -> CursorIndex {
            var index = CursorIndex()
            let fileTools = tools.intersection(["claude", "codex", "kimi", "pi", "dsh", "antigravity"])
            for tool in fileTools {
                guard let cursor = try? store.getScanCursor(tool: tool) else { continue }
                let paths = cursor.keys.filter { $0.hasPrefix("/") }.sorted()
                switch tool {
                case "claude":
                    for path in paths {
                        let name = (path as NSString).lastPathComponent
                        index.claudeByFilename[name, default: []].append(path)
                    }
                case "codex":
                    index.codexPaths = paths
                    if let identity = cursor["logs2_identity"] as? [Any], identity.count >= 3,
                       let dbPath = identity[2] as? String, dbPath.hasPrefix("/") {
                        index.codexLogsDBPath = dbPath
                    }
                case "kimi":
                    for path in paths {
                        let name = (path as NSString).lastPathComponent
                        index.kimiByFilename[name, default: []].append(path)
                    }
                case "pi":
                    for path in paths {
                        let name = (path as NSString).lastPathComponent
                        index.piByFilename[name, default: []].append(path)
                    }
                case "dsh":
                    index.dshPaths = paths
                    for path in paths {
                        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                        if !parent.isEmpty {
                            index.dshByParentDir[parent, default: []].append(path)
                        }
                    }
                case "antigravity":
                    for path in paths {
                        if let sid = antigravitySessionID(fromTranscriptPath: path) {
                            index.antigravityBySessionID[sid, default: []].append(path)
                        }
                    }
                default:
                    break
                }
            }
            if tools.contains("antigravity"), let mapPath = roots?.antigravityWorkspaceMap {
                index.antigravityWorkspaces = AntigravityWorkspaceMap.load(path: mapPath)
            }
            return index
        }

        private static func antigravitySessionID(fromTranscriptPath path: String) -> String? {
            let suffix = "/.system_generated/logs/transcript.jsonl"
            guard path.hasSuffix(suffix) else { return nil }
            let prefix = String(path.dropLast(suffix.count))
            let sid = (prefix as NSString).lastPathComponent
            return sid.isEmpty ? nil : sid
        }
    }

    // ------------------------------------------------------------ 解析入口 ----

    /// 从 `legacy|/abs/path.jsonl|12` 或 `cli|/abs/path.jsonl|4` 中提取绝对路径。
    public static func extractPrefixedSrcKeyPath(_ srcKey: String, prefix: String) -> String? {
        guard srcKey.hasPrefix(prefix) else { return nil }
        let rest = srcKey.dropFirst(prefix.count)
        guard let lastPipe = rest.lastIndex(of: "|") else { return nil }
        let candidate = String(rest[..<lastPipe])
        return candidate.hasPrefix("/") ? candidate : nil
    }

    /// 流式读取 JSONL 头部若干行，提取首个绝对路径形式的 cwd（避免整文件读入内存）。
    public static func firstCwdFromJSONL(path: String, maxLines: Int = 64,
                                         maxBytes: Int64 = 256 * 1024) -> String? {
        guard let reader = ByteLineReader(path: path, offset: 0) else { return nil }
        var seen = 0
        while seen < maxLines, let (offset, data, _) = reader.readLine() {
            if offset >= maxBytes { break }
            seen += 1
            let payload = data.last == 0x0A ? Data(data.dropLast()) : data
            guard !payload.isEmpty,
                  let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            else { continue }
            if let cwd = obj["cwd"] as? String, cwd.hasPrefix("/") {
                return cwd
            }
            if obj["type"] as? String == "session_meta",
               let meta = obj["payload"] as? [String: Any],
               let cwd = meta["cwd"] as? String, cwd.hasPrefix("/") {
                return cwd
            }
            if obj["kind"] as? String == "event",
               let envelope = obj["envelope"] as? [String: Any],
               envelope["type"] as? String == "event.session.created",
               let inner = envelope["payload"] as? [String: Any],
               let session = inner["session"] as? [String: Any],
               let meta = session["metadata"] as? [String: Any],
               let cwd = meta["cwd"] as? String, cwd.hasPrefix("/") {
                return cwd
            }
        }
        return nil
    }

    /// 解析会话原始记录文件的绝对路径；找不到时返回空串（不伪造不存在的路径）。
    public static func resolveFilePath(hints: SessionHints, cursor: CursorIndex,
                                       roots: ScanRoots?, allowDiskWalk: Bool) -> String {
        let sid = hints.sessionID
        switch hints.tool {
        case "claude":
            return resolveClaudeFile(sid: sid, project: hints.project, cursor: cursor,
                                     roots: roots, allowDiskWalk: allowDiskWalk)
        case "codex":
            return resolveCodexFile(hints: hints, cursor: cursor, roots: roots,
                                    allowDiskWalk: allowDiskWalk)
        case "kimi":
            return resolveKimiFile(hints: hints, cursor: cursor, roots: roots,
                                   allowDiskWalk: allowDiskWalk)
        case "opencode":
            if hints.sourceScopePath.hasPrefix("/") { return hints.sourceScopePath }
            if let db = roots?.opencodeDB, fileExists(db) { return db }
            return ""
        case "hermes":
            if hints.sourceScopePath.hasPrefix("/") { return hints.sourceScopePath }
            if let home = roots?.hermesHome {
                let candidate = (home as NSString).appendingPathComponent("state.db")
                if fileExists(candidate) { return candidate }
            }
            return ""
        case "pi":
            return resolvePiFile(hints: hints, cursor: cursor, roots: roots,
                                 allowDiskWalk: allowDiskWalk)
        case "dsh":
            return resolveDshFile(hints: hints, cursor: cursor, roots: roots,
                                  allowDiskWalk: allowDiskWalk)
        case "antigravity":
            return resolveAntigravityFile(sid: sid, cursor: cursor, roots: roots)
        default:
            if hints.sourceScopePath.hasPrefix("/") { return hints.sourceScopePath }
            return ""
        }
    }

    /// 解析会话所属的真实工作文件夹；无可靠目录时返回空串。
    public static func resolveWorkspacePath(hints: SessionHints, filePath: String,
                                            cursor: CursorIndex, roots: ScanRoots?) -> String {
        if hints.workspacePath.hasPrefix("/") { return hints.workspacePath }
        if hints.project.hasPrefix("/") { return hints.project }
        if hints.tool == "antigravity",
           let mapped = cursor.antigravityWorkspaces[hints.sessionID],
           mapped.hasPrefix("/") {
            return mapped
        }
        if !filePath.isEmpty, filePath.hasSuffix(".jsonl"), fileExists(filePath),
           ["claude", "codex", "pi", "kimi"].contains(hints.tool),
           let cwd = firstCwdFromJSONL(path: filePath) {
            return cwd
        }
        if hints.tool == "claude", hints.project.hasPrefix("-") {
            let candidate = "/" + hints.project.dropFirst().replacingOccurrences(of: "-", with: "/")
            if isExistingDirectory(candidate) { return candidate }
        }
        return ""
    }

    // ------------------------------------------------------------ 各工具解析 ----

    private static func resolveClaudeFile(sid: String, project: String, cursor: CursorIndex,
                                          roots: ScanRoots?, allowDiskWalk: Bool) -> String {
        guard !sid.isEmpty else { return "" }
        let fileName = "\(sid).jsonl"
        if let root = roots?.claude, !project.isEmpty, !project.hasPrefix("/") {
            let direct = ((root as NSString).appendingPathComponent(project) as NSString)
                .appendingPathComponent(fileName)
            if fileExists(direct) { return direct }
        }
        if let matches = cursor.claudeByFilename[fileName],
           let best = pickBestPath(matches, preferredParent: project.isEmpty ? nil : project) {
            return best
        }
        if allowDiskWalk, let root = roots?.claude {
            let fm = FileManager.default
            if let dirs = try? fm.contentsOfDirectory(atPath: root) {
                for dir in dirs.sorted() {
                    let candidate = ((root as NSString).appendingPathComponent(dir) as NSString)
                        .appendingPathComponent(fileName)
                    if fileExists(candidate) { return candidate }
                }
            }
            if let enumerator = fm.enumerator(atPath: root) {
                for case let rel as String in enumerator {
                    if (rel as NSString).lastPathComponent == fileName {
                        return (root as NSString).appendingPathComponent(rel)
                    }
                }
            }
        }
        return ""
    }

    private static func resolveCodexFile(hints: SessionHints, cursor: CursorIndex,
                                         roots: ScanRoots?, allowDiskWalk: Bool) -> String {
        if let fromKey = extractPrefixedSrcKeyPath(hints.pathSrcKey, prefix: "legacy|") {
            return fromKey
        }
        let sid = hints.sessionID
        if !sid.isEmpty {
            let matches = cursor.codexPaths.filter {
                let name = ($0 as NSString).lastPathComponent
                return name == "\(sid).jsonl" || name.contains(sid)
            }
            if let best = pickBestPath(matches) { return best }
        }
        if allowDiskWalk, let dir = roots?.codexSessions, !sid.isEmpty,
           let enumerator = FileManager.default.enumerator(atPath: dir) {
            for case let rel as String in enumerator where rel.hasSuffix(".jsonl") {
                let name = (rel as NSString).lastPathComponent
                if name == "\(sid).jsonl" || name.contains(sid) {
                    return (dir as NSString).appendingPathComponent(rel)
                }
            }
        }
        if hints.hasCodexSQLite {
            if let db = roots?.codexLogsDB, fileExists(db) { return db }
            if let db = cursor.codexLogsDBPath { return db }
            if let db = roots?.codexLogsDB { return db }
        }
        return ""
    }

    private static func resolveKimiFile(hints: SessionHints, cursor: CursorIndex,
                                        roots: ScanRoots?, allowDiskWalk: Bool) -> String {
        if let fromKey = extractPrefixedSrcKeyPath(hints.pathSrcKey, prefix: "cli|") {
            return fromKey
        }
        let sid = hints.sessionID
        guard !sid.isEmpty else { return "" }
        let journalName = "session_\(sid).jsonl"
        let cliName = "\(sid).jsonl"
        if let journalDir = roots?.kimiCodeHome {
            let direct = (journalDir as NSString).appendingPathComponent(journalName)
            if fileExists(direct) { return direct }
        }
        let cursorMatches = (cursor.kimiByFilename[journalName] ?? [])
            + (cursor.kimiByFilename[cliName] ?? [])
        if let best = pickBestPath(cursorMatches, preferredFilename: journalName) {
            return best
        }
        if allowDiskWalk, let cliDir = roots?.kimiCLI,
           let enumerator = FileManager.default.enumerator(atPath: cliDir) {
            for case let rel as String in enumerator where (rel as NSString).lastPathComponent == cliName {
                return (cliDir as NSString).appendingPathComponent(rel)
            }
        }
        return ""
    }

    private static func resolvePiFile(hints: SessionHints, cursor: CursorIndex,
                                      roots: ScanRoots?, allowDiskWalk: Bool) -> String {
        let basename: String? = {
            guard !hints.fileSrcKey.isEmpty,
                  let pipe = hints.fileSrcKey.firstIndex(of: "|") else { return nil }
            let name = String(hints.fileSrcKey[..<pipe])
            return name.hasSuffix(".jsonl") ? name : nil
        }()
        if let basename, let matches = cursor.piByFilename[basename],
           let best = pickBestPath(matches) {
            return best
        }
        let sid = hints.sessionID
        if !sid.isEmpty {
            let exactName = "\(sid).jsonl"
            if let matches = cursor.piByFilename[exactName], let best = pickBestPath(matches) {
                return best
            }
            let partial = cursor.piByFilename.values.flatMap { $0 }.filter {
                ($0 as NSString).lastPathComponent.contains(sid)
            }
            if let best = pickBestPath(partial) { return best }
        }
        if hints.activitySrcKeyPath.hasPrefix("/") {
            return hints.activitySrcKeyPath
        }
        if allowDiskWalk, let piRoots = roots?.piRoots {
            let targets = Set([basename, sid.isEmpty ? nil : "\(sid).jsonl"].compactMap { $0 })
            for base in piRoots {
                guard let enumerator = FileManager.default.enumerator(atPath: base) else { continue }
                for case let rel as String in enumerator where rel.hasSuffix(".jsonl") {
                    let name = (rel as NSString).lastPathComponent
                    if targets.contains(name) || (!sid.isEmpty && name.contains(sid)) {
                        return (base as NSString).appendingPathComponent(rel)
                    }
                }
            }
        }
        return ""
    }

    private static func resolveDshFile(hints: SessionHints, cursor: CursorIndex,
                                       roots: ScanRoots?, allowDiskWalk: Bool) -> String {
        let sid = hints.sessionID
        guard !sid.isEmpty else { return "" }
        if sid.hasSuffix(".jsonl.zstd") {
            if let root = roots?.dshSessions {
                let direct = (root as NSString).appendingPathComponent(sid)
                if fileExists(direct) { return direct }
            }
            let matches = cursor.dshPaths.filter { $0.hasSuffix("/" + sid) }
            if let best = pickBestPath(matches) { return best }
        }
        if let matches = cursor.dshByParentDir[sid],
           let best = pickBestPath(matches, preferredFilename: "session.jsonl.zstd") {
            return best
        }
        if let root = roots?.dshSessions, !hints.project.isEmpty, !hints.project.hasPrefix("/") {
            let direct = (((root as NSString).appendingPathComponent(hints.project) as NSString)
                .appendingPathComponent(sid) as NSString)
                .appendingPathComponent("session.jsonl.zstd")
            if fileExists(direct) { return direct }
        }
        if allowDiskWalk, let root = roots?.dshSessions,
           let workspaces = try? FileManager.default.contentsOfDirectory(atPath: root) {
            for ws in workspaces.sorted() {
                let sessionDir = ((root as NSString).appendingPathComponent(ws) as NSString)
                    .appendingPathComponent(sid)
                let primary = (sessionDir as NSString).appendingPathComponent("session.jsonl.zstd")
                if fileExists(primary) { return primary }
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: sessionDir),
                   let first = entries.sorted().first(where: { $0.hasSuffix(".jsonl.zstd") }) {
                    return (sessionDir as NSString).appendingPathComponent(first)
                }
            }
        }
        return ""
    }

    private static func resolveAntigravityFile(sid: String, cursor: CursorIndex,
                                               roots: ScanRoots?) -> String {
        guard !sid.isEmpty else { return "" }
        if let agRoots = roots?.antigravityRoots {
            for root in agRoots {
                let candidate = ((root as NSString).appendingPathComponent(sid) as NSString)
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl")
                if fileExists(candidate) { return candidate }
            }
        }
        if let matches = cursor.antigravityBySessionID[sid], let best = pickBestPath(matches) {
            return best
        }
        return ""
    }

    // ------------------------------------------------------------ 工具方法 ----

    public static func fileExists(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    public static func isExistingDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func pickBestPath(_ candidates: [String], preferredParent: String? = nil,
                                     preferredFilename: String? = nil) -> String? {
        let unique = Array(Set(candidates))
        guard !unique.isEmpty else { return nil }
        return unique.sorted { a, b in
            let aExists = fileExists(a), bExists = fileExists(b)
            if aExists != bExists { return aExists }
            if let preferredFilename {
                let aMatch = (a as NSString).lastPathComponent == preferredFilename
                let bMatch = (b as NSString).lastPathComponent == preferredFilename
                if aMatch != bMatch { return aMatch }
            }
            if let preferredParent {
                let aParent = ((a as NSString).deletingLastPathComponent as NSString).lastPathComponent == preferredParent
                let bParent = ((b as NSString).deletingLastPathComponent as NSString).lastPathComponent == preferredParent
                if aParent != bParent { return aParent }
            }
            return a < b
        }.first
    }
}
