//
//  OpencodeScanner.swift
//  TokenTrackerCore
//
//  移植自 scanners/opencode.py：session 累计字段按持久化快照计算差量；
//  首次存量保留为时间未分配历史。updated_at 不是安全游标（并列与重置
//  会藏住变化），全量读取所有累计行。
//

import Foundation

public struct OpencodeScanner: ScannerAdapter {
    public let name = "opencode"
    public let detail = "~/.local/share/opencode/opencode.db"
    public let dbPath: String

    public init(dbPath: String) {
        self.dbPath = expandPath(dbPath)
    }

    public func detect() -> Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// model 字段可能是 JSON 字符串 / 对象 / 裸字符串。
    private func modelID(_ raw: Any?) -> String {
        guard let raw else { return "" }
        if let s = raw as? String {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return s }
            return modelID(obj)
        }
        if let dict = raw as? [String: Any] {
            return (dict["id"] as? String) ?? (dict["model"] as? String)
                ?? (dict["providerID"] as? String) ?? ""
        }
        return String(describing: raw)
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        let src = try sqliteRO(dbPath)
        let rows = try src.query("SELECT * FROM session")
        let observedAt = store.nowMs()
        var outcome = ScanOutcome(files: 1)
        let scope = realPath(dbPath)
        for row in rows {
            let id = row.string("id")
            let result = try store.putSnapshot(
                tool: name, sourceScope: scope, identity: id,
                sessionID: id, project: {
                    let dir = row.string("directory")
                    let title = row.string("title")
                    return !dir.isEmpty ? dir : title
                }(),
                model: modelID(row["model"]),
                input: row.int("tokens_input"), output: row.int("tokens_output"),
                cacheRead: row.int("tokens_cache_read"), cacheWrite: row.int("tokens_cache_write"),
                nativeCost: row.doubleOrNil("cost"), prices: prices,
                legacyKey: id, observedAt: observedAt)
            try store.setSessionTitle(tool: name, sessionID: id, title: row.string("title"))
            outcome.added += result.added
            outcome.counterResets += result.counterResets
            outcome.updated += 1
        }
        try store.setScanCursor(tool: name, cursor: ["mode": "snapshots", "observed_at": observedAt])
        return outcome
    }
}
