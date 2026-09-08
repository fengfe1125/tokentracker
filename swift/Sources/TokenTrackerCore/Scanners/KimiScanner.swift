//
//  KimiScanner.swift
//  TokenTrackerCore
//
//  移植自 scanners/kimi.py：~/.kimi-code/server/events/session_*.jsonl
//  （事件日志）+ kimi-cli ~/.kimi/sessions/（通用 JSONL 兜底）。
//  turn.step.completed 的 usage 是每步增量 → 直接累加，不重复计数。
//

import Foundation

public struct KimiScanner: ScannerAdapter {
    public let name = "kimi"
    public let detail = "~/.kimi-code/server/events/session_*.jsonl"
    public let journalDir: String
    public let cliDir: String

    public init(journalDir: String, cliDir: String) {
        self.journalDir = expandPath(journalDir)
        self.cliDir = expandPath(cliDir)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func detect() -> Bool {
        isDirectory(journalDir) || isDirectory(cliDir)
    }

    private func parseTS(_ raw: Any?) -> Int64 {
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return Int64(d < 1e12 ? d * 1000 : d)
        }
        if let s = raw as? String { return parseISODateMs(s) ?? 0 }
        return 0
    }

    private func jsonlFiles(under base: String, matching predicate: (String) -> Bool) -> [String] {
        var out: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: base) {
            for case let entry as String in enumerator where predicate(entry) {
                out.append((base as NSString).appendingPathComponent(entry))
            }
        }
        return out.sorted()
    }

    private func scanJournal(_ store: UsageStore, _ prices: PriceTable,
                             cursor: inout [String: Any], full: Bool) throws -> ScanOutcome {
        var outcome = ScanOutcome()
        guard isDirectory(journalDir) else { return outcome }
        let files = jsonlFiles(under: journalDir) {
            ($0 as NSString).lastPathComponent.hasPrefix("session_")
                && $0.hasSuffix(".jsonl")
        }
        for path in files {
            if !full && !fingerprintChanged(cursor: cursor, path: path) { continue }
            guard let statKey = StatKey(path: path) else { continue }
            outcome.files += 1
            let filename = (path as NSString).lastPathComponent
            let sessionID = String(filename.dropFirst("session_".count).dropLast(".jsonl".count))
            var project = ""
            var modelHint = ""
            var title: String?
            for (_, obj) in iterJSONL(path) {
                let kind = obj["kind"] as? String
                let envelope = obj["envelope"] as? [String: Any] ?? [:]
                let payload = envelope["payload"] as? [String: Any] ?? [:]
                let eventType = envelope["type"] as? String ?? ""
                let activityTS = parseTS(jsonOrAny(envelope["timestamp"], obj["time"]))
                if kind == "event" && eventType == "tool.call.started" {
                    let call = payload["toolCall"] as? [String: Any] ?? payload
                    let rawName = jsonOrString(call["name"], call["toolName"], call["tool"])
                    let callID = jsonOrString(call["id"], call["toolCallId"], payload["toolCallId"])
                    if !rawName.isEmpty {
                        let change = try store.recordActivity(
                            agent: name, srcKey: "\(sessionID)|tool|\(callID.isEmpty ? String(describing: obj["seq"] ?? "") : callID)",
                            rawName: rawName, sessionID: sessionID,
                            turnID: payload["turnId"] as? String ?? "", callID: callID,
                            startedAt: activityTS == 0 ? nil : activityTS,
                            sourceKind: "kimi_journal",
                            arguments: jsonOrAny(call["args"], call["arguments"], call["input"]))
                        outcome.activityAdded += change.added
                        outcome.activityUpdated += change.updated
                    }
                } else if kind == "event" && eventType == "tool.result" {
                    let callID = jsonOrString(payload["toolCallId"], payload["callId"], payload["id"])
                    var status = ActivityNormalizer.status(jsonOrAny(payload["status"], payload["error"]))
                    if status == "unknown" { status = payload["error"] == nil ? "success" : "error" }
                    outcome.activityUpdated += try store.completeActivity(
                        agent: name, callID: callID, status: status,
                        endedAt: activityTS == 0 ? nil : activityTS,
                        durationMs: (payload["durationMs"] as? NSNumber)?.int64Value)
                }
                if title == nil && kind == "event" && envelope["type"] as? String == "turn.started" {
                    if let prompt = payload["prompt"] as? String,
                       !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = cleanSessionTitle(prompt)
                    }
                }
                if kind == "event" && envelope["type"] as? String == "event.session.created" {
                    let session = payload["session"] as? [String: Any] ?? [:]
                    let meta = session["metadata"] as? [String: Any] ?? [:]
                    if let cwd = meta["cwd"] as? String, !cwd.isEmpty { project = cwd }
                    continue
                }
                guard kind == "event",
                      envelope["type"] as? String == "turn.step.completed",
                      let usage = payload["usage"] as? [String: Any] else { continue }
                let inp = jsonInt(usage["inputOther"])      // 非缓存输入增量
                let outp = jsonInt(usage["output"])
                let cr = jsonInt(usage["inputCacheRead"])
                let cw = jsonInt(usage["inputCacheCreation"])
                if inp + outp + cr + cw == 0 { continue }
                var m = payload["model"]
                if let dict = m as? [String: Any] { m = dict["id"] }
                if let mStr = m as? String, !mStr.isEmpty { modelHint = mStr }
                // 事件日志不携带模型字段，默认 kimi-code（k3 家族）
                let model = modelHint.isEmpty ? "kimi-code" : modelHint
                let ts = parseTS(jsonOrAny(envelope["timestamp"], obj["time"]))
                let key = "\(sessionID)|step|\((obj["seq"] as? NSNumber).map { $0.stringValue } ?? "None")"
                let cost = prices.cost(for: model, input: inp, output: outp,
                                       cacheRead: cr, cacheWrite: cw)
                outcome.added += try store.putEvent(
                    tool: name, srcKey: key, sessionID: sessionID, project: project,
                    ts: ts, model: model, input: inp, output: outp,
                    cacheRead: cr, cacheWrite: cw, cost: cost)
            }
            cursor[path] = statKey.asDict
            if let title {
                try store.setSessionTitle(tool: name, sessionID: sessionID, title: title)
            }
        }
        return outcome
    }

    private func scanCLI(_ store: UsageStore, _ prices: PriceTable,
                         cursor: inout [String: Any], full: Bool) throws -> ScanOutcome {
        var outcome = ScanOutcome()
        guard isDirectory(cliDir) else { return outcome }
        let files = jsonlFiles(under: cliDir) { $0.hasSuffix(".jsonl") }
        for path in files {
            if !full && !fingerprintChanged(cursor: cursor, path: path) { continue }
            guard let statKey = StatKey(path: path) else { continue }
            outcome.files += 1
            let filename = (path as NSString).lastPathComponent
            for (lineno, obj) in iterJSONL(path) {
                guard let usage = obj["usage"] as? [String: Any] else { continue }
                let inp = jsonOrInt(usage["input"], usage["input_tokens"])
                let outp = jsonOrInt(usage["output"], usage["output_tokens"])
                if inp + outp == 0 { continue }
                let model = obj["model"] as? String ?? ""
                let cost = prices.cost(for: model, input: inp, output: outp)
                outcome.added += try store.putEvent(
                    tool: name, srcKey: "cli|\(path)|\(lineno)",
                    sessionID: String(filename.dropLast(".jsonl".count)),
                    project: (path as NSString).deletingLastPathComponent,
                    ts: parseTS(obj["timestamp"]), model: model,
                    input: inp, output: outp, cost: cost)
            }
            cursor[path] = statKey.asDict
        }
        return outcome
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        var cursor = try store.getScanCursor(tool: name)
        let effectiveFull = full || activityNeedsBackfill(cursor)
        let journal = try scanJournal(store, prices, cursor: &cursor, full: effectiveFull)
        let cli = try scanCLI(store, prices, cursor: &cursor, full: effectiveFull)
        markActivityCurrent(&cursor)
        try store.setScanCursor(tool: name, cursor: cursor)
        return ScanOutcome(added: journal.added + cli.added,
                           updated: journal.updated + cli.updated,
                           files: journal.files + cli.files,
                           activityAdded: journal.activityAdded + cli.activityAdded,
                           activityUpdated: journal.activityUpdated + cli.activityUpdated)
    }
}
