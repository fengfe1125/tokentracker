//
//  CodexScanner.swift
//  TokenTrackerCore
//
//  移植自 scanners/codex.py：rollout JSONL 优先，SQLite turn 遥测补缺。
//  input 归一化为不含缓存读/写。同 turn 优先 JSONL，SQLite 只补其缺少的
//  差额；没有可靠 turn 身份则按整个会话选择 JSONL。
//

import Foundation

public struct CodexScanner: ScannerAdapter {
    public let name = "codex"
    public let detail = "~/.codex/logs_2.sqlite 或 ~/.codex/sessions/"
    static let parserVersion = 5
    static let kindJSONL = "codex_jsonl"
    static let kindSQLite = "codex_sqlite"
    static let toolCallTypes: Set<String> = [
        "function_call", "custom_tool_call", "mcp_call", "local_shell_call",
        "shell_call", "computer_call", "apply_patch_call",
    ]
    static let toolOutputTypes: Set<String> = [
        "function_call_output", "custom_tool_call_output", "mcp_call_output",
        "local_shell_call_output", "shell_call_output", "computer_call_output",
        "apply_patch_call_output",
    ]

    public let logsDB: String
    public let sessionsDir: String

    public init(logsDB: String, sessionsDir: String) {
        self.logsDB = expandPath(logsDB)
        self.sessionsDir = expandPath(sessionsDir)
    }

    public func detect() -> Bool {
        FileManager.default.fileExists(atPath: logsDB) || isDirectory(sessionsDir)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // ------------------------------------------------------------ 解析 ----

    /// token_usage 字段正则（codex.turn.token_usage. 前缀可选，前面不能是词字符）。
    private static let fieldsRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<![\w])(?:codex\.turn\.token_usage\.)?(input_tokens|cached_input_tokens|cache_write_input_tokens|output_tokens)=(\d+)"#)
    }()
    private static let modelRegex = try! NSRegularExpression(pattern: #"\bmodel=["']?([\w./:\-]+)"#)
    private static let threadRegex = try! NSRegularExpression(pattern: #"\bthread\.id=["']?([\w\-]+)"#)
    private static let turnRegex = try! NSRegularExpression(pattern: #"\bturn\.id=["']?([\w\-]+)"#)
    private static let spanRegex = try! NSRegularExpression(pattern: #"\bturn\{([^{}]*)\}"#)

    private static let aliases: [([String], Int)] = [
        (["input_tokens"], 0),
        (["output_tokens"], 1),
        (["cached_input_tokens"], 2),
        (["cache_write_input_tokens", "cache_creation_input_tokens", "cache_write"], 3),
    ]

    func timestamp(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return Int64(d < 1e12 ? d * 1000 : d)
        }
        if let s = value as? String { return parseISODateMs(s) ?? 0 }
        return 0
    }

    /// 校验计数器（严格非负 int、非 bool），无效返回 nil。
    func counts(_ raw: [String: Any]?) -> (Int64, Int64, Int64, Int64)? {
        guard let raw else { return nil }
        let allKeys = CodexScanner.aliases.flatMap { $0.0 }
        guard allKeys.contains(where: { raw[$0] != nil }) else { return nil }
        var values: [Int64] = []
        for (keys, _) in CodexScanner.aliases {
            let value = keys.compactMap { raw[$0] }.first
            guard let v = value.flatMap({ jsonStrictNonNegativeInt($0) }) ?? (value == nil ? 0 : nil)
            else { return nil }
            values.append(v)
        }
        return (values[0], values[1], values[2], values[3])
    }

    func normalized(_ c: (Int64, Int64, Int64, Int64)) -> (Int64, Int64, Int64, Int64) {
        (max(c.0 - c.2 - c.3, 0), c.1, c.2, c.3)
    }

    private func regexFirst(_ re: NSRegularExpression, _ body: String) -> String? {
        let range = NSRange(body.startIndex..., in: body)
        guard let match = re.firstMatch(in: body, range: range),
              let r = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[r])
    }

    // ------------------------------------------------------------ 落库 ----

    @discardableResult
    private func put(_ store: UsageStore, _ prices: PriceTable, key: String, sid: String,
                     turn: String, model: String, ts: Int64,
                     counts: (Int64, Int64, Int64, Int64), kind: String,
                     project: String = "", quality: String = "exact") throws -> (Int, Int) {
        let n = normalized(counts)
        let cost = prices.cost(for: model, input: n.0, output: n.1, cacheRead: n.2, cacheWrite: n.3)
        let exists = try store.conn.queryOne(
            "SELECT 1 FROM usage_events WHERE tool=? AND src_key=?", [name, key]) != nil
        try store.putEvent(tool: name, srcKey: key, sessionID: sid, project: project,
                           ts: ts > 0 ? ts : 1, model: model,
                           input: n.0, output: n.1, cacheRead: n.2, cacheWrite: n.3,
                           cost: cost, replace: true,
                           timeQuality: ts > 0 ? quality : "unallocated",
                           costSource: "estimate", sourceKind: kind, sourceScope: turn)
        return exists ? (0, 1) : (1, 0)
    }

    private func coveredByJSONL(_ store: UsageStore, sid: String, turn: String) throws -> Bool {
        var sql = "SELECT 1 FROM usage_events WHERE tool=? AND session_id=? AND source_kind=?"
        var args: [Any?] = [name, sid, CodexScanner.kindJSONL]
        if !turn.isEmpty {
            sql += " AND (source_scope=? OR source_scope='')"
            args.append(turn)
        }
        return try store.conn.queryOne(sql + " LIMIT 1", args) != nil
    }

    private func jsonlCounts(_ store: UsageStore, sid: String, turn: String) throws -> (Int64, Int64, Int64, Int64) {
        let row = try store.conn.queryOne(
            "SELECT COALESCE(SUM(input+cache_read+cache_write),0) AS a,COALESCE(SUM(output),0) AS b,"
                + "COALESCE(SUM(cache_read),0) AS c,COALESCE(SUM(cache_write),0) AS d FROM usage_events "
                + "WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
            [name, sid, CodexScanner.kindJSONL, turn])
        return (row?.int("a") ?? 0, row?.int("b") ?? 0, row?.int("c") ?? 0, row?.int("d") ?? 0)
    }

    private func rawRow(_ row: Row) -> (Int64, Int64, Int64, Int64) {
        (row.int("input") + row.int("cache_read") + row.int("cache_write"),
         row.int("output"), row.int("cache_read"), row.int("cache_write"))
    }

    /// 减去四个互斥事件类别，而不是用包含缓存的 input 去减独立缓存计数。
    private func remaining(_ total: (Int64, Int64, Int64, Int64),
                           _ known: (Int64, Int64, Int64, Int64)) -> (Int64, Int64, Int64, Int64) {
        let tn = normalized(total), kn = normalized(known)
        let inp = max(tn.0 - kn.0, 0), out = max(tn.1 - kn.1, 0)
        let cached = max(tn.2 - kn.2, 0), written = max(tn.3 - kn.3, 0)
        return (inp + cached + written, out, cached, written)
    }

    /// 选取唯一填充的 span，绝不合并两个嵌套 turn。
    private func sqliteBody(_ body: String) -> String {
        let range = NSRange(body.startIndex..., in: body)
        let spans = CodexScanner.spanRegex.matches(in: body, range: range).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
        let candidates = spans.filter { $0.contains("codex.turn.token_usage.input_tokens=") }
        return candidates.last ?? body
    }

    // -------------------------------------------------------- SQLite 源 ----

    private func scanSQLite(_ store: UsageStore, _ prices: PriceTable,
                            cursor: inout [String: Any], full: Bool) throws -> (Int, Int, Int) {
        guard FileManager.default.fileExists(atPath: logsDB) else { return (0, 0, 0) }
        var added = 0, updated = 0
        let src = try sqliteRO(logsDB)

        var st = stat()
        guard stat(logsDB, &st) == 0 else { return (0, 0, 0) }
        let identity: [Any] = [Int64(st.st_dev), Int64(st.st_ino),
                               (logsDB as NSString).standardizingPath]
        let storedIdentity = cursor["logs2_identity"] as? [Any]
        let identityMatches: Bool
        if let storedIdentity, storedIdentity.count == 3 {
            identityMatches = (storedIdentity[0] as? NSNumber)?.int64Value == identity[0] as? Int64
                && (storedIdentity[1] as? NSNumber)?.int64Value == identity[1] as? Int64
                && (storedIdentity[2] as? String) == identity[2] as? String
        } else {
            identityMatches = false
        }
        var last: Int64 = (full || !identityMatches)
            ? 0 : ((cursor["logs2_last_id"] as? NSNumber)?.int64Value ?? 0)
        let maximum = try src.scalarInt("SELECT COALESCE(MAX(id),0) FROM logs")
        if maximum < last { last = 0 }
        let rows = try src.query(
            "SELECT id,ts,ts_nanos,feedback_log_body FROM logs WHERE id>? "
                + "AND feedback_log_body LIKE '%codex.turn.token_usage.input_tokens=%' ORDER BY id",
            [last])
        for row in rows {
            last = row.int("id")
            let body = sqliteBody(row.string("feedback_log_body"))
            let nsBody = body as NSString
            var fieldDict: [String: Any] = [:]
            for match in CodexScanner.fieldsRegex.matches(
                in: body, range: NSRange(body.startIndex..., in: body)) {
                let key = nsBody.substring(with: match.range(at: 1))
                let value = nsBody.substring(with: match.range(at: 2))
                fieldDict[key] = Int64(value) // Python dict 推导：后出现的覆盖先出现的
            }
            guard var parsedCounts = counts(fieldDict), parsedCounts != (0, 0, 0, 0) else { continue }
            let thread = regexFirst(CodexScanner.threadRegex, body)
            let turn = regexFirst(CodexScanner.turnRegex, body) ?? ""
            let sid = thread ?? (!turn.isEmpty ? turn : String(row.int("id")))
            let model = regexFirst(CodexScanner.modelRegex, body) ?? ""
            let tsRaw = row.int64OrZero("ts")
            var ts: Int64
            if tsRaw > Int64(1e14) {
                ts = tsRaw / 1_000_000
            } else {
                ts = timestamp(tsRaw == 0 ? nil : tsRaw)
                if tsRaw > 0 && tsRaw < Int64(1e11) {
                    ts += row.int("ts_nanos") / 1_000_000
                }
            }
            var key = "logs2|\(row.int("id"))"
            let old = try store.conn.queryOne(
                "SELECT * FROM usage_events WHERE tool=? AND src_key=?", [name, key])
            // 被替换的数据源可能复用了属于其他会话的行 ID。
            if let old, old.string("session_id") != sid
                || (!old.string("source_scope").isEmpty && old.string("source_scope") != turn) {
                key = "logs2|\(sid)|\(turn)|\(row.int("id"))"
            }
            if try coveredByJSONL(store, sid: sid, turn: turn) {
                let unscoped = try store.conn.queryOne(
                    "SELECT 1 FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope='' LIMIT 1",
                    [name, sid, CodexScanner.kindJSONL]) != nil
                if turn.isEmpty || unscoped {
                    _ = try store.conn.execute(
                        "DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?",
                        [name, key, sid])
                    continue
                }
                // 还在增长的 rollout 可能只包含该 turn 的一部分；保留已核实的余额。
                parsedCounts = remaining(parsedCounts, try jsonlCounts(store, sid: sid, turn: turn))
                if parsedCounts == (0, 0, 0, 0) {
                    _ = try store.conn.execute(
                        "DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
                        [name, sid, CodexScanner.kindSQLite, turn])
                    _ = try store.conn.execute(
                        "DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?",
                        [name, key, sid])
                    continue
                }
            }
            if !turn.isEmpty {
                if let same = try store.conn.queryOne(
                    "SELECT * FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=? ORDER BY id LIMIT 1",
                    [name, sid, CodexScanner.kindSQLite, turn]) {
                    // 多条日志行携带同一 turn 总量：复用首个 src_key，保留最大完整快照。
                    if same.string("src_key") != key {
                        _ = try store.conn.execute(
                            "DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?",
                            [name, key, sid])
                    }
                    key = same.string("src_key")
                    let existing = rawRow(same)
                    if parsedCounts.0 + parsedCounts.1 < existing.0 + existing.1 { continue }
                }
            }
            let (a, u) = try put(store, prices, key: key, sid: sid, turn: turn,
                                 model: model, ts: ts, counts: parsedCounts,
                                 kind: CodexScanner.kindSQLite)
            added += a
            updated += u
        }
        cursor["logs2_last_id"] = last
        cursor["logs2_identity"] = identity
        return (added, updated, 1)
    }

    // -------------------------------------------------------- JSONL 源 ----

    struct RolloutEvent {
        var key: String?
        var sid = ""
        var turn = ""
        var model = ""
        var ts: Int64 = 0
        var counts = (Int64(0), Int64(0), Int64(0), Int64(0))
        var project = ""
        var quality = "exact"
        var title: String?
    }

    private func rolloutEvents(_ path: String) -> [RolloutEvent] {
        var events: [RolloutEvent] = []
        var sid = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var project = (path as NSString).deletingLastPathComponent
        var model = "", turn = ""
        var sidFromMeta = false
        var previous: (Int64, Int64, Int64, Int64)?
        struct FallbackKey: Hashable {
            let turn: String
            let ts: Int64
            let counts: (Int64, Int64, Int64, Int64)
            static func == (a: FallbackKey, b: FallbackKey) -> Bool {
                a.turn == b.turn && a.ts == b.ts && a.counts == b.counts
            }
            func hash(into hasher: inout Hasher) {
                hasher.combine(turn); hasher.combine(ts)
                hasher.combine(counts.0); hasher.combine(counts.1)
                hasher.combine(counts.2); hasher.combine(counts.3)
            }
        }
        var fallbackSeen = Set<FallbackKey>()
        var title: String?

        for (lineno, obj) in iterJSONL(path) {
            if title == nil {
                let text = userText(obj)
                if !text.isEmpty { title = text }
            }
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let kind = obj["type"] as? String
            if kind == "session_meta" {
                // 子代理/fork 的 rollout 会重放父会话的 session_meta：只有首条（自身）
                // 有权决定 sid，否则子会话用量记到父会话头上，且子会话的 SQLite
                // 遥测因找不到 JSONL 覆盖而把同一用量再算一遍。空串也回退。
                if !sidFromMeta, let id = payload["id"] as? String, !id.isEmpty {
                    sid = id
                    sidFromMeta = true
                }
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty { project = cwd }
                continue
            }
            if kind == "turn_context" {
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
                if let t = payload["turn_id"] as? String, !t.isEmpty { turn = t }
                continue
            }
            if kind == "event_msg" && payload["type"] as? String == "task_started" {
                turn = (payload["turn_id"] as? String) ?? ""
                continue
            }
            if kind == "event_msg" && ["task_complete", "turn_aborted"].contains(payload["type"] as? String) {
                turn = ""
                continue
            }
            let ts = timestamp(obj["timestamp"])
            let quality = "exact"
            let eventTurn = (payload["turn_id"] as? String) ?? (obj["turn_id"] as? String) ?? turn
            var counts: (Int64, Int64, Int64, Int64)?
            if kind == "event_msg" && payload["type"] as? String == "token_count" {
                guard let info = payload["info"] as? [String: Any] else { continue }
                let total = self.counts(info["total_token_usage"] as? [String: Any])
                let last = self.counts(info["last_token_usage"] as? [String: Any])
                if let total {
                    if previous == nil {
                        counts = total
                        // 续跑/分叉文件的首个 total 带着继承历史；只有 last
                        // 是这个文件中新发生、可以安全归因的调用。
                        if let last, last != total {
                            counts = last
                        }
                    } else if let prev = previous,
                              zip([total.0, total.1, total.2, total.3],
                                  [prev.0, prev.1, prev.2, prev.3]).contains(where: { $0 < $1 }) {
                        // compaction 可能重置计数器：建立新基线，不产生负差量。
                        previous = total
                        continue
                    } else if let prev = previous {
                        counts = (total.0 - prev.0, total.1 - prev.1, total.2 - prev.2, total.3 - prev.3)
                    }
                    previous = total
                } else if let last {
                    counts = last
                    let fingerprint = FallbackKey(turn: eventTurn, ts: ts, counts: last)
                    if fallbackSeen.contains(fingerprint) { continue }
                    fallbackSeen.insert(fingerprint)
                    // 之后的累计快照已包含这些调用。
                    let p = previous ?? (0, 0, 0, 0)
                    previous = (p.0 + last.0, p.1 + last.1, p.2 + last.2, p.3 + last.3)
                } else {
                    continue
                }
            } else {
                let raw = (obj["tokens"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])
                guard let c = self.counts(raw) else { continue }
                counts = c
                if let s = obj["thread_id"] as? String, !s.isEmpty { sid = s }
                else if let s = obj["session_id"] as? String, !s.isEmpty { sid = s }
                if let m = obj["model"] as? String, !m.isEmpty { model = m }
                else if let m = obj["modelId"] as? String, !m.isEmpty { model = m }
            }
            guard let finalCounts = counts,
                  finalCounts != (Int64(0), Int64(0), Int64(0), Int64(0)) else { continue }
            events.append(RolloutEvent(key: "legacy|\(path)|\(lineno)", sid: sid,
                                       turn: eventTurn, model: model, ts: ts,
                                       counts: finalCounts, project: project, quality: quality))
        }
        if let title {
            events.append(RolloutEvent(key: nil, sid: sid, project: project, title: title))
        }
        return events
    }

    private func replaceSQLiteScope(_ store: UsageStore, _ prices: PriceTable,
                                    event: RolloutEvent,
                                    previousJSONL: (Int64, Int64, Int64, Int64)) throws {
        let sid = event.sid, turn = event.turn
        if turn.isEmpty {
            _ = try store.conn.execute(
                "DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=?",
                [name, sid, CodexScanner.kindSQLite])
            return
        }
        _ = try store.conn.execute(
            "DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=''",
            [name, sid, CodexScanner.kindSQLite])
        if let same = try store.conn.queryOne(
            "SELECT * FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
            [name, sid, CodexScanner.kindSQLite, turn]) {
            let raw = rawRow(same)
            let total = (raw.0 + previousJSONL.0, raw.1 + previousJSONL.1,
                         raw.2 + previousJSONL.2, raw.3 + previousJSONL.3)
            let rest = remaining(total, try jsonlCounts(store, sid: sid, turn: turn))
            if rest != (0, 0, 0, 0) {
                _ = try put(store, prices, key: same.string("src_key"), sid: sid, turn: turn,
                            model: same.string("model"), ts: same.int("ts"), counts: rest,
                            kind: CodexScanner.kindSQLite, project: same.string("project"),
                            quality: same.string("time_quality"))
            } else {
                _ = try store.conn.execute("DELETE FROM usage_events WHERE tool=? AND src_key=?",
                                           [name, same.string("src_key")])
            }
        }
    }

    private func scanRolloutActivity(_ store: UsageStore, path: String) throws -> (Int, Int) {
        var sid = String((path as NSString).lastPathComponent.dropLast(".jsonl".count))
        var turn = ""
        var added = 0, updated = 0
        for (lineno, obj) in iterJSONL(path) {
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let kind = obj["type"] as? String ?? ""
            if kind == "session_meta" {
                if let value = payload["id"] as? String, !value.isEmpty { sid = value }
                continue
            }
            if kind == "turn_context" {
                if let value = payload["turn_id"] as? String, !value.isEmpty { turn = value }
                continue
            }
            if kind == "event_msg", payload["type"] as? String == "task_started" {
                turn = payload["turn_id"] as? String ?? turn
                continue
            }
            guard kind == "response_item" else { continue }
            let itemType = payload["type"] as? String ?? ""
            let tsValue = timestamp(obj["timestamp"])
            let ts: Int64? = tsValue == 0 ? nil : tsValue
            let callID = jsonOrString(payload["call_id"], payload["id"])
            if CodexScanner.toolCallTypes.contains(itemType) {
                var rawName = payload["name"] as? String ?? ""
                if rawName.isEmpty {
                    if ["local_shell_call", "shell_call"].contains(itemType) { rawName = "shell" }
                    else if itemType == "apply_patch_call" { rawName = "apply_patch" }
                    else if itemType == "computer_call" { rawName = "computer" }
                }
                guard !rawName.isEmpty else { continue }
                let arguments = payload["arguments"] ?? payload["input"] ?? payload["action"]
                let sourceKey = "\(realPath(path))|response|\(jsonOrString(payload["id"], callID).isEmpty ? String(lineno) : jsonOrString(payload["id"], callID))"
                let change = try store.recordActivity(
                    agent: name, srcKey: sourceKey, rawName: rawName, sessionID: sid,
                    turnID: turn, callID: callID, startedAt: ts,
                    sourceKind: "codex_rollout", arguments: arguments, allowSkillPath: true)
                added += change.added; updated += change.updated
                if rawName == "exec", let script = arguments as? String {
                    for (index, inner) in ActivityNormalizer.inferredCodexTools(script).enumerated() {
                        let child = try store.recordActivity(
                            agent: name, srcKey: "\(sourceKey)|inner|\(index)", rawName: inner,
                            sessionID: sid, turnID: turn, parentCallID: callID,
                            startedAt: ts, sourceKind: "codex_exec_payload",
                            confidence: "derived")
                        added += child.added; updated += child.updated
                    }
                }
            } else if CodexScanner.toolOutputTypes.contains(itemType) {
                var status = ActivityNormalizer.status(payload["status"])
                if status == "unknown", let output = payload["output"] as? [String: Any] {
                    status = ((output["is_error"] as? Bool) == true || output["error"] != nil)
                        ? "error" : "success"
                }
                if status == "unknown" { status = "success" }
                updated += try store.completeActivity(agent: name, callID: callID,
                                                       status: status, endedAt: ts)
            }
        }
        return (added, updated)
    }

    private func scanLegacy(_ store: UsageStore, _ prices: PriceTable,
                            cursor: inout [String: Any], full: Bool) throws -> (Int, Int, Int, Int, Int) {
        guard isDirectory(sessionsDir) else { return (0, 0, 0, 0, 0) }
        var added = 0, updated = 0, files = 0, activityAdded = 0, activityUpdated = 0
        var allFiles: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: sessionsDir) {
            for case let entry as String in enumerator where entry.hasSuffix(".jsonl") {
                allFiles.append((sessionsDir as NSString).appendingPathComponent(entry))
            }
        }
        allFiles.sort()
        for path in allFiles {
            if !full && !fingerprintChanged(cursor: cursor, path: path) { continue }
            guard let statKey = StatKey(path: path) else { continue }
            files += 1
            for event in rolloutEvents(path) {
                guard let key = event.key else {   // 会话标题事件：首个真实用户消息
                    if let title = event.title {
                        try store.setSessionTitle(tool: name, sessionID: event.sid, title: title)
                    }
                    continue
                }
                // 只有经过校验的非空 payload 才有权替换。
                let previousJSONL = try jsonlCounts(store, sid: event.sid, turn: event.turn)
                let (a, u) = try put(store, prices, key: key, sid: event.sid, turn: event.turn,
                                     model: event.model, ts: event.ts, counts: event.counts,
                                     kind: CodexScanner.kindJSONL, project: event.project,
                                     quality: event.quality)
                try replaceSQLiteScope(store, prices, event: event, previousJSONL: previousJSONL)
                added += a
                updated += u
            }
            let activity = try scanRolloutActivity(store, path: path)
            activityAdded += activity.0
            activityUpdated += activity.1
            cursor[path] = statKey.asDict
        }
        return (added, updated, files, activityAdded, activityUpdated)
    }

    // ------------------------------------------------------------ 入口 ----

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        var cursor = try store.getScanCursor(tool: name)
        let effectiveFull = full
            || (cursor["parser_version"] as? NSNumber)?.intValue != CodexScanner.parserVersion
            || activityNeedsBackfill(cursor)
        // 数据源删除、插入、游标移动一起回滚（即使调用方捕获后继续其他工具）。
        _ = try store.conn.execute("SAVEPOINT codex_scan")
        do {
            // JSONL 先扫（主源），SQLite 后扫补缺：同一趟内去重查询就能看到
            // 最新的 JSONL 归因，归因变更无需等下一次全量扫描才收敛。
            let (a2, u2, f2, aa2, au2) = try scanLegacy(
                store, prices, cursor: &cursor, full: effectiveFull)
            let (a1, u1, f1) = try scanSQLite(store, prices, cursor: &cursor, full: effectiveFull)
            let ambiguous = try store.conn.query(
                "SELECT old.id FROM usage_events old WHERE old.tool=? AND old.source_kind='' "
                    + "AND old.src_key LIKE 'logs2|%' AND EXISTS "
                    + "(SELECT 1 FROM usage_events new WHERE new.tool=old.tool AND new.session_id=old.session_id AND new.source_kind=?)",
                [name, CodexScanner.kindJSONL])
            for row in ambiguous {
                _ = try store.conn.execute("UPDATE usage_events SET time_quality='unallocated' WHERE id=?",
                                           [row.int("id")])
            }
            cursor["parser_version"] = CodexScanner.parserVersion
            markActivityCurrent(&cursor)
            let cursorJSON = String(data: try JSONSerialization.data(withJSONObject: cursor),
                                    encoding: .utf8) ?? "{}"
            _ = try store.conn.execute("INSERT OR REPLACE INTO scan_state(tool,cursor) VALUES (?,?)",
                                       [name, cursorJSON])
            _ = try store.conn.execute("RELEASE SAVEPOINT codex_scan")
            var outcome = ScanOutcome(added: a1 + a2, updated: u1 + u2, files: f1 + f2,
                                      activityAdded: aa2, activityUpdated: au2)
            if !ambiguous.isEmpty {
                outcome.warning = "保留 \(ambiguous.count) 条无法核实与 JSONL 对应关系的旧 Codex 日志；已标记时间未知，可能存在重复历史。"
            }
            return outcome
        } catch {
            _ = try? store.conn.execute("ROLLBACK TO SAVEPOINT codex_scan")
            _ = try? store.conn.execute("RELEASE SAVEPOINT codex_scan")
            throw error
        }
    }
}

private extension Row {
    func int64OrZero(_ key: String) -> Int64 { int(key) }
}
