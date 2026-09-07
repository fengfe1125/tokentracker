//
//  ClaudeScanner.swift
//  TokenTrackerCore
//
//  移植自 scanners/claude.py：~/.claude/projects/<slug>/*.jsonl。
//  以 message.id 为幂等键；增量按字节游标，截断/轮转回退全量（行号兜底键）。
//

import Foundation

public struct ClaudeScanner: ScannerAdapter {
    public let name = "claude"
    public let detail = "~/.claude/projects/**/*.jsonl"
    public let root: String

    public init(root: String) {
        self.root = expandPath(root)
    }

    public func detect() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
    }

    private func ms(fromTS ts: String?, fallback: Int64) -> Int64 {
        if let ts, let ms = parseISODateMs(ts) { return ms }
        return fallback
    }

    /// 解析一行 → (added, 标题候选)。标题 = 首个真实用户消息。
    private func scanLine(_ obj: [String: Any], fallbackKey: String, sessionID: String,
                          slug: String, mtimeMs: Int64, prices: PriceTable,
                          store: UsageStore) throws -> (Int, String?) {
        let title = userText(obj)
        let msg = obj["message"] as? [String: Any] ?? [:]
        var usage = msg["usage"] as? [String: Any]
        if usage == nil { usage = obj["usage"] as? [String: Any] }
        guard let usage else { return (0, title.isEmpty ? nil : title) }
        let inp = jsonInt(usage["input_tokens"])
        let outp = jsonInt(usage["output_tokens"])
        let cr = jsonInt(usage["cache_read_input_tokens"])
        let cw = jsonInt(usage["cache_creation_input_tokens"])
        if inp + outp + cr + cw == 0 { return (0, title.isEmpty ? nil : title) }
        let model = jsonOrString(msg["model"], obj["model"])
        let key = (msg["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(sessionID)|\(fallbackKey)"
        let ts = ms(fromTS: obj["timestamp"] as? String, fallback: mtimeMs)
        let cost = prices.cost(for: model, input: inp, output: outp, cacheRead: cr, cacheWrite: cw)
        let added = try store.putEvent(tool: name, srcKey: "\(sessionID)|\(key)",
                                       sessionID: sessionID, project: slug, ts: ts,
                                       model: model, input: inp, output: outp,
                                       cacheRead: cr, cacheWrite: cw, cost: cost)
        return (added, title.isEmpty ? nil : title)
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        var cursor = try store.getScanCursor(tool: name)
        var outcome = ScanOutcome()
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return outcome }
        // 收集 (dirpath, filename)；os.walk 跨目录顺序无关（结果集按 src_key 落库后排序导出），
        // 目录内文件名排序对齐 sorted(names)。
        var files: [(dir: String, fileName: String)] = []
        for case let entry as String in enumerator {
            let dir = (entry as NSString).deletingLastPathComponent
            let fileName = (entry as NSString).lastPathComponent
            files.append((dir, fileName))
        }
        files.sort { $0.dir == $1.dir ? $0.fileName < $1.fileName : $0.dir < $1.dir }

        for (relDir, fileName) in files {
            let dirpath = relDir.isEmpty ? root : (root as NSString).appendingPathComponent(relDir)
            if dirpath == root { continue }  // slug 目录在下一层
            guard fileName.hasSuffix(".jsonl") else { continue }
            let dirBase = (dirpath as NSString).lastPathComponent
            let slug = dirBase == "projects"
                ? ((dirpath as NSString).deletingLastPathComponent as NSString).lastPathComponent
                : (dirBase.isEmpty ? dirpath : dirBase)
            let path = (dirpath as NSString).appendingPathComponent(fileName)
            if !full && !fingerprintChanged(cursor: cursor, path: path) { continue }
            guard let statKey = StatKey(path: path) else { continue }
            outcome.files += 1

            let sessionID = String(fileName.dropLast(".jsonl".count))
            var title: String?
            let mtimeMs = statKey.m / 1_000_000
            let prevOffset: Int64 = full ? 0 : ((cursor[path] as? [String: Any])
                .flatMap { ($0["o"] as? NSNumber)?.int64Value } ?? 0)
            var newOffset: Int64 = 0
            var delta: [(Int64, [String: Any])]?
            if prevOffset > 0 {
                let (items, offset) = readJSONLDelta(path: path, offset: prevOffset)
                if offset < 0 {
                    delta = nil            // 截断/轮转/偏移失效 → 全量
                } else {
                    delta = items
                    newOffset = offset
                }
            }
            if delta == nil {
                // 全量解析：行号兜底键，与历史数据幂等
                for (lineno, obj) in iterJSONL(path) {
                    let (a, t) = try scanLine(obj, fallbackKey: String(lineno),
                                              sessionID: sessionID, slug: slug,
                                              mtimeMs: mtimeMs, prices: prices, store: store)
                    outcome.added += a
                    if let t, title == nil { title = t }
                }
                newOffset = statKey.s
            } else if let delta {
                // 增量解析：字节偏移兜底键（仅追加文件中稳定）
                for (lineOffset, obj) in delta {
                    let (a, t) = try scanLine(obj, fallbackKey: "b\(lineOffset)",
                                              sessionID: sessionID, slug: slug,
                                              mtimeMs: mtimeMs, prices: prices, store: store)
                    outcome.added += a
                    if let t, title == nil { title = t }
                }
            }
            var snapshot = statKey.asDict
            snapshot["o"] = newOffset
            cursor[path] = snapshot
            if let title {
                try store.setSessionTitle(tool: self.name, sessionID: sessionID, title: title)
            }
        }
        try store.setScanCursor(tool: name, cursor: cursor)
        return outcome
    }
}
