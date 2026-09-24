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
    private func modelInfo(_ raw: Any?) -> (model: String, provider: String) {
        guard let raw else { return ("", "") }
        if let s = raw as? String {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return (s, "") }
            return modelInfo(obj)
        }
        if let dict = raw as? [String: Any] {
            return ((dict["id"] as? String) ?? (dict["modelID"] as? String)
                ?? (dict["model"] as? String) ?? "",
                (dict["providerID"] as? String) ?? (dict["provider"] as? String) ?? "")
        }
        return (String(describing: raw), "")
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        let src = try sqliteRO(dbPath)
        let rows = try src.query("SELECT * FROM session")
        let observedAt = store.nowMs()
        var outcome = ScanOutcome(files: 1)
        let scope = realPath(dbPath)
        for row in rows {
            let id = row.string("id")
            let model = modelInfo(row["model"])
            let result = try store.putSnapshot(
                tool: name, sourceScope: scope, identity: id,
                sessionID: id, project: {
                    let dir = row.string("directory")
                    let title = row.string("title")
                    return !dir.isEmpty ? dir : title
                }(),
                model: model.model,
                input: row.int("tokens_input"), output: row.int("tokens_output"),
                cacheRead: row.int("tokens_cache_read"), cacheWrite: row.int("tokens_cache_write"),
                nativeCost: row.doubleOrNil("cost"), prices: prices,
                legacyKey: id, observedAt: observedAt, provider: model.provider)
            let directory=row.string("directory")
            if directory.hasPrefix("/") {
                for event in try store.conn.query("SELECT src_key FROM usage_events WHERE tool=? AND session_id=?",[name,id]) {
                    try store.recordProjectPath(tool:name,srcKey:event.string("src_key"),path:directory)
                }
            }
            try store.setSessionTitle(tool: name, sessionID: id, title: row.string("title"))
            outcome.added += result.added
            outcome.counterResets += result.counterResets
            outcome.updated += 1
        }
        let tables = Set(try src.query("SELECT name FROM sqlite_master WHERE type='table'")
            .map { $0.string("name") })
        if tables.contains("part") {
            for row in try src.query("SELECT id,session_id,time_created,time_updated,data FROM part") {
                guard let dataText = row.stringOrNil("data"),
                      let data = dataText.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      obj["type"] as? String == "tool",
                      let rawName = obj["tool"] as? String else { continue }
                let state = obj["state"] as? [String: Any] ?? [:]
                let timing = state["time"] as? [String: Any] ?? [:]
                let status = ActivityNormalizer.status(state["status"])
                let start = jsonOrInt(timing["start"], row["time_created"])
                let end = jsonOrInt(timing["end"], status == "unknown" ? nil : row["time_updated"])
                let change = try store.recordActivity(
                    agent: name, srcKey: "\(scope)|part|\(row.string("id"))",
                    rawName: rawName, sessionID: row.string("session_id"),
                    callID: jsonOrString(obj["callID"], obj["callId"]),
                    startedAt: start == 0 ? nil : start, endedAt: end == 0 ? nil : end,
                    status: status, sourceKind: "opencode_part", arguments: state["input"])
                outcome.activityAdded += change.added
                outcome.activityUpdated += change.updated
            }
        }
        var cursor: [String: Any] = ["mode": "snapshots", "observed_at": observedAt]
        markActivityCurrent(&cursor)
        try store.setScanCursor(tool: name, cursor: cursor)
        return outcome
    }
}
