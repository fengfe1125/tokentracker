import Foundation

public struct WeeklyReport: Codable, Sendable, Identifiable {
    public var id: String
    public var generatedAt: Int64
    public var ruleVersion: Int = 1
    public var query: UsageQuery
    public var totals: UsageTotals
    public var previous: UsageTotals
    public var projects: [ProjectSummary]
    public var models: [UsageBreakdown]
    public var costSources: [UsageBreakdown]
    public var budgets: [RiskNotice]
    public var health: [ScanHealth]
    public var activityCount: Int64
    public var markdown: String {
        let change=totals.tokens-previous.tokens
        let formatter=DateFormatter();formatter.timeZone=TimeZone(identifier:query.timeZoneID);formatter.dateFormat="yyyy-MM-dd HH:mm"
        let interval=[query.start,query.end].map { $0.map { formatter.string(from:Date(timeIntervalSince1970:Double($0)/1000)) } ?? "未知" }.joined(separator:" — ")
        return """
        # TokenTracker 本地周报

        范围：\(interval)（左闭右开）

        时区：\(query.timeZoneID) · 规则 v\(ruleVersion) · 生成时间：\(Date(timeIntervalSince1970:Double(generatedAt)/1000).ISO8601Format())

        - Token：\(totals.tokens)（非缓存输入 \(totals.input)、输出 \(totals.output)、缓存读 \(totals.cacheRead)、缓存写 \(totals.cacheWrite)）
        - 费用合计：\(totals.costLabel)（含估算，非订阅账单）
        - 未计价记录：\(totals.unpriced) · 无法归入本周的历史 Token：\(totals.unallocatedTokens)
        - 相比上一自然周：\(change >= 0 ? "+" : "")\(change) Token；覆盖不完整时不解释为实际增长
        - 用量记录：\(totals.records) · 会话：\(totals.sessions) · 执行活动：\(activityCount)

        ## 项目

        \(projects.enumerated().map { "- 项目 \($0.offset+1)：\($0.element.totals.tokens) Token · \($0.element.totals.costLabel)" }.joined(separator:"\n"))

        ## 模型用量

        \(models.map { "- \($0.id)：\($0.totals.tokens) Token · \($0.totals.costLabel)" }.joined(separator:"\n"))

        ## 费用依据

        \(costSources.map { "- \($0.id)：\($0.totals.costLabel) · \($0.totals.records) 条记录" }.joined(separator:"\n"))

        ## 预算

        \(budgets.map { "- \($0.title)：\($0.detail)" }.joined(separator:"\n"))

        ## 生成时数据健康

        \(health.map { "- \($0.id)：\($0.state)" }.joined(separator:"\n"))

        本报告为生成时快照；后续补扫不会自动改写。工具调用成功不代表任务质量。
        """
    }
}

extension UsageStore {
    public func weeklyReports() throws -> [WeeklyReport] {
        try conn.query("SELECT payload FROM weekly_reports ORDER BY generated_at DESC").map {
            try JSONDecoder().decode(WeeklyReport.self,from:Data($0.string("payload").utf8))
        }
    }
    @discardableResult
    public func generateWeeklyReport(now: Date = Date(), timeZone: TimeZone = .current, regenerate: Bool = false) throws -> WeeklyReport {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone;calendar.firstWeekday=2;calendar.minimumDaysInFirstWeek=4
        let end=calendar.dateInterval(of:.weekOfYear,for:now)!.start
        let start=calendar.date(byAdding:.day,value:-7,to:end)!
        let lo=Int64(start.timeIntervalSince1970*1000),hi=Int64(end.timeIntervalSince1970*1000)
        let query=UsageQuery(start:lo,end:hi,timeZoneID:timeZone.identifier)
        let id="\(timeZone.identifier):\(lo)"
        if !regenerate,let row=try conn.queryOne("SELECT payload FROM weekly_reports WHERE id=?",[id]) {
            return try JSONDecoder().decode(WeeklyReport.self,from:Data(row.string("payload").utf8))
        }
        try conn.execute("BEGIN")
        defer { try? conn.rollback() }
        let generatedAt=Int64(Date().timeIntervalSince1970*1000)
        let previousStart=calendar.date(byAdding:.day,value:-7,to:start)!
        let previous=UsageQuery(start:Int64(previousStart.timeIntervalSince1970*1000),end:lo,timeZoneID:timeZone.identifier)
        var projects:[ProjectSummary]=[],offset=0
        while true {
            let page=try projectSummaries(query,limit:1000,offset:offset);projects += page
            if page.count < 1000 { break };offset += page.count
        }
        let report=WeeklyReport(id:id,generatedAt:generatedAt,query:query,
            totals:try usageTotals(query),previous:try usageTotals(previous),projects:projects,
            models:try breakdown(query,dimension:"model"),costSources:try breakdown(query,dimension:"cost_source"),budgets:try budgetRisks(now:end.addingTimeInterval(-0.001),timeZone:timeZone),
            health:try health(now:generatedAt),activityCount:try conn.scalarInt("SELECT COUNT(*) FROM agent_activity_events WHERE started_at>=? AND started_at<? AND event_layer!='request_fallback'",[lo,hi]))
        try conn.rollback() // Persist only after all sections have read the same snapshot.
        let payload=String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
        _ = try conn.execute("INSERT OR REPLACE INTO weekly_reports VALUES (?,?,?)",[id,report.generatedAt,payload])
        _ = try conn.execute("DELETE FROM weekly_reports WHERE id NOT IN (SELECT id FROM weekly_reports ORDER BY generated_at DESC LIMIT 52)")
        try conn.commit();return report
    }
}

public enum ExportKind: String, CaseIterable, Sendable { case usage, sessions, activity, summary, health }
public enum ExportFormat: String, CaseIterable, Sendable { case csv, json }
public final class ExportCancellation: @unchecked Sendable {
    private let lock=NSLock();private var value=false
    public init() {}
    public func cancel() { lock.lock();value=true;lock.unlock() }
    public func check() throws { lock.lock();let cancelled=value;lock.unlock();if cancelled { throw CancellationError() } }
}
public enum InsightExporter {
    public static func csvField(_ value: String) -> String {
        let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines)
        let safe = trimmed.first.map { "=+-@".contains($0) } == true || value.first == "\t" || value.first == "\r" ? "'"+value : value
        return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""
    }
    public static func export(store: UsageStore, query: UsageQuery, kind: ExportKind, format: ExportFormat,
                              destination: URL, includePrivate: Bool = false, cancellation: ExportCancellation = ExportCancellation()) throws {
        if kind == .activity,query.model != nil { throw SQLiteError(message:"Activity has no reliable per-model attribution") }
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".tt-export-"+UUID().uuidString)
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw SQLiteError(message:"无法创建导出文件") }
        defer { try? FileManager.default.removeItem(at:temporary) }
        let handle=try FileHandle(forWritingTo:temporary);defer { try? handle.close() }
        func write(_ text:String) throws { try cancellation.check();try handle.write(contentsOf:Data(text.utf8)) }
        var aliases:[String:String]=[:]
        func alias(_ type:String,_ value:String) -> String {
            if value.isEmpty { return "" };let key=type+":"+value
            if let existing=aliases[key] { return existing }
            let name="\(type) \(aliases.keys.filter{$0.hasPrefix(type+":")}.count+1)";aliases[key]=name;return name
        }
        var first=true,headers:[String]=[]
        if format == .json {
            // Filters are represented without leaking project IDs (which may contain paths).
            let metadata:[String:Any] = ["version":1,"kind":kind.rawValue,"timeZone":query.timeZoneID,
                "start":query.start as Any? ?? NSNull(),"end":query.end as Any? ?? NSNull(),
                "projectFiltered":query.projectID != nil,"tool":query.tool ?? "all",
                "metrics":"Token=input+output+cache_read+cache_write; cost includes estimates, not subscription bill"]
            let encoded=String(decoding:try JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys),as:UTF8.self)
            try write("{\"metadata\":\(encoded),\"rows\":[")
        }
        func emit(_ row: Row) throws {
            var object:[String:Any]=[:]
            for (key,value) in row.values {
                var v:Any=value ?? NSNull()
                if ["project","session_id","raw_name","canonical_name","skill_name","call_id","parent_call_id","turn_id"].contains(key),let str=value as? String {
                    v=includePrivate && ["project","session_id"].contains(key) ? str : alias(key,str)
                }
                if ["path","title"].contains(key),!includePrivate { continue }
                object[key]=v
            }
            if format == .json {
                let text=String(decoding:try JSONSerialization.data(withJSONObject:object,options:.sortedKeys),as:UTF8.self)
                try write((first ? "" : ",")+text)
            } else {
                if first { headers=object.keys.sorted();try write(headers.map(csvField).joined(separator:",")+"\n") }
                try write(headers.map { key in csvField(object[key].map { $0 is NSNull ? "" : String(describing:$0) } ?? "") }.joined(separator:",")+"\n")
            }
            first=false
        }
        try store.conn.execute("BEGIN")
        defer { try? store.conn.rollback() }
        let (filter,args)=store.insightFilter(query)
        if kind == .summary {
            let totals=try store.usageTotals(query)
            let dict=try JSONSerialization.jsonObject(with:JSONEncoder().encode(totals)) as! [String:Any]
            try emit(Row(values:dict.mapValues{Optional($0)}))
        } else if kind == .health {
            for health in try store.health(now:store.nowMs()) {
                let dict=try JSONSerialization.jsonObject(with:JSONEncoder().encode(health)) as! [String:Any]
                try emit(Row(values:dict.mapValues{Optional($0)}))
            }
        } else {
            var offset=0
            while true {
                try cancellation.check()
                let sql:String,parameters:[Any?]
                if kind == .activity {
                    var clauses=["1"],params:[Any?]=[]
                    if let start=query.start,let end=query.end { clauses.append("COALESCE(a.started_at,a.ended_at)>=? AND COALESCE(a.started_at,a.ended_at)<?");params += [start,end] }
                    if let tool=query.tool { clauses.append("a.agent=?");params.append(tool) }
                    if query.projectID != nil { clauses.append("EXISTS(SELECT 1 \(UsageStore.insightJoin) WHERE u.tool=a.agent AND u.session_id=a.session_id AND \(filter))");params += args }
                    sql="SELECT a.agent,a.session_id,a.raw_name,a.canonical_name,a.skill_name,a.call_id,a.parent_call_id,a.turn_id,a.started_at,a.ended_at,a.duration_ms,a.status,a.confidence,a.event_kind,a.event_layer FROM agent_activity_events a WHERE \(clauses.joined(separator:" AND ")) ORDER BY a.id LIMIT 500 OFFSET ?"
                    parameters=params+[offset]
                } else if kind == .sessions {
                    sql="SELECT u.tool,u.session_id,MAX(meta.title) title,\(UsageStore.insightAggregate) \(UsageStore.insightJoin) LEFT JOIN session_meta meta ON meta.tool=u.tool AND meta.session_id=u.session_id WHERE \(filter) GROUP BY u.tool,u.session_id ORDER BY u.tool,u.session_id LIMIT 500 OFFSET ?";parameters=args+[offset]
                } else {
                    sql="SELECT u.tool,u.session_id,\(UsageStore.resolvedProject) project,pp.path,meta.title,u.ts,u.model,u.input,u.output,u.cache_read,u.cache_write,u.cost,u.cost_source,u.time_quality,u.interval_start \(UsageStore.insightJoin) LEFT JOIN session_meta meta ON meta.tool=u.tool AND meta.session_id=u.session_id WHERE \(filter) ORDER BY u.id LIMIT 500 OFFSET ?";parameters=args+[offset]
                }
                let rows=try store.conn.query(sql,parameters)
                for row in rows { try cancellation.check();try emit(row) }
                if rows.count < 500 { break };offset += rows.count
            }
        }
        if format == .json { try write("]}") }
        try handle.synchronize();try cancellation.check()
        guard rename(temporary.path,destination.path) == 0 else { throw SQLiteError(message:"无法保存导出文件") }
    }
}
