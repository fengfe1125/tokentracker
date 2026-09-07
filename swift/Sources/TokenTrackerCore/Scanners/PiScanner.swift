//
//  PiScanner.swift
//  TokenTrackerCore
//
//  移植自 scanners/pi.py：~/.pi/agent/sessions/**/*.jsonl（Oh My Pi: ~/.omp）。
//  幂等键：文件内事件 id；官方 cost 优先，缺失时价格表估算。
//

import Foundation

public struct PiScanner: ScannerAdapter {
    public let name = "pi"
    public let detail = "~/.pi/agent/sessions/**/*.jsonl"
    public let roots: [String]

    public init(roots: [String]) {
        self.roots = roots.map(expandPath).filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public func detect() -> Bool {
        !roots.isEmpty
    }

    private func parseTS(_ raw: Any?) -> Int64 {
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return Int64(d < 1e12 ? d * 1000 : d)
        }
        if let s = raw as? String { return parseISODateMs(s) ?? 0 }
        return 0
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        var cursor = try store.getScanCursor(tool: name)
        var outcome = ScanOutcome()
        for base in roots {
            var files: [String] = []
            if let enumerator = FileManager.default.enumerator(atPath: base) {
                for case let entry as String in enumerator where entry.hasSuffix(".jsonl") {
                    files.append((base as NSString).appendingPathComponent(entry))
                }
            }
            files.sort()
            for path in files {
                if !full && !fingerprintChanged(cursor: cursor, path: path) { continue }
                guard let statKey = StatKey(path: path) else { continue }
                outcome.files += 1
                var sessionID = ""
                var project = ((path as NSString).deletingLastPathComponent as NSString)
                    .lastPathComponent
                var title: String?
                for (_, obj) in iterJSONL(path) {
                    if title == nil {
                        let text = userText(obj)
                        if !text.isEmpty { title = text }
                    }
                    let type = obj["type"] as? String
                    if type == "session" {
                        sessionID = obj["id"] as? String ?? ""
                        let cwd = obj["cwd"] as? String ?? ""
                        if !cwd.isEmpty { project = cwd }
                        continue
                    }
                    guard type == "message",
                          let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any] else { continue }
                    let inp = jsonInt(usage["input"])
                    let outp = jsonInt(usage["output"])
                    let cr = jsonInt(usage["cacheRead"])
                    let cw = jsonInt(usage["cacheWrite"])
                    if inp + outp + cr + cw == 0 { continue }
                    let model = jsonOrString(msg["model"], obj["modelId"])
                    let ts = parseTS(jsonOrAny(msg["timestamp"], obj["timestamp"]))
                    let basename = (path as NSString).lastPathComponent
                    let eventID = (obj["id"] as? NSNumber)?.stringValue
                        ?? (obj["id"] as? String) ?? "None"
                    let key = "\(basename)|\(eventID)"
                    let costObj = usage["cost"] as? [String: Any] ?? [:]
                    // 官方 cost 优先；<=0 时价格表估算（未匹配保持 nil，不计费）
                    var cost: Double? = (costObj["total"] as? NSNumber)?.doubleValue ?? 0
                    if (cost ?? 0) <= 0 {
                        cost = prices.cost(for: model, input: inp, output: outp,
                                           cacheRead: cr, cacheWrite: cw)
                    }
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
        }
        try store.setScanCursor(tool: name, cursor: cursor)
        return outcome
    }
}
