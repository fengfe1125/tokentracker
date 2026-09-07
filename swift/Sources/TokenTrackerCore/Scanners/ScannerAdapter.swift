//
//  ScannerAdapter.swift
//  TokenTrackerCore
//
//  扫描器协议与注册表（对齐 tokentracker/scanners/__init__.py）。
//

import Foundation

public struct ScanOutcome: Equatable, Sendable {
    public var added: Int = 0
    public var updated: Int = 0
    public var files: Int = 0
    public var counterResets: Int = 0
    public var warning: String?
    public var skipped: String?
    public var error: String?
}

public protocol ScannerAdapter {
    var name: String { get }
    var detail: String { get }
    func detect() -> Bool
    /// 抛错由 ScanRunner 捕获并回滚该工具的事务。
    func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome
}

/// 各工具数据源根目录（默认取环境变量 / 本机路径；差分测试注入语料目录）。
public struct ScanRoots: Sendable {
    public var claude: String
    public var codexLogsDB: String
    public var codexSessions: String
    public var opencodeDB: String
    public var dshSessions: String
    public var hermesHome: String
    public var kimiCodeHome: String
    public var kimiCLI: String
    public var piRoots: [String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = NSHomeDirectory()
        claude = environment["CLAUDE_PROJECTS_DIR"] ?? "\(home)/.claude/projects"
        codexLogsDB = environment["CODEX_LOGS_DB"] ?? "\(home)/.codex/logs_2.sqlite"
        codexSessions = environment["CODEX_SESSIONS_DIR"] ?? "\(home)/.codex/sessions"
        opencodeDB = environment["OPENCODE_DB"] ?? "\(home)/.local/share/opencode/opencode.db"
        dshSessions = environment["DSH_SESSIONS_DIR"] ?? "\(home)/.dsh/sessions"
        hermesHome = environment["HERMES_HOME"] ?? "\(home)/.hermes"
        kimiCodeHome = environment["KIMI_CODE_HOME"] ?? "\(home)/.kimi-code/server/events"
        kimiCLI = "\(home)/.kimi/sessions"
        piRoots = [environment["PI_HOME"] ?? "\(home)/.pi/agent/sessions", "\(home)/.omp"]
    }
}

public struct DetectInfo: Equatable, Sendable {
    public var installed: Bool
    public var detail: String
    public init(installed: Bool, detail: String) {
        self.installed = installed
        self.detail = detail
    }
}

public enum ScannerRegistry {
    public static let all = ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"]

    public static func make(_ name: String, roots: ScanRoots) -> ScannerAdapter? {
        switch name {
        case "claude": return ClaudeScanner(root: roots.claude)
        case "codex": return CodexScanner(logsDB: roots.codexLogsDB, sessionsDir: roots.codexSessions)
        case "opencode": return OpencodeScanner(dbPath: roots.opencodeDB)
        case "dsh": return DshScanner(root: roots.dshSessions)
        case "hermes": return HermesScanner(home: roots.hermesHome)
        case "kimi": return KimiScanner(journalDir: roots.kimiCodeHome, cliDir: roots.kimiCLI)
        case "pi": return PiScanner(roots: roots.piRoots)
        default: return nil
        }
    }
}

/// run_all：单工具出错不影响其他工具；事务语义对齐 Python
/// （BEGIN IMMEDIATE → scan → error? rollback : commit）。
public struct ScanRunner {
    public let store: UsageStore
    public let prices: PriceTable
    public let roots: ScanRoots

    public init(store: UsageStore, prices: PriceTable, roots: ScanRoots) {
        self.store = store
        self.prices = prices
        self.roots = roots
    }

    public func detectAll() -> [String: DetectInfo] {
        var out: [String: DetectInfo] = [:]
        for name in ScannerRegistry.all {
            if let adapter = ScannerRegistry.make(name, roots: roots) {
                out[name] = DetectInfo(installed: adapter.detect(), detail: adapter.detail)
            } else {
                out[name] = DetectInfo(installed: false, detail: "未知工具")
            }
        }
        return out
    }

    @discardableResult
    public func runAll(tools: [String]? = nil, full: Bool = false) -> [String: ScanOutcome] {
        var results: [String: ScanOutcome] = [:]
        for name in tools ?? ScannerRegistry.all {
            guard let adapter = ScannerRegistry.make(name, roots: roots) else { continue }
            if !adapter.detect() {
                results[name] = ScanOutcome(skipped: "未检测到数据源")
                continue
            }
            do {
                if !store.conn.inTransaction { try store.conn.beginImmediate() }
                let outcome = try adapter.scan(store, prices, full: full)
                if outcome.error != nil {
                    try store.conn.rollback()
                } else {
                    try store.conn.commit()
                }
                results[name] = outcome
            } catch {
                try? store.conn.rollback()
                results[name] = ScanOutcome(error: String(describing: error))
            }
        }
        try? store.conn.commit()
        return results
    }
}
