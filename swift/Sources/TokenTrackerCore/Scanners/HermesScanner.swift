//
//  HermesScanner.swift
//  TokenTrackerCore
//
//  移植自 scanners/hermes.py：$HERMES_HOME/state.db（含 profiles/*/state.db）。
//  session_model_usage 按六元组身份记录累计用量；按来源库持久化快照，
//  保留存量并记录观察区间内的差量。
//

import Foundation

public struct HermesScanner: ScannerAdapter {
    public let name = "hermes"
    public let detail = "~/.hermes/state.db (session_model_usage)"
    public let home: String
    /// 测试缝：覆盖 dbFiles()（对齐 Python patch hermes.db_files）。
    public var dbFilesOverride: [String]?

    public init(home: String) {
        self.home = expandPath(home)
    }

    static let identityKeys = ["session_id", "model", "billing_provider",
                               "billing_base_url", "billing_mode", "task"]

    public func dbFiles() -> [String] {
        if let dbFilesOverride { return dbFilesOverride }
        var out: [String] = []
        let fm = FileManager.default
        let root = (home as NSString).appendingPathComponent("state.db")
        if fm.fileExists(atPath: root) { out.append(root) }
        let profilesDir = (home as NSString).appendingPathComponent("profiles")
        if let entries = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for entry in entries.sorted() {
                let candidate = (profilesDir as NSString)
                    .appendingPathComponent(entry).appending("/state.db")
                if fm.fileExists(atPath: candidate) { out.append(candidate) }
            }
        }
        return out
    }

    public func detect() -> Bool {
        !dbFiles().isEmpty
    }

    private func readRows(_ path: String) throws -> [Row] {
        let src = try sqliteRO(path)
        return try src.query("""
            SELECT u.*, s.display_name FROM session_model_usage u
            LEFT JOIN sessions s ON s.id = u.session_id
            """)
    }

    /// 身份六元组（元素可为 NULL，对齐 Python 的 None）。
    private func identity(_ row: Row) -> [String?] {
        HermesScanner.identityKeys.map { row[$0] as? String }
    }

    private func counts(_ row: Row) -> (Int64, Int64, Int64, Int64) {
        (row.int("input_tokens"), row.int("output_tokens"),
         row.int("cache_read_tokens"), row.int("cache_write_tokens"))
    }

    /// 旧全局键的归属仲裁：先精确匹配，再单候选/单调延续；有歧义的下降
    /// 无法证明是哪个来源重置，保留旧行。
    private func legacyOwners(_ store: UsageStore, sources: [(String, [Row])]) throws -> [String: String?] {
        var groups: [String: [(String, Row)]] = [:]
        for (path, rows) in sources {
            for row in rows {
                let key = identity(row).map { $0 ?? "None" }.joined(separator: "|")
                groups[key, default: []].append((path, row))
            }
        }
        var owners: [String: String?] = [:]
        for (key, candidates) in groups {
            let old = try store.conn.queryOne(
                "SELECT * FROM usage_events WHERE tool=? AND src_key=? AND source_scope=''",
                [name, key])
            guard let old else { continue }
            let oldCounts = (old.int("input"), old.int("output"),
                             old.int("cache_read"), old.int("cache_write"))
            let exact = candidates.filter { _, row in
                counts(row) == oldCounts
                    && (row.stringOrNil("display_name") ?? row.stringOrNil("session_id") ?? "") == old.string("project")
            }
            let monotonic = candidates.filter { _, row in
                let c = counts(row)
                return c.0 >= oldCounts.0 && c.1 >= oldCounts.1
                    && c.2 >= oldCounts.2 && c.3 >= oldCounts.3
            }
            let selected = !exact.isEmpty ? exact
                : (candidates.count == 1 ? candidates : monotonic)
            // 注意：owners[key]=.some(nil) 表示「有歧义，保留旧行」——直接赋 nil
            // 会被 Dictionary 当成删除键，语义相反。
            owners[key] = .some(selected.first?.0)
        }
        return owners
    }

    private func scanOne(_ store: UsageStore, path: String, prices: PriceTable,
                         rows: [Row], owners: [String: String?]) throws -> (Int, Int, Int) {
        var added = 0, resets = 0
        let observedAt = store.nowMs()
        let scope = realPath(path)
        for row in rows {
            let parts = identity(row)
            let key = parts.map { $0 ?? "None" }.joined(separator: "|")
            // 新版 hermes 常把 actual 记为 0 / unknown：视为未知成本，交给价格表估算。
            let actual = row.doubleOrNil("actual_cost_usd") ?? 0
            let estimated = row.doubleOrNil("estimated_cost_usd") ?? 0
            let native: Double?
            let origin: String
            if actual > 0 {
                native = actual; origin = "native"
            } else if estimated > 0 {
                native = estimated; origin = "provider_estimate"
            } else {
                native = nil; origin = "priced"
            }
            let legacyKey: String? = {
                // Python: key if key not in owners or owners[key] == path else None
                // owners[key]=nil 表示归属有歧义，同样不可认领。
                guard let entry = owners[key] else { return key }
                return entry == path ? key : nil
            }()
            let identityJSON = pythonJSONDumps(parts)
            let c = counts(row)
            let result = try store.putSnapshot(
                tool: name, sourceScope: scope, identity: identityJSON,
                sessionID: row.string("session_id"),
                project: row.stringOrNil("display_name") ?? row.stringOrNil("session_id") ?? "",
                model: row.string("model"),
                input: c.0, output: c.1, cacheRead: c.2, cacheWrite: c.3,
                nativeCost: native, costSource: origin, prices: prices,
                legacyKey: legacyKey, observedAt: observedAt)
            try store.setSessionTitle(tool: name, sessionID: row.string("session_id"),
                                      title: row.stringOrNil("display_name") ?? "")
            added += result.added
            resets += result.counterResets
        }
        return (added, rows.count, resets)
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        let files = dbFiles()
        if !store.conn.inTransaction { try store.conn.beginImmediate() }
        let sources = try files.map { ($0, try readRows($0)) }
        let owners = try legacyOwners(store, sources: sources)
        var outcome = ScanOutcome(files: files.count)
        for (path, rows) in sources {
            let (a, u, r) = try scanOne(store, path: path, prices: prices,
                                        rows: rows, owners: owners)
            outcome.added += a
            outcome.updated += u
            outcome.counterResets += r
        }
        let unresolved = try store.conn.scalarInt(
            "SELECT COUNT(*) FROM usage_events WHERE tool=? AND source_scope='' AND time_quality='unallocated'",
            [name])
        try store.setScanCursor(tool: name, cursor: ["mode": "snapshots"])
        if unresolved > 0 {
            outcome.warning = "保留 \(unresolved) 条无法映射 profile 的未分配历史，可能与现存来源重叠"
        }
        return outcome
    }
}
