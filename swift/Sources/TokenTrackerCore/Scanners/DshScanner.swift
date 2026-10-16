//
//  DshScanner.swift
//  TokenTrackerCore
//
//  移植自 scanners/dsh.py：~/.dsh/sessions/**/session.jsonl.zstd。
//  幂等键：会话内 (turn, step)。同名文件分布在不同目录，必须保留完整
//  相对路径作为兜底身份。
//

import Foundation

public struct DshScanner: ScannerAdapter {
    public let name = "dsh"
    public let detail = "~/.dsh/sessions/**/session.jsonl.zstd"
    public let root: String
    /// 测试可注入解压器（对齐 Python patch iter_zstd_jsonl）。
    public var reader: (String) -> [(Int, [String: Any])] = iterZstdJSONL

    public init(root: String) {
        self.root = expandPath(root)
    }

    public func detect() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
    }

    /// 仅当旧文件名兜底键的载荷已被完全入账时才删除旧行。
    private func replaceOldFallback(_ store: UsageStore, oldKey: String, sid: String,
                                    project: String, ts: Int64, model: String,
                                    counts: (Int64, Int64, Int64, Int64)) throws -> Int {
        guard let old = try store.conn.queryOne(
            "SELECT * FROM usage_events WHERE tool=? AND src_key=?", [name, oldKey]),
            old.string("project") == project, old.int("ts") == ts,
            old.string("model") == model,
            old.int("input") == counts.0, old.int("output") == counts.1,
            old.int("cache_read") == counts.2, old.int("cache_write") == counts.3
        else { return 0 }
        _ = try store.conn.execute("DELETE FROM usage_events WHERE tool=? AND src_key=?",
                                   [name, oldKey])
        return 1
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        var cursor = try store.getScanCursor(tool: name)
        let effectiveFull = full || activityNeedsBackfill(cursor)
        var outcome = ScanOutcome()
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let entry as String in enumerator where entry.hasSuffix(".jsonl.zstd") {
                files.append(entry)
            }
        }
        files.sort()
        for rel in files {
            let path = (root as NSString).appendingPathComponent(rel)
            if !effectiveFull && !fingerprintChanged(cursor: cursor, path: path) { continue }
            guard let statKey = StatKey(path: path) else { continue }
            outcome.files += 1
            // 一级子目录是 workspace slug，二级是 session id
            let parts = (rel as NSString).deletingLastPathComponent
                .split(separator: "/").map(String.init)
            let fallbackID = rel  // 同名 session.jsonl.zstd 分布在不同目录，保留完整相对路径
            let oldFallback = ((rel as NSString).lastPathComponent as NSString)
                .replacingOccurrences(of: ".jsonl.zstd", with: "")
            var sessionID = ""
            var project = parts.count >= 1 ? parts[0] : ""
            var model = ""
            for (lineno, obj) in reader(path) {
                let type = obj["type"] as? String ?? ""
                if type == "session" {
                    let id = obj["id"] as? String ?? ""
                    sessionID = !id.isEmpty ? id : (parts.count >= 2 ? parts[1] : "")
                    let cwd = obj["cwd"] as? String ?? ""
                    project = !cwd.isEmpty ? cwd : project
                } else if type == "request/header" {
                    let data = obj["data"] as? [String: Any] ?? [:]
                    let header = data["header"] as? [String: Any] ?? [:]
                    let config = header["config"] as? [String: Any] ?? [:]
                    if let m = config["model"] as? String, !m.isEmpty { model = m }
                } else if type == "tool/call" {
                    let data = obj["data"] as? [String: Any] ?? [:]
                    let rawName = jsonOrString(data["name"], data["tool"])
                    let callID = jsonOrString(data["callId"], data["id"])
                    let sid = sessionID.isEmpty ? fallbackID : sessionID
                    if !rawName.isEmpty {
                        let change = try store.recordActivity(
                            agent: name, srcKey: "\(sid)|tool|\(callID.isEmpty ? String(lineno) : callID)",
                            rawName: rawName, sessionID: sid,
                            turnID: {
                                guard let value = data["turn"] else { return "" }
                                if let number = value as? NSNumber, number.int64Value == 0 { return "" }
                                return String(describing: value)
                            }(),
                            callID: callID,
                            startedAt: {
                                let value = jsonOrInt(obj["time"], data["time"])
                                return value == 0 ? nil : value
                            }(),
                            sourceKind: "dsh_zstd",
                            arguments: jsonOrAny(data["arguments"], data["args"], data["input"]))
                        outcome.activityAdded += change.added
                        outcome.activityUpdated += change.updated
                    }
                } else if type == "tool/result" {
                    let data = obj["data"] as? [String: Any] ?? [:]
                    let callID = jsonOrString(data["callId"], data["id"])
                    var status = ActivityNormalizer.status(jsonOrAny(data["status"], data["error"]))
                    if status == "unknown" { status = data["error"] == nil ? "success" : "error" }
                    let ended = jsonOrInt(obj["time"], data["time"])
                    outcome.activityUpdated += try store.completeActivity(
                        agent: name, callID: callID, status: status,
                        endedAt: ended == 0 ? nil : ended,
                        durationMs: (data["durationMs"] as? NSNumber)?.int64Value)
                } else if type == "assistant/chunk" {
                    let data = obj["data"] as? [String: Any] ?? [:]
                    let chunk = data["chunk"] as? [String: Any] ?? [:]
                    guard chunk["type"] as? String == "usage",
                          let usage = chunk["usage"] as? [String: Any] else { continue }
                    let inp = jsonInt(usage["inputTokens"])
                    let outp = jsonInt(usage["outputTokens"])
                    let cr = jsonOrInt(usage["cacheReadTokens"], usage["cacheRead"])
                    let cw = jsonOrInt(usage["cacheWriteTokens"], usage["cacheWrite"])
                    if inp + outp + cr + cw == 0 { continue }
                    let ts = jsonInt(obj["time"])
                    let sid = sessionID.isEmpty ? fallbackID : sessionID
                    let turn = data["turn"].map { String(describing: $0) } ?? "None"
                    let step = data["step"].map { String(describing: $0) } ?? "None"
                    let key = "\(sid)|\(turn)|\(step)"
                    let quote = prices.quote(model: model, input: inp, output: outp,
                                              cacheRead: cr, cacheWrite: cw, eventAtMs: ts)
                    outcome.added += try store.putEvent(
                        tool: name, srcKey: key, sessionID: sid, project: project,
                        ts: ts, model: model, input: inp, output: outp,
                        cacheRead: cr, cacheWrite: cw, cost: quote?.cost,
                        provider: quote?.provider ?? (model.lowercased().hasPrefix("deepseek-") ? "deepseek" : ""),
                        priceVersionID: quote?.priceVersionID)
                    if sessionID.isEmpty {
                        let oldKey = "\(oldFallback)|\(turn)|\(step)"
                        outcome.updated += try replaceOldFallback(
                            store, oldKey: oldKey, sid: sid, project: project,
                            ts: ts, model: model, counts: (inp, outp, cr, cw))
                    }
                } else if type == "usage" {
                    // 顶层 usage 事件（兜底）
                    let data = obj["data"] as? [String: Any] ?? [:]
                    let usage = (data["usage"] as? [String: Any]) ?? data
                    let inp = jsonOrInt(usage["inputTokens"], usage["input"])
                    let outp = jsonOrInt(usage["outputTokens"], usage["output"])
                    if inp + outp == 0 { continue }
                    let ts = jsonInt(obj["time"])
                    let sid = sessionID.isEmpty ? fallbackID : sessionID
                    let seq = obj["seq"].map { String(describing: $0) } ?? "None"
                    let key = "\(sid)|top|\(seq)"
                    let quote = prices.quote(model: model, input: inp, output: outp, eventAtMs: ts)
                    outcome.added += try store.putEvent(
                        tool: name, srcKey: key, sessionID: sid, project: project,
                        ts: ts, model: model, input: inp, output: outp, cost: quote?.cost,
                        provider: quote?.provider ?? (model.lowercased().hasPrefix("deepseek-") ? "deepseek" : ""),
                        priceVersionID: quote?.priceVersionID)
                    if sessionID.isEmpty {
                        let oldKey = "\(oldFallback)|top|\(seq)"
                        outcome.updated += try replaceOldFallback(
                            store, oldKey: oldKey, sid: sid, project: project,
                            ts: ts, model: model, counts: (inp, outp, 0, 0))
                    }
                }
            }
            cursor[path] = statKey.asDict
        }
        markActivityCurrent(&cursor)
        try store.setScanCursor(tool: name, cursor: cursor)
        return outcome
    }
}
