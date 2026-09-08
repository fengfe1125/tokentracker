//
//  UsageStore.swift
//  TokenTrackerCore
//
//  移植自 tokentracker/db.py：SQLite 汇总库、事务式 schema 升级、
//  显式时间质量。token 四列互斥：非缓存输入 / 输出 / 缓存读 / 缓存写。
//  未知历史留在总量里；观察区间不强行归入其跨越的日期/小时。
//
//  时钟可注入（nowMs），差分测试与单测用固定时钟对齐 Python 侧
//  冻结 db.time.time 的行为。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class UsageStore {
    public static let schemaVersion: Int32 = 3
    public static let tokenColumns = ["input", "output", "cache_read", "cache_write"]
    public static let tokensExpr = "(input+output+cache_read+cache_write)"

    static let schema = """
    CREATE TABLE IF NOT EXISTS usage_events (
        id INTEGER PRIMARY KEY, tool TEXT NOT NULL, session_id TEXT NOT NULL DEFAULT '',
        project TEXT NOT NULL DEFAULT '', ts INTEGER NOT NULL, model TEXT NOT NULL DEFAULT '',
        input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
        cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
        cost REAL, src_key TEXT NOT NULL,
        time_quality TEXT NOT NULL DEFAULT 'exact', interval_start INTEGER,
        cost_source TEXT NOT NULL DEFAULT 'estimate',
        source_kind TEXT NOT NULL DEFAULT '', source_scope TEXT NOT NULL DEFAULT '',
        UNIQUE(tool, src_key)
    );
    CREATE INDEX IF NOT EXISTS idx_events_tool_ts ON usage_events(tool, ts);
    CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events(ts);
    CREATE TABLE IF NOT EXISTS scan_state (tool TEXT PRIMARY KEY, cursor TEXT);
    CREATE TABLE IF NOT EXISTS aggregate_snapshots (
        tool TEXT NOT NULL, source_scope TEXT NOT NULL, identity TEXT NOT NULL,
        values_json TEXT NOT NULL, observed_at INTEGER NOT NULL, revision INTEGER NOT NULL,
        PRIMARY KEY(tool, source_scope, identity)
    );
    CREATE TABLE IF NOT EXISTS migration_history (
        version INTEGER NOT NULL, migrated_at INTEGER NOT NULL, event_id INTEGER,
        original_json TEXT NOT NULL, note TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS session_meta (
        tool TEXT NOT NULL, session_id TEXT NOT NULL, title TEXT NOT NULL,
        updated_at INTEGER NOT NULL, PRIMARY KEY(tool, session_id)
    );
    CREATE TABLE IF NOT EXISTS agent_activity_events (
        id INTEGER PRIMARY KEY, agent TEXT NOT NULL,
        session_id TEXT NOT NULL DEFAULT '', turn_id TEXT NOT NULL DEFAULT '',
        raw_name TEXT NOT NULL, canonical_name TEXT NOT NULL,
        namespace TEXT NOT NULL DEFAULT '', call_id TEXT NOT NULL DEFAULT '',
        parent_call_id TEXT NOT NULL DEFAULT '', started_at INTEGER, ended_at INTEGER,
        duration_ms INTEGER, status TEXT NOT NULL DEFAULT 'unknown',
        source_kind TEXT NOT NULL DEFAULT '', confidence TEXT NOT NULL DEFAULT 'exact',
        skill_name TEXT NOT NULL DEFAULT '', skill_confidence TEXT NOT NULL DEFAULT '',
        src_key TEXT NOT NULL, UNIQUE(agent, src_key)
    );
    CREATE INDEX IF NOT EXISTS idx_activity_agent_time ON agent_activity_events(agent, started_at);
    CREATE INDEX IF NOT EXISTS idx_activity_session ON agent_activity_events(agent, session_id, started_at);
    CREATE INDEX IF NOT EXISTS idx_activity_tool ON agent_activity_events(canonical_name, started_at);
    CREATE INDEX IF NOT EXISTS idx_activity_skill ON agent_activity_events(skill_name, started_at);
    """

    public let conn: SQLiteConnection
    public let path: String
    /// 测试缝：putEvent 写入前调用（可抛错模拟写入失败，验证回滚路径）。
    public var putEventHook: ((_ tool: String, _ sourceKind: String) throws -> Void)?
    /// 注入时钟（毫秒）。测试冻结；生产为系统时间。
    public var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// 迁移重定价用的价格表（App 层注入真实价格表；默认内置）。
    public var priceTableForMigration: PriceTable = .default

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        conn = try SQLiteConnection(path: path)
        let version = Int32(try conn.scalarInt("PRAGMA user_version"))
        if version != UsageStore.schemaVersion {
            if path == ":memory:" {
                try upgrade(from: version)
            } else {
                let lockPath = path + ".migrate.lock"
                let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
                if fd >= 0 {
                    flock(fd, LOCK_EX)
                    defer { flock(fd, LOCK_UN); close(fd) }
                    try upgrade(from: version)
                } else {
                    try upgrade(from: version)
                }
            }
        }
    }

    deinit { try? conn.commit() }

    // ------------------------------------------------------------ 迁移 ----

    private func upgrade(from version: Int32) throws {
        if version > UsageStore.schemaVersion {
            throw SQLiteError(message: "Database version \(version) is newer than supported \(UsageStore.schemaVersion)")
        }
        if version == UsageStore.schemaVersion { return }
        let legacy = try conn.queryOne(
            "SELECT 1 FROM sqlite_master WHERE name='usage_events'") != nil
        if legacy {
            let backupPath = "\(path).v\(version).backup-\(DispatchTime.now().uptimeNanoseconds).db"
            let backup = try SQLiteConnection(path: backupPath)
            try conn.backup(to: backup)
        }
        if version < 3 { try validateResidualActivityTable() }
        try conn.beginImmediate()
        do {
            if legacy && version < 1 {
                let columns: [(String, String)] = [
                    ("time_quality", "TEXT NOT NULL DEFAULT 'exact'"),
                    ("interval_start", "INTEGER"),
                    ("cost_source", "TEXT NOT NULL DEFAULT 'estimate'"),
                    ("source_kind", "TEXT NOT NULL DEFAULT ''"),
                    ("source_scope", "TEXT NOT NULL DEFAULT ''"),
                ]
                for (column, declaration) in columns {
                    _ = try conn.execute("ALTER TABLE usage_events ADD COLUMN \(column) \(declaration)")
                }
            }
            for statement in UsageStore.schema.split(separator: ";") {
                let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { _ = try conn.execute(trimmed) }
            }
            if legacy && version < 1 {
                let prices = priceTableForMigration
                for row in try conn.query(
                    "SELECT * FROM usage_events WHERE tool IN ('codex','opencode','hermes')") {
                    let original = row.values.compactMapValues { $0 }
                    let originalJSON = (try? String(data: JSONSerialization.data(
                        withJSONObject: original), encoding: .utf8)) ?? "{}"
                    _ = try conn.execute("INSERT INTO migration_history VALUES (?,?,?,?,?)", [
                        Int64(UsageStore.schemaVersion), nowMs(), row.intOrNil("id") as Any,
                        originalJSON,
                        "Preserved original counters; Codex prices recalculated using the current price table (not a historical bill).",
                    ])
                    if row.string("tool") == "codex" {
                        let inp = max(0, row.int("input") - row.int("cache_read") - row.int("cache_write"))
                        let cost = prices.cost(for: row.string("model"), input: inp,
                                               output: row.int("output"),
                                               cacheRead: row.int("cache_read"),
                                               cacheWrite: row.int("cache_write"))
                        let quality = row.string("src_key").hasPrefix("legacy|") ? "unallocated" : "exact"
                        _ = try conn.execute(
                            "UPDATE usage_events SET input=?,cost=?,cost_source='recomputed',time_quality=? WHERE id=?",
                            [inp, cost as Any, quality, row.int("id")])
                    } else {
                        _ = try conn.execute(
                            "UPDATE usage_events SET time_quality='unallocated',cost_source='legacy' WHERE id=?",
                            [row.int("id")])
                    }
                }
            }
            _ = try conn.execute("PRAGMA user_version=\(UsageStore.schemaVersion)")
            try conn.commit()
        } catch {
            try conn.rollback()
            throw error
        }
    }

    /// Some rollback builds reset user_version to 2 while leaving the complete
    /// v3 activity table behind. Preserve that table, but never guess how to
    /// migrate a malformed residual schema.
    private func validateResidualActivityTable() throws {
        guard try conn.queryOne(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_activity_events'") != nil
        else { return }
        let expected: Set<String> = [
            "id", "agent", "session_id", "turn_id", "raw_name", "canonical_name",
            "namespace", "call_id", "parent_call_id", "started_at", "ended_at",
            "duration_ms", "status", "source_kind", "confidence", "skill_name",
            "skill_confidence", "src_key",
        ]
        let columns = Set(try conn.query("PRAGMA table_info(agent_activity_events)")
            .map { $0.string("name") })
        guard columns == expected else {
            throw SQLiteError(message: "Existing agent_activity_events schema is incompatible")
        }
        var hasIdentityConstraint = false
        for index in try conn.query("PRAGMA index_list(agent_activity_events)")
            where index.int("unique") == 1 {
            let escaped = index.string("name").replacingOccurrences(of: "\"", with: "\"\"")
            let names = try conn.query("PRAGMA index_info(\"\(escaped)\")")
                .sorted { $0.int("seqno") < $1.int("seqno") }
                .map { $0.string("name") }
            if names == ["agent", "src_key"] {
                hasIdentityConstraint = true
                break
            }
        }
        guard hasIdentityConstraint else {
            throw SQLiteError(message: "Existing agent_activity_events lacks UNIQUE(agent,src_key)")
        }
    }

    // ------------------------------------------------------------ 写入 ----

    /// INSERT OR IGNORE（replace=true 时 OR REPLACE）。返回实际写入行数。
    @discardableResult
    public func putEvent(tool: String, srcKey: String, sessionID: String = "",
                         project: String = "", ts input0: Int64 = 0, model: String = "",
                         input: Int64 = 0, output: Int64 = 0,
                         cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
                         cost: Double? = nil, replace: Bool = false,
                         timeQuality: String = "exact", intervalStart: Int64? = nil,
                         costSource: String = "estimate", sourceKind: String = "",
                         sourceScope: String = "") throws -> Int {
        var quality = timeQuality
        var ts = input0
        if let putEventHook { try putEventHook(tool, sourceKind) }
        guard ["exact", "observed", "unallocated"].contains(quality) else {
            throw SQLiteError(message: "Unknown time quality: \(quality)")
        }
        if quality == "observed" && (intervalStart == nil || intervalStart! > ts) {
            quality = "unallocated"
        }
        if ts <= 0 { ts = nowMs() }
        let verb = replace ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        return try conn.execute(
            "\(verb) INTO usage_events (tool,src_key,session_id,project,ts,model,input,output,cache_read,cache_write,cost,"
                + "time_quality,interval_start,cost_source,source_kind,source_scope) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [tool, srcKey, sessionID, project, ts, model, input, output, cacheRead, cacheWrite,
             cost as Any, quality, intervalStart as Any, costSource, sourceKind, sourceScope])
    }

    @discardableResult
    public func putActivityEvent(_ event: ActivityEvent) throws -> (added: Int, updated: Int) {
        guard ["success", "error", "denied", "unknown"].contains(event.status),
              ["exact", "derived"].contains(event.confidence),
              event.skillConfidence.isEmpty || ["exact", "derived"].contains(event.skillConfidence),
              !event.agent.isEmpty, !event.srcKey.isEmpty, !event.rawName.isEmpty else {
            throw SQLiteError(message: "Invalid activity event")
        }
        let before = try conn.queryOne(
            "SELECT status,ended_at,duration_ms FROM agent_activity_events WHERE agent=? AND src_key=?",
            [event.agent, event.srcKey])
        _ = try conn.execute("""
            INSERT INTO agent_activity_events (
              agent,session_id,turn_id,raw_name,canonical_name,namespace,call_id,parent_call_id,
              started_at,ended_at,duration_ms,status,source_kind,confidence,
              skill_name,skill_confidence,src_key
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(agent,src_key) DO UPDATE SET
              session_id=CASE WHEN excluded.session_id!='' THEN excluded.session_id ELSE session_id END,
              turn_id=CASE WHEN excluded.turn_id!='' THEN excluded.turn_id ELSE turn_id END,
              ended_at=COALESCE(excluded.ended_at,ended_at),
              duration_ms=COALESCE(excluded.duration_ms,duration_ms),
              status=CASE WHEN excluded.status!='unknown' THEN excluded.status ELSE status END,
              skill_name=CASE WHEN excluded.skill_name!='' THEN excluded.skill_name ELSE skill_name END,
              skill_confidence=CASE WHEN excluded.skill_confidence!='' THEN excluded.skill_confidence ELSE skill_confidence END
            """, [event.agent, event.sessionID, event.turnID, event.rawName, event.canonicalName,
                   event.namespace, event.callID, event.parentCallID, event.startedAt as Any,
                   event.endedAt as Any, event.durationMs as Any, event.status, event.sourceKind,
                   event.confidence, event.skillName, event.skillConfidence, event.srcKey])
        let after = try conn.queryOne(
            "SELECT status,ended_at,duration_ms FROM agent_activity_events WHERE agent=? AND src_key=?",
            [event.agent, event.srcKey])
        let changed = before != nil && (before?.string("status") != after?.string("status")
            || before?.intOrNil("ended_at") != after?.intOrNil("ended_at")
            || before?.intOrNil("duration_ms") != after?.intOrNil("duration_ms"))
        return (before == nil ? 1 : 0, changed ? 1 : 0)
    }

    @discardableResult
    public func completeActivity(agent: String, callID: String, status: String = "success",
                                 endedAt: Int64? = nil, durationMs inputDuration: Int64? = nil) throws -> Int {
        guard !callID.isEmpty, ["success", "error", "denied", "unknown"].contains(status),
              let row = try conn.queryOne(
                "SELECT id,started_at,status,ended_at,duration_ms FROM agent_activity_events "
                    + "WHERE agent=? AND call_id=? ORDER BY id DESC LIMIT 1", [agent, callID]) else { return 0 }
        var duration = inputDuration
        if duration == nil, let endedAt, let started = row.intOrNil("started_at") {
            duration = max(0, endedAt - started)
        }
        let effectiveEnded = endedAt ?? row.intOrNil("ended_at")
        let effectiveDuration = duration ?? row.intOrNil("duration_ms")
        let changed = row.string("status") != status || row.intOrNil("ended_at") != effectiveEnded
            || row.intOrNil("duration_ms") != effectiveDuration
        _ = try conn.execute("UPDATE agent_activity_events SET status=?,ended_at=COALESCE(?,ended_at),"
            + "duration_ms=COALESCE(?,duration_ms) WHERE id=?",
            [status, endedAt as Any, duration as Any, row.int("id")])
        return changed ? 1 : 0
    }

    public func setScanCursor(tool: String, cursor: [String: Any]) throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: cursor), encoding: .utf8) ?? "{}"
        _ = try conn.execute("INSERT OR REPLACE INTO scan_state(tool,cursor) VALUES (?,?)", [tool, json])
        try conn.commit()
    }

    public func getScanCursor(tool: String) throws -> [String: Any] {
        guard let row = try conn.queryOne("SELECT cursor FROM scan_state WHERE tool=?", [tool]),
              let text = row.stringOrNil("cursor"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }

    /// 会话标题（首个 user 消息等）。只在内容变化时更新，幂等。
    public func setSessionTitle(tool: String, sessionID: String, title: String) throws {
        let cleaned = collapseWhitespace(title)
        guard !cleaned.isEmpty, !sessionID.isEmpty else { return }
        _ = try conn.execute("""
            INSERT INTO session_meta VALUES (?,?,?,?)
            ON CONFLICT(tool, session_id) DO UPDATE SET title=excluded.title,
            updated_at=excluded.updated_at WHERE session_meta.title != excluded.title
            """, [tool, sessionID, cleaned, nowMs()])
    }

    // ---------------------------------------------------- 聚合快照引擎 ----

    /// 持久化一次累计观测，只入库其差量（不 commit）。
    /// 首次观测没有可靠事件时间；不变的观测也会推进区间下界；
    /// 计数器下降则建立新基线，不产生负事件。
    @discardableResult
    public func putSnapshot(tool: String, sourceScope: String, identity: String,
                            sessionID: String, project: String, model: String,
                            input: Int64 = 0, output: Int64 = 0,
                            cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
                            nativeCost: Double? = nil, costSource: String = "native",
                            prices: PriceTable = .default, legacyKey: String? = nil,
                            observedAt: Int64? = nil) throws -> (added: Int, counterResets: Int) {
        if !conn.inTransaction { try conn.beginImmediate() }
        let now = observedAt ?? nowMs()
        let digest = sha256Hex(pythonJSONDumps([sourceScope, identity]))
        var values: [String: Any?] = [
            "input": max(0, input), "output": max(0, output),
            "cache_read": max(0, cacheRead), "cache_write": max(0, cacheWrite),
            "native_cost": nativeCost as Any,
            "native_source": nativeCost != nil ? costSource : nil,
        ]

        let row = try conn.queryOne(
            "SELECT * FROM aggregate_snapshots WHERE tool=? AND source_scope=? AND identity=?",
            [tool, sourceScope, identity])
        var previous: [String: Any?]?
        var start: Int64?
        var revision: Int64 = -1
        if let row {
            previous = decodeSnapshotValues(row.string("values_json"))
            start = row.intOrNil("observed_at")
            revision = row.int("revision")
        } else if let legacyKey {
            let legacy = try conn.queryOne(
                "SELECT * FROM usage_events WHERE tool=? AND src_key=? AND source_scope=''",
                [tool, legacyKey])
            if let legacy {
                var prev: [String: Any?] = [:]
                for k in UsageStore.tokenColumns { prev[k] = legacy.int(k) }
                prev["accounted_cost"] = legacy.doubleOrNil("cost") ?? 0
                let legacySource = legacy.string("cost_source")
                let legacyNative = (legacySource == "native" || legacySource == "provider_estimate") ? legacySource : nil
                prev["native_source"] = legacyNative as Any
                prev["native_cost"] = (legacyNative != nil ? legacy.doubleOrNil("cost") : nil) as Any
                prev["legacy_key"] = legacyKey
                _ = try conn.execute(
                    "UPDATE usage_events SET time_quality='unallocated',source_kind='aggregate_snapshot',source_scope=? WHERE id=?",
                    [sourceScope, legacy.int("id")])
                previous = prev
            }
        }
        let adoptedKey = (previous?["legacy_key"] as? String) ?? legacyKey

        let ledgerWhere = "tool=? AND (src_key LIKE ? OR (src_key=? AND source_scope=?))"
        let ledgerArgs: [Any?] = [tool, "aggregate|\(digest)|%", adoptedKey ?? "", sourceScope]
        func ledgerCost() throws -> Double {
            try conn.queryOne("SELECT COALESCE(SUM(cost),0) FROM usage_events WHERE \(ledgerWhere)",
                              ledgerArgs)?.double("COALESCE(SUM(cost),0)") ?? 0
        }
        let costOffset = (previous?["cost_offset"] as? Double)
            ?? ((previous?["cost_offset"] as? Int64).map(Double.init) ?? 0)
        var accounted: Double
        if let prev = previous, prev.keys.contains("accounted_cost") {
            accounted = (prev["accounted_cost"] as? Double)
                ?? ((prev["accounted_cost"] as? Int64).map(Double.init) ?? 0)
        } else {
            // 兼容成本账本出现之前的快照：用真实账本减去旧纪元留存。
            accounted = try ledgerCost() - costOffset
        }

        func prevInt(_ key: String) -> Int64 {
            (previous?[key] as? Int64) ?? ((previous?[key] as? Double).map(Int64.init) ?? 0)
        }
        let reset = previous != nil && UsageStore.tokenColumns.contains {
            ((values[$0] as? Int64) ?? 0) < prevInt($0)
        }
        var delta: [String: Int64] = [:]
        for k in UsageStore.tokenColumns {
            delta[k] = ((values[k] as? Int64) ?? 0) - (previous != nil ? prevInt(k) : 0)
        }

        var added = 0
        func emit(_ counters: [String: Int64], _ cost: Double?, _ origin: String, _ quality: String) throws {
            revision += 1
            added += try putEvent(
                tool: tool, srcKey: "aggregate|\(digest)|\(revision)",
                sessionID: sessionID, project: project, ts: now, model: model,
                input: counters["input"] ?? 0, output: counters["output"] ?? 0,
                cacheRead: counters["cache_read"] ?? 0, cacheWrite: counters["cache_write"] ?? 0,
                cost: cost, timeQuality: quality,
                intervalStart: quality == "observed" ? start : nil,
                costSource: origin, sourceKind: "aggregate_snapshot", sourceScope: sourceScope)
        }

        if !reset {
            let prevNative = previous?["native_cost"] as? Double
            let continuousNative = previous != nil && nativeCost != nil && prevNative != nil
                && (previous?["native_source"] as? String) == costSource
                && nativeCost! >= prevNative!
            if previous != nil && nativeCost != nil && !continuousNative {
                // 观测之间 reprice 可能已回填 NULL 成本；对账真实账本，
                // 并减去旧纪元留存的开销。
                accounted = try ledgerCost() - costOffset
            }
            let cost: Double?
            let origin: String
            if nativeCost != nil && (previous == nil || continuousNative) {
                cost = nativeCost! - (prevNative ?? 0)
                origin = costSource
            } else {
                cost = prices.cost(for: model, input: delta["input"] ?? 0,
                                   output: delta["output"] ?? 0,
                                   cacheRead: delta["cache_read"] ?? 0,
                                   cacheWrite: delta["cache_write"] ?? 0)
                origin = "estimate"
            }
            if delta.values.contains(where: { $0 != 0 }) || (cost != nil && cost != 0) {
                try emit(delta, cost, origin, start != nil ? "observed" : "unallocated")
                accounted += cost ?? 0
            }
            if previous != nil && nativeCost != nil && !continuousNative {
                // 首个权威累计成本（或来源切换）对账历史，不落入当前时间桶。
                let correction = nativeCost! - accounted
                if abs(correction) > 1e-9 {
                    try emit(Dictionary(uniqueKeysWithValues: UsageStore.tokenColumns.map { ($0, Int64(0)) }),
                             correction, "native_adjustment", "unallocated")
                }
                accounted = nativeCost!
                // 这些未知单价已并入累计调整；后续 reprice 不得重复收费。
                _ = try conn.execute(
                    "UPDATE usage_events SET cost=0,cost_source='native_included' WHERE \(ledgerWhere) AND cost IS NULL",
                    ledgerArgs)
            }
        } else {
            revision += 1
            // 计数器重启：未来 native 成本相对此基线，而非旧纪元留存。
            if let nativeCost {
                accounted = nativeCost
            } else {
                accounted = prices.cost(for: model, input: values["input"] as? Int64 ?? 0,
                                        output: values["output"] as? Int64 ?? 0,
                                        cacheRead: values["cache_read"] as? Int64 ?? 0,
                                        cacheWrite: values["cache_write"] as? Int64 ?? 0) ?? 0
            }
            let ledger = try ledgerCost()
            values["cost_offset"] = ledger - accounted
        }
        if !reset {
            values["cost_offset"] = costOffset
        }
        values["accounted_cost"] = accounted
        values["legacy_key"] = adoptedKey as Any

        let valuesJSON = String(data: try JSONSerialization.data(
            withJSONObject: values.compactMapValues { $0 }), encoding: .utf8) ?? "{}"
        _ = try conn.execute("INSERT OR REPLACE INTO aggregate_snapshots VALUES (?,?,?,?,?,?)",
                             [tool, sourceScope, identity, valuesJSON, now, revision])
        return (added, reset ? 1 : 0)
    }

    private func decodeSnapshotValues(_ text: String) -> [String: Any?] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dict = object as? [String: Any] else { return [:] }
        return dict.mapValues { $0 is NSNull ? nil : $0 }
    }

    // ------------------------------------------------------------ 查询 ----

    static let aggSelect = UsageStore.tokenColumns.map { "COALESCE(SUM(\($0)),0) AS \($0)" }.joined(separator: ", ")
        + ", COALESCE(SUM(\(UsageStore.tokensExpr)),0) AS tokens, COUNT(*) AS events,"
        + " COALESCE(SUM(CASE WHEN cost IS NULL THEN 1 ELSE 0 END),0) AS unpriced,"
        + " COALESCE(SUM(CASE WHEN time_quality='observed' THEN \(UsageStore.tokensExpr) ELSE 0 END),0) AS estimated_tokens,"
        + " COALESCE(SUM(CASE WHEN time_quality='unallocated' THEN \(UsageStore.tokensExpr) ELSE 0 END),0) AS unallocated_tokens,"
        + " COALESCE(SUM(cost),0) AS cost"

    /// 测试可覆盖范围边界（对齐 Python 测试 patch db._range_bounds）。
    public var rangeBoundsOverride: (Int64, Int64)?

    public func rangeBounds(_ rangeKey: String) -> (Int64, Int64) {
        if let override = rangeBoundsOverride { return override }
        let now = Date(timeIntervalSince1970: TimeInterval(nowMs()) / 1000)
        var cal = Calendar.current
        cal.timeZone = .current
        let start: Date
        switch rangeKey {
        case "day":
            start = cal.startOfDay(for: now)
        case "week":
            start = cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now)!)
        case "month":
            var c = cal.dateComponents([.year, .month], from: now)
            c.day = 1
            start = cal.date(from: c)!
        default:
            start = Date(timeIntervalSince1970: 0)
        }
        return (Int64(start.timeIntervalSince1970 * 1000),
                Int64((now.timeIntervalSince1970 + 1) * 1000))
    }

    private func countable(_ lo: Int64, _ hi: Int64) -> (String, [Any?]) {
        ("(time_quality='exact' OR (time_quality='observed' AND interval_start>=?)) AND ts>=? AND ts<?",
         [lo, lo, hi])
    }

    private func filter(_ rangeKey: String, tool: String? = nil, modelPrefix: String? = nil) -> (String, [Any?]) {
        var sql: String
        var args: [Any?]
        if rangeKey == "all" {
            sql = "1"; args = []
        } else {
            (sql, args) = countable(rangeBounds(rangeKey).0, rangeBounds(rangeKey).1)
        }
        if let tool { sql += " AND tool=?"; args.append(tool) }
        if let modelPrefix { sql += " AND model LIKE ?"; args.append(modelPrefix + "%") }
        return (sql, args)
    }

    private func scope(_ sql: String, _ args: [Any?], tool: String? = nil, modelPrefix: String? = nil) -> (String, [Any?]) {
        var sql = sql; var args = args
        if let tool { sql += " AND tool=?"; args.append(tool) }
        if let modelPrefix { sql += " AND model LIKE ?"; args.append(modelPrefix + "%") }
        return (sql, args)
    }

    private func bucketExpr(_ column: String, _ bucket: String) -> String {
        let fmt = bucket == "hour" ? "%Y-%m-%d %H" : "%Y-%m-%d"
        return "strftime('\(fmt)', \(column)/1000, 'unixepoch', 'localtime')"
    }

    private func bucketFilter(_ bucket: String) -> String {
        "(time_quality='exact' OR (time_quality='observed' AND \(bucketExpr("interval_start", bucket))=\(bucketExpr("ts", bucket))))"
    }

    public struct TimeSummary: Equatable, Sendable {
        public var unallocatedTokens: Int64
        public var unallocatedCost: Double
        public var unallocatedEvents: Int64
        public var estimatedTokens: Int64

        public init(unallocatedTokens: Int64, unallocatedCost: Double,
                    unallocatedEvents: Int64, estimatedTokens: Int64) {
            self.unallocatedTokens = unallocatedTokens
            self.unallocatedCost = unallocatedCost
            self.unallocatedEvents = unallocatedEvents
            self.estimatedTokens = estimatedTokens
        }
    }

    public func timeSummary(rangeKey: String = "all", bucket: String? = nil,
                            tool: String? = nil) throws -> TimeSummary {
        var (whereSQL, args) = filter(rangeKey, tool: tool)
        if let bucket { whereSQL += " AND " + bucketFilter(bucket) }
        let estimate = try conn.queryOne(
            "SELECT COALESCE(SUM(\(UsageStore.tokensExpr)),0) FROM usage_events WHERE \(whereSQL) AND time_quality='observed'",
            args)?.int("COALESCE(SUM(\(UsageStore.tokensExpr)),0)") ?? 0

        var excluded: String
        var excludedArgs: [Any?]
        if rangeKey == "all" {
            excluded = "time_quality='unallocated'"
            excludedArgs = []
            if let bucket { excluded += " OR (time_quality='observed' AND NOT " + bucketFilter(bucket) + ")" }
        } else {
            let (lo, hi) = rangeBounds(rangeKey)
            var (included, includedArgs) = countable(lo, hi)
            if let bucket { included += " AND " + bucketFilter(bucket) }
            // 未知历史可能属于任何范围；区间仅在重叠时才相关。
            excluded = "time_quality='unallocated' OR (time_quality='observed' AND ts>=? AND interval_start<? AND NOT (\(included)))"
            excludedArgs = [lo, hi] + includedArgs
        }
        (excluded, excludedArgs) = scope("(\(excluded))", excludedArgs, tool: tool)
        let row = try conn.queryOne(
            "SELECT COALESCE(SUM(\(UsageStore.tokensExpr)),0) AS tokens,COALESCE(SUM(cost),0) AS cost,COUNT(*) AS events FROM usage_events WHERE \(excluded)",
            excludedArgs)
        return TimeSummary(unallocatedTokens: row?.int("tokens") ?? 0,
                           unallocatedCost: row?.double("cost") ?? 0,
                           unallocatedEvents: row?.int("events") ?? 0,
                           estimatedTokens: estimate)
    }

    public struct ToolStats: Equatable, Sendable {
        public var tool = ""
        public var sessions: Int64 = 0
        public var input: Int64 = 0, output: Int64 = 0
        public var cacheRead: Int64 = 0, cacheWrite: Int64 = 0
        public var tokens: Int64 = 0, events: Int64 = 0, unpriced: Int64 = 0
        public var estimatedTokens: Int64 = 0, unallocatedTokens: Int64 = 0
        public var cost: Double = 0

        init(row: Row) {
            tool = row.string("tool")
            sessions = row.int("sessions")
            input = row.int("input"); output = row.int("output")
            cacheRead = row.int("cache_read"); cacheWrite = row.int("cache_write")
            tokens = row.int("tokens"); events = row.int("events"); unpriced = row.int("unpriced")
            estimatedTokens = row.int("estimated_tokens")
            unallocatedTokens = row.int("unallocated_tokens")
            cost = row.double("cost")
        }
        public init() {}
    }

    public func stats(rangeKey: String = "all", tool: String? = nil) throws
        -> (rows: [ToolStats], total: ToolStats, summary: TimeSummary) {
        let (whereSQL, args) = filter(rangeKey, tool: tool)
        let rows = try conn.query(
            "SELECT tool,COUNT(DISTINCT session_id) AS sessions,\(UsageStore.aggSelect) FROM usage_events WHERE \(whereSQL) GROUP BY tool ORDER BY tokens DESC",
            args).map(ToolStats.init(row:))
        var total = ToolStats()
        total.tool = "__total__"
        for row in rows {
            total.sessions += row.sessions
            total.input += row.input; total.output += row.output
            total.cacheRead += row.cacheRead; total.cacheWrite += row.cacheWrite
            total.tokens += row.tokens; total.events += row.events
            total.unpriced += row.unpriced
            total.estimatedTokens += row.estimatedTokens
            total.unallocatedTokens += row.unallocatedTokens
            total.cost += row.cost
        }
        total.cost = roundHalfEven(total.cost, 6)
        return (rows, total, try timeSummary(rangeKey: rangeKey, tool: tool))
    }

    public struct DailyRow: Equatable, Sendable {
        public var tool: String
        public var day: String
        public var stats: ToolStats
    }

    public func daily(rangeKey: String = "all") throws -> [DailyRow] {
        let bucket = rangeKey == "day" ? "hour" : "day"
        let label = bucket == "hour"
            ? "strftime('%H:00', ts/1000, 'unixepoch', 'localtime')"
            : bucketExpr("ts", bucket)
        let (whereSQL, args) = filter(rangeKey)
        return try conn.query(
            "SELECT tool,\(label) AS d,\(UsageStore.aggSelect) FROM usage_events WHERE \(whereSQL) AND \(bucketFilter(bucket)) GROUP BY d,tool ORDER BY d",
            args).map { row in
                var s = ToolStats(row: row)
                s.tool = row.string("tool")
                return DailyRow(tool: row.string("tool"), day: row.string("d"), stats: s)
            }
    }

    public struct ModelRow: Equatable, Sendable {
        public var tool: String
        public var model: String
        public var stats: ToolStats
    }

    public func models(rangeKey: String = "all", tool: String? = nil) throws -> [ModelRow] {
        let (whereSQL, args) = filter(rangeKey, tool: tool)
        return try conn.query(
            "SELECT tool,model,\(UsageStore.aggSelect) FROM usage_events WHERE \(whereSQL) GROUP BY tool,model ORDER BY tokens DESC",
            args).map { ModelRow(tool: $0.string("tool"), model: $0.string("model"),
                                  stats: ToolStats(row: $0)) }
    }

    /// 窗口内可计数用量（usd=true 时返回成本）。
    public func windowUsage(startMs: Int64, tool: String? = nil, modelPrefix: String? = nil,
                            includeCache: Bool = false, usd: Bool = false) throws -> Double {
        let now = nowMs() + 1000
        var (sql, args) = countable(startMs, now)
        (sql, args) = scope(sql, args, tool: tool, modelPrefix: modelPrefix)
        let expr = usd ? "cost" : (includeCache ? UsageStore.tokensExpr : "input+output")
        let row = try conn.queryOne("SELECT COALESCE(SUM(\(expr)),0) FROM usage_events WHERE \(sql)", args)
        return usd ? (row?.double("COALESCE(SUM(\(expr)),0)") ?? 0)
                   : Double(row?.int("COALESCE(SUM(\(expr)),0)") ?? 0)
    }

    public func windowUnallocated(startMs: Int64, tool: String? = nil, modelPrefix: String? = nil,
                                  includeCache: Bool = false, usd: Bool = false) throws -> Double {
        var (sql, args) = ("(time_quality='unallocated' OR (time_quality='observed' AND ts>=? AND interval_start<?))",
                           [startMs, startMs] as [Any?])
        (sql, args) = scope(sql, args, tool: tool, modelPrefix: modelPrefix)
        let expr = usd ? "cost" : (includeCache ? UsageStore.tokensExpr : "input+output")
        let row = try conn.queryOne("SELECT COALESCE(SUM(\(expr)),0) FROM usage_events WHERE \(sql)", args)
        return usd ? (row?.double("COALESCE(SUM(\(expr)),0)") ?? 0)
                   : Double(row?.int("COALESCE(SUM(\(expr)),0)") ?? 0)
    }

    public func quotaUsage(rangeKey: String, tool: String? = nil, modelPrefix: String? = nil,
                           includeCache: Bool = false) throws -> (tokens: Int64, cost: Double) {
        let (whereSQL, args) = filter(rangeKey, tool: tool, modelPrefix: modelPrefix)
        let expr = includeCache ? UsageStore.tokensExpr : "input+output"
        let row = try conn.queryOne(
            "SELECT COALESCE(SUM(\(expr)),0) AS t,COALESCE(SUM(cost),0) AS c FROM usage_events WHERE \(whereSQL)", args)
        return (row?.int("t") ?? 0, row?.double("c") ?? 0)
    }

    /// 用价格表回填 NULL 成本（不覆盖已有成本）。
    @discardableResult
    public func reprice(_ prices: PriceTable) throws -> Int {
        var n = 0
        for row in try conn.query("SELECT * FROM usage_events WHERE cost IS NULL") {
            if let cost = prices.cost(for: row.string("model"), input: row.int("input"),
                                      output: row.int("output"),
                                      cacheRead: row.int("cache_read"),
                                      cacheWrite: row.int("cache_write")) {
                _ = try conn.execute("UPDATE usage_events SET cost=?,cost_source='estimate' WHERE id=?",
                                     [cost, row.int("id")])
                n += 1
            }
        }
        try conn.commit()
        return n
    }

    public struct ActivitySummaryRow: Equatable, Sendable {
        public var name: String
        public var calls: Int64
        public var sessions: Int64
        public var success: Int64
        public var errors: Int64
        public var denied: Int64
        public var unknown: Int64
        public var exact: Int64
        public var derived: Int64
        public var lastUsed: Int64
    }

    private func activityFilter(rangeKey: String, agent: String?, confidence: String,
                                sessionID: String?, skill: Bool) throws -> (String, [Any?]) {
        guard ["day", "week", "month", "all"].contains(rangeKey),
              ["exact", "derived", "all"].contains(confidence) else {
            throw SQLiteError(message: "Invalid activity filter")
        }
        var clauses: [String] = []
        var args: [Any?] = []
        if rangeKey != "all" {
            let bounds = rangeBounds(rangeKey)
            clauses.append("COALESCE(started_at,ended_at,0)>=? AND COALESCE(started_at,ended_at,0)<?")
            args.append(contentsOf: [bounds.0, bounds.1])
        }
        if let agent { clauses.append("agent=?"); args.append(agent) }
        if let sessionID { clauses.append("session_id=?"); args.append(sessionID) }
        if confidence != "all" {
            clauses.append((skill ? "skill_confidence" : "confidence") + "=?")
            args.append(confidence)
        }
        if skill { clauses.append("skill_name!=''") }
        return (clauses.isEmpty ? "1=1" : clauses.joined(separator: " AND "), args)
    }

    public func activitySummary(rangeKey: String = "all", agent: String? = nil,
                                group: String = "tool", confidence: String = "all",
                                sessionID: String? = nil) throws -> [ActivitySummaryRow] {
        guard ["agent", "tool", "skill"].contains(group) else {
            throw SQLiteError(message: "Invalid activity group")
        }
        let skill = group == "skill"
        let (whereSQL, args) = try activityFilter(rangeKey: rangeKey, agent: agent,
            confidence: confidence, sessionID: sessionID, skill: skill)
        let name = group == "agent" ? "agent"
            : (skill ? "skill_name" : (agent == nil ? "canonical_name" : "raw_name"))
        let evidence = skill ? "skill_confidence" : "confidence"
        return try conn.query("""
            SELECT \(name) AS name,COUNT(*) AS calls,COUNT(DISTINCT session_id) AS sessions,
              SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS success,
              SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) AS error,
              SUM(CASE WHEN status='denied' THEN 1 ELSE 0 END) AS denied,
              SUM(CASE WHEN status='unknown' THEN 1 ELSE 0 END) AS unknown,
              SUM(CASE WHEN \(evidence)='exact' THEN 1 ELSE 0 END) AS exact,
              SUM(CASE WHEN \(evidence)='derived' THEN 1 ELSE 0 END) AS derived,
              MAX(COALESCE(ended_at,started_at,0)) AS last_used
            FROM agent_activity_events WHERE \(whereSQL)
            GROUP BY \(name) ORDER BY calls DESC,name
            """, args).map { row in
                ActivitySummaryRow(name: row.string("name"), calls: row.int("calls"),
                    sessions: row.int("sessions"), success: row.int("success"),
                    errors: row.int("error"), denied: row.int("denied"),
                    unknown: row.int("unknown"), exact: row.int("exact"),
                    derived: row.int("derived"), lastUsed: row.int("last_used"))
            }
    }

    public func activityTimeline(rangeKey: String = "all", agent: String? = nil, sessionID: String? = nil,
                                 confidence: String = "all", limit: Int = 200,
                                 before: Int64? = nil) throws -> [ActivityEvent] {
        var (whereSQL, args) = try activityFilter(rangeKey: rangeKey, agent: agent,
            confidence: confidence, sessionID: sessionID, skill: false)
        if let before {
            whereSQL += " AND COALESCE(started_at,ended_at,0)<?"
            args.append(before)
        }
        args.append(max(1, min(limit, 1000)))
        return try conn.query("SELECT * FROM agent_activity_events WHERE \(whereSQL) "
            + "ORDER BY COALESCE(started_at,ended_at,0) DESC,id DESC LIMIT ?", args).map { row in
            ActivityEvent(agent: row.string("agent"), sessionID: row.string("session_id"),
                turnID: row.string("turn_id"), rawName: row.string("raw_name"),
                canonicalName: row.string("canonical_name"), namespace: row.string("namespace"),
                callID: row.string("call_id"), parentCallID: row.string("parent_call_id"),
                startedAt: row.intOrNil("started_at"), endedAt: row.intOrNil("ended_at"),
                durationMs: row.intOrNil("duration_ms"), status: row.string("status"),
                sourceKind: row.string("source_kind"), confidence: row.string("confidence"),
                skillName: row.string("skill_name"), skillConfidence: row.string("skill_confidence"),
                srcKey: row.string("src_key"))
        }
    }

    public struct ObservationInterval: Equatable, Sendable {
        public var intervalStart: Int64?
        public var ts: Int64
        public var tokens: Int64
    }

    public struct SessionDetail: Equatable, Sendable {
        public var project: String = ""
        public var total = ToolStats()
        public var firstTs: Int64?
        public var lastTs: Int64?
        public var models: [ModelRow] = []
        public var observationIntervals: [ObservationInterval] = []
        public var activity: [ActivityEvent] = []
        public var activitySummary: [ActivitySummaryRow] = []
    }

    public func sessionDetail(tool: String, sessionID: String) throws -> SessionDetail {
        let args: [Any?] = [tool, sessionID]
        let times = "MIN(CASE WHEN time_quality!='unallocated' THEN COALESCE(interval_start,ts) END) AS first_ts,"
            + "MAX(CASE WHEN time_quality!='unallocated' THEN ts END) AS last_ts"
        let modelRows = try conn.query(
            "SELECT model,\(UsageStore.aggSelect),\(times) FROM usage_events WHERE tool=? AND session_id=? GROUP BY model ORDER BY tokens DESC",
            args).map { ModelRow(tool: tool, model: $0.string("model"), stats: ToolStats(row: $0)) }
        let totalRow = try conn.queryOne(
            "SELECT COALESCE(MAX(NULLIF(project,'')),'') AS project,\(UsageStore.aggSelect),\(times) FROM usage_events WHERE tool=? AND session_id=?",
            args)
        let intervals = try conn.query(
            "SELECT interval_start,ts,\(UsageStore.tokensExpr) AS tokens FROM usage_events WHERE tool=? AND session_id=? AND time_quality='observed' ORDER BY ts",
            args)
        var detail = SessionDetail()
        detail.project = totalRow?.string("project") ?? ""
        if let totalRow { detail.total = ToolStats(row: totalRow) }
        detail.firstTs = totalRow?.intOrNil("first_ts")
        detail.lastTs = totalRow?.intOrNil("last_ts")
        detail.models = modelRows
        detail.observationIntervals = intervals.map {
            ObservationInterval(intervalStart: $0.intOrNil("interval_start"),
                                ts: $0.int("ts"), tokens: $0.int("tokens"))
        }
        detail.activity = try activityTimeline(agent: tool, sessionID: sessionID, limit: 500)
        detail.activitySummary = try activitySummary(agent: tool, group: "tool", sessionID: sessionID)
        return detail
    }

    public struct SessionRow: Equatable, Sendable {
        public var tool: String
        public var sessionID: String
        public var project: String
        public var lastSeen: String?
        public var ts: Int64?
        public var model: String
        public var title: String?
        public var stats: ToolStats
        public var activityExact: Int64 = 0
        public var activityDerived: Int64 = 0
        public var skills: Int64 = 0
    }

    public func sessions(rangeKey: String = "all", tool: String? = nil,
                         limit: Int = 300, query: String? = nil) throws -> [SessionRow] {
        let (whereSQL, filterArgs) = filter(rangeKey, tool: tool)
        let base = """
            SELECT tool,session_id,MAX(project) AS project,
            datetime(MAX(CASE WHEN time_quality!='unallocated' THEN ts END)/1000,'unixepoch','localtime') AS last_seen,
            MAX(CASE WHEN time_quality!='unallocated' THEN ts END) AS ts,MAX(model) AS model,\(UsageStore.aggSelect)
            FROM usage_events WHERE \(whereSQL) GROUP BY tool,session_id ORDER BY ts DESC
            """
        var sql = "SELECT s.*, m.title FROM (\(base)) s LEFT JOIN session_meta m ON m.tool=s.tool AND m.session_id=s.session_id"
        var args = filterArgs
        if let query, !query.isEmpty {
            sql += " WHERE (m.title LIKE ? OR s.project LIKE ? OR s.session_id LIKE ? OR s.model LIKE ?)"
            args.append(contentsOf: Array(repeating: "%\(query)%" as Any?, count: 4))
        }
        sql += " ORDER BY s.ts DESC LIMIT ?"
        args.append(limit)
        var rows = try conn.query(sql, args).map { row in
            SessionRow(tool: row.string("tool"), sessionID: row.string("session_id"),
                       project: row.string("project"), lastSeen: row.stringOrNil("last_seen"),
                       ts: row.intOrNil("ts"), model: row.string("model"),
                       title: row.stringOrNil("title"), stats: ToolStats(row: row))
        }
        let bounds = rangeBounds(rangeKey)
        let rangeClause = rangeKey == "all" ? "1=1" :
            "COALESCE(started_at,ended_at,0)>=\(bounds.0) AND COALESCE(started_at,ended_at,0)<\(bounds.1)"
        let counts = try conn.query("""
            SELECT agent,session_id,
              SUM(CASE WHEN confidence='exact' THEN 1 ELSE 0 END) AS activity_exact,
              SUM(CASE WHEN confidence='derived' THEN 1 ELSE 0 END) AS activity_derived,
              COUNT(DISTINCT CASE WHEN skill_name!='' THEN skill_name END) AS skills
            FROM agent_activity_events WHERE \(rangeClause) GROUP BY agent,session_id
            """)
        let byKey = Dictionary(uniqueKeysWithValues: counts.map {
            ("\($0.string("agent"))\u{0}\($0.string("session_id"))", $0)
        })
        for index in rows.indices {
            if let count = byKey["\(rows[index].tool)\u{0}\(rows[index].sessionID)"] {
                rows[index].activityExact = count.int("activity_exact")
                rows[index].activityDerived = count.int("activity_derived")
                rows[index].skills = count.int("skills")
            }
        }
        return rows
    }
}

/// UsageStore 的连接以 SQLITE_OPEN_FULLMUTEX 打开（连接级串行化），跨线程安全。
extension UsageStore: @unchecked Sendable {}

/// Python " ".join(text.split())：按空白折叠。
public func collapseWhitespace(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// Python text[:120]：截断到 120 个字符（按 grapheme，标题用途足够）。
public func truncate120(_ text: String) -> String {
    String(text.prefix(120))
}

/// session 标题清洗：折叠空白 + 截断（对齐 set_session_title）。
public func cleanSessionTitle(_ title: String) -> String {
    truncate120(collapseWhitespace(title))
}
