import Foundation

public struct UsageQuery: Sendable, Equatable, Codable {
    public var start: Int64?
    public var end: Int64?
    public var timeZoneID: String
    public var model: String? = nil
    public var tool: String?
    public var projectID: String?
    public init(start: Int64? = nil, end: Int64? = nil, timeZoneID: String = TimeZone.current.identifier,
                tool: String? = nil, projectID: String? = nil) {
        self.start = start; self.end = end; self.timeZoneID = timeZoneID
        self.tool = tool; self.projectID = projectID
    }
    public static func period(_ key: String, now: Date = Date(), timeZone: TimeZone = .current) -> UsageQuery {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; calendar.firstWeekday = 2
        let day = calendar.startOfDay(for: now)
        let start: Date?
        switch key {
        case "day": start = day
        case "week": start = calendar.date(byAdding: .day, value: -6, to: day)
        case "calendarWeek": start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case "month": start = calendar.dateInterval(of: .month, for: now)?.start
        default: start = nil
        }
        return UsageQuery(start: start.map { Int64($0.timeIntervalSince1970 * 1000) },
                          end: start == nil ? nil : Int64(now.timeIntervalSince1970 * 1000) + 1,
                          timeZoneID: timeZone.identifier)
    }
}

public struct UsageTotals: Codable, Sendable, Equatable {
    public var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0
    public var records: Int64 = 0, sessions: Int64 = 0, unpriced: Int64 = 0, estimatedTokens: Int64 = 0
    public var cost: Double = 0
    public var unallocatedTokens: Int64 = 0
    public var unallocatedCost: Double = 0
    public var tokens: Int64 { input + output + cacheRead + cacheWrite }
    public var costLabel: String { records == 0 ? "—" : unpriced == records ? "未计价" : String(format: "$%.4f", cost) }
    public init() {}
    init(_ row: Row) {
        input = row.int("input"); output = row.int("output"); cacheRead = row.int("cache_read")
        cacheWrite = row.int("cache_write"); records = row.int("records"); sessions = row.int("sessions")
        unpriced = row.int("unpriced"); cost = row.double("cost"); estimatedTokens = row.int("estimated_tokens")
    }
}

public struct ProjectSummary: Identifiable, Sendable, Codable {
    public var id: String, name: String
    public var totals: UsageTotals
    public var lastActivity: Int64?
    public init(id:String,name:String,totals:UsageTotals,lastActivity:Int64?) { self.id=id;self.name=name;self.totals=totals;self.lastActivity=lastActivity }
}
public struct UsageBreakdown: Identifiable, Sendable, Codable {
    public var id: String
    public var totals: UsageTotals
}
public struct ScanHealth: Identifiable, Sendable, Codable {
    public var id: String, state: String
    public var attemptedAt: Int64, succeededAt: Int64?
    public var duration: Double
    public var files: Int, added: Int, updated: Int
    public var error: String, parserVersion: Int
    public var parseErrors: Int?, readErrors: Int?
}

extension UsageStore {
    public static let insightsSchema = """
    CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,name TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS project_paths(path TEXT PRIMARY KEY,automatic_id TEXT NOT NULL,manual_id TEXT);
    CREATE TABLE IF NOT EXISTS project_sources(tool TEXT NOT NULL,src_key TEXT NOT NULL,path TEXT NOT NULL,PRIMARY KEY(tool,src_key));
    CREATE TABLE IF NOT EXISTS project_sessions(tool TEXT NOT NULL,session_id TEXT NOT NULL,project_id TEXT NOT NULL,PRIMARY KEY(tool,session_id));
    CREATE TABLE IF NOT EXISTS insight_state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS scan_health(tool TEXT PRIMARY KEY,state TEXT NOT NULL,attempted_at INTEGER NOT NULL,succeeded_at INTEGER,duration REAL NOT NULL,files INTEGER NOT NULL,added INTEGER NOT NULL,updated INTEGER NOT NULL,error TEXT NOT NULL,parser_version INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS scan_diagnostics(tool TEXT PRIMARY KEY,parse_errors INTEGER,read_errors INTEGER);
    CREATE TABLE IF NOT EXISTS scan_health_history(id INTEGER PRIMARY KEY,tool TEXT NOT NULL,at INTEGER NOT NULL,state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS budgets(id TEXT PRIMARY KEY,payload TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS quota_samples(identity TEXT NOT NULL,at INTEGER NOT NULL,pct REAL NOT NULL,resets_at INTEGER NOT NULL,PRIMARY KEY(identity,at));
    CREATE TABLE IF NOT EXISTS alert_deliveries(identity TEXT NOT NULL,cycle TEXT NOT NULL,level INTEGER NOT NULL,at INTEGER NOT NULL,PRIMARY KEY(identity,cycle,level));
    CREATE TABLE IF NOT EXISTS weekly_reports(id TEXT PRIMARY KEY,generated_at INTEGER NOT NULL,payload TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_project_sources_path ON project_sources(path);
    CREATE INDEX IF NOT EXISTS idx_project_paths_auto ON project_paths(automatic_id);
    CREATE INDEX IF NOT EXISTS idx_insight_session ON usage_events(tool,session_id);
    CREATE INDEX IF NOT EXISTS idx_health_history_time ON scan_health_history(at);
    """
    static let insightJoin = """
    FROM usage_events u
    LEFT JOIN project_sources ps ON ps.tool=u.tool AND ps.src_key=u.src_key
    LEFT JOIN project_paths pp ON pp.path=ps.path
    LEFT JOIN project_sessions sm ON sm.tool=u.tool AND sm.session_id=u.session_id
    """
    static let resolvedProject = "COALESCE(sm.project_id,pp.manual_id,pp.automatic_id,'unassigned')"
    static let insightAggregate = """
    COALESCE(SUM(u.input),0) input,COALESCE(SUM(u.output),0) output,
    COALESCE(SUM(u.cache_read),0) cache_read,COALESCE(SUM(u.cache_write),0) cache_write,
    COUNT(*) records,COUNT(DISTINCT u.tool || char(0) || u.session_id) sessions,
    SUM(CASE WHEN u.cost IS NULL THEN 1 ELSE 0 END) unpriced,COALESCE(SUM(u.cost),0) cost,
    COALESCE(SUM(CASE WHEN u.time_quality='observed' THEN u.input+u.output+u.cache_read+u.cache_write ELSE 0 END),0) estimated_tokens
    """
    func insightFilter(_ query: UsageQuery, excluded: Bool = false) -> (String, [Any?]) {
        var terms: [String] = [], args: [Any?] = []
        if let start = query.start, let end = query.end {
            let inRange = "((u.time_quality='exact' OR (u.time_quality='observed' AND u.interval_start>=?)) AND u.ts>=? AND u.ts<?)"
            if excluded {
                terms.append("(u.time_quality='unallocated' OR (u.time_quality='observed' AND u.interval_start<? AND u.ts>=? AND NOT \(inRange)))")
                args += [end,start,start,start,end]
            } else { terms.append(inRange);args += [start,start,end] }
        } else if excluded { terms.append("0") }
        if let model = query.model { terms.append("u.model=?"); args.append(model) }
        if let tool = query.tool { terms.append("u.tool=?"); args.append(tool) }
        if let project = query.projectID { terms.append("\(Self.resolvedProject)=?"); args.append(project) }
        return (terms.isEmpty ? "1" : terms.joined(separator: " AND "), args)
    }
    public func usageTotals(_ query: UsageQuery) throws -> UsageTotals {
        let joins = query.projectID == nil ? "FROM usage_events u" : Self.insightJoin
        let (filter,args) = insightFilter(query)
        let row = try conn.queryOne("SELECT \(Self.insightAggregate) \(joins) WHERE \(filter)", args)!
        var totals = UsageTotals(row)
        let (excluded,excludedArgs) = insightFilter(query, excluded: true)
        let extra = try conn.queryOne("SELECT COALESCE(SUM(u.input+u.output+u.cache_read+u.cache_write),0) tokens,COALESCE(SUM(u.cost),0) cost \(joins) WHERE \(excluded)",excludedArgs)
        totals.unallocatedTokens = extra?.int("tokens") ?? 0; totals.unallocatedCost = extra?.double("cost") ?? 0
        return totals
    }
    public func projectSummaries(_ query: UsageQuery, search: String = "", limit: Int = 100, offset: Int = 0) throws -> [ProjectSummary] {
        let (filter,args) = insightFilter(query)
        return try conn.query("""
        SELECT * FROM (SELECT \(Self.resolvedProject) id,COALESCE(p.name,'未归属') name,
        \(Self.insightAggregate),MAX(CASE WHEN u.time_quality!='unallocated' THEN u.ts END) last_activity
        \(Self.insightJoin) LEFT JOIN projects p ON p.id=\(Self.resolvedProject)
        WHERE \(filter) GROUP BY \(Self.resolvedProject)) WHERE name LIKE ?
        ORDER BY input+output+cache_read+cache_write DESC,id LIMIT ? OFFSET ?
        """,args + ["%\(search)%",max(1,min(limit,1000)),max(0,offset)]).map {
            ProjectSummary(id: $0.string("id"), name: $0.string("name"), totals: UsageTotals($0), lastActivity: $0.intOrNil("last_activity"))
        }
    }
    public func breakdown(_ query: UsageQuery, dimension: String) throws -> [UsageBreakdown] {
        let expressions = ["tool":"u.tool","model":"u.model","cost_source":"u.cost_source","session":"u.tool || char(0) || u.session_id","project":Self.resolvedProject,"day":"date(u.ts/1000,'unixepoch','localtime')"]
        guard let expr = expressions[dimension] else { throw SQLiteError(message: "Unsupported dimension") }
        let joins = query.projectID == nil && dimension != "project" ? "FROM usage_events u" : Self.insightJoin
        let (filter,args) = insightFilter(query)
        return try conn.query("SELECT \(expr) id,\(Self.insightAggregate) \(joins) WHERE \(filter) GROUP BY \(expr) ORDER BY SUM(u.input+u.output+u.cache_read+u.cache_write) DESC",args).map { UsageBreakdown(id:$0.string("id"),totals:UsageTotals($0)) }
    }
    public func recordProjectPath(tool: String, srcKey: String, path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { return }
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        _ = try conn.execute("INSERT OR REPLACE INTO project_sources(tool,src_key,path) VALUES (?,?,?)",[tool,srcKey,path])
        if try conn.queryOne("SELECT path FROM project_paths WHERE path=?",[path]) == nil {
            // Git resolution happens in a separate metadata pass, not in the scanner transaction.
            let common = ProjectResolver.gitCommonDirectory(path)
            let id = common.map { "git:" + $0 } ?? ("directory:" + path)
            _ = try conn.execute("INSERT OR IGNORE INTO projects(id,name) VALUES (?,?)",[id,common.map { URL(fileURLWithPath:$0).deletingLastPathComponent().lastPathComponent } ?? URL(fileURLWithPath:path).lastPathComponent])
            _ = try conn.execute("INSERT OR IGNORE INTO project_paths(path,automatic_id) VALUES (?,?)",[path,id])
        }
    }
    public func resolveProjectRepositories() throws {
        // Each newly discovered path is resolved once by recordProjectPath.
        // Existing IDs remain stable for budgets and manually named projects.
    }
    public func renameProject(_ id: String, name: String) throws {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, id != "unassigned" else { throw SQLiteError(message:"项目名称无效") }
        _ = try conn.execute("UPDATE projects SET name=? WHERE id=?",[name,id]); try conn.commit()
    }
    public func assignDirectory(_ path: String, projectID: String?) throws {
        let normalized=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path
        if let projectID,try conn.queryOne("SELECT id FROM projects WHERE id=?",[projectID]) == nil { throw SQLiteError(message:"项目不存在") }
        guard try conn.queryOne("SELECT path FROM project_paths WHERE path=?",[normalized]) != nil else { throw SQLiteError(message:"没有此工作目录的用量记录") }
        _ = try conn.execute("UPDATE project_paths SET manual_id=? WHERE path=?",[projectID as Any,normalized]); try conn.commit()
    }
    public func assignSession(tool: String, sessionID: String, projectID: String?) throws {
        if let projectID {
            guard try conn.queryOne("SELECT id FROM projects WHERE id=?",[projectID]) != nil, try conn.queryOne("SELECT id FROM usage_events WHERE tool=? AND session_id=? LIMIT 1",[tool,sessionID]) != nil else { throw SQLiteError(message:"项目或会话不存在") }
            _ = try conn.execute("INSERT OR REPLACE INTO project_sessions VALUES (?,?,?)",[tool,sessionID,projectID])
        } else { _ = try conn.execute("DELETE FROM project_sessions WHERE tool=? AND session_id=?",[tool,sessionID]) }
        try conn.commit()
    }
    public func recordHealth(tool: String, outcome: ScanOutcome, started: Int64, finished: Int64) throws {
        let diagnostics = ScanDiagnostics.current
        let issues = (diagnostics?.parseErrors ?? 0) + (diagnostics?.readErrors ?? 0)
        let state = outcome.skipped != nil ? "未发现" : outcome.error != nil ? "失败" : outcome.warning != nil || issues > 0 ? "部分异常" : "正常"
        let success: Int64? = outcome.skipped == nil && outcome.error == nil ? finished : nil
        _ = try conn.execute("""
        INSERT INTO scan_health VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(tool) DO UPDATE SET
        state=excluded.state,attempted_at=excluded.attempted_at,succeeded_at=COALESCE(excluded.succeeded_at,scan_health.succeeded_at),duration=excluded.duration,files=excluded.files,added=excluded.added,updated=excluded.updated,error=excluded.error,parser_version=excluded.parser_version
        """,[tool,state,started,success as Any,Double(finished-started)/1000,outcome.files,outcome.added,outcome.updated,
              outcome.error != nil ? "读取或解析失败；请重新扫描" : outcome.warning != nil ? "来源存在警告" : "",ActivityNormalizer.parserVersion])
        _ = try conn.execute("INSERT OR REPLACE INTO scan_diagnostics VALUES (?,?,?)",[tool,diagnostics?.parseErrors as Any,diagnostics?.readErrors as Any])
        _ = try conn.execute("INSERT INTO scan_health_history(tool,at,state) VALUES (?,?,?)",[tool,finished,state])
        _ = try conn.execute("DELETE FROM scan_health_history WHERE at<?",[finished-30*86400000]); try conn.commit()
    }
    public func health(now: Int64, interval: Int = 60) throws -> [ScanHealth] {
        try conn.query("SELECT h.*,d.parse_errors,d.read_errors FROM scan_health h LEFT JOIN scan_diagnostics d ON d.tool=h.tool ORDER BY h.tool").map { row in
            let success = row.intOrNil("succeeded_at")
            let stale = row.string("state") == "正常" && now-(success ?? 0) > Int64(max(interval*3,300))*1000
            return ScanHealth(id:row.string("tool"),state:stale ? "过期" : row.string("state"),attemptedAt:row.int("attempted_at"),succeededAt:success,duration:row.double("duration"),files:Int(row.int("files")),added:Int(row.int("added")),updated:Int(row.int("updated")),error:row.string("error"),parserVersion:Int(row.int("parser_version")),parseErrors:row.intOrNil("parse_errors").map(Int.init),readErrors:row.intOrNil("read_errors").map(Int.init))
        }
    }
}

public enum ProjectResolver {
    public static func gitCommonDirectory(_ path: String) -> String? {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/git")
        process.arguments = ["--no-optional-locks","-C",path,"rev-parse","--path-format=absolute","--git-common-dir"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let value = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines), value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath:value).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct UsageSessionSummary: Identifiable, Sendable {
    public var tool:String, sessionID:String, title:String
    public var totals:UsageTotals
    public var id:String { tool+"\0"+sessionID }
}
extension UsageStore {
    public func projectSessions(_ query:UsageQuery,limit:Int=100,offset:Int=0) throws -> [UsageSessionSummary] {
        let (filter,args)=insightFilter(query)
        return try conn.query("""
        SELECT u.tool,u.session_id,COALESCE(MAX(meta.title),'') title,\(Self.insightAggregate)
        \(Self.insightJoin) LEFT JOIN session_meta meta ON meta.tool=u.tool AND meta.session_id=u.session_id
        WHERE \(filter) GROUP BY u.tool,u.session_id ORDER BY SUM(u.input+u.output+u.cache_read+u.cache_write) DESC,u.tool,u.session_id LIMIT ? OFFSET ?
        """,args+[max(1,min(limit,1000)),max(0,offset)]).map {
            UsageSessionSummary(tool:$0.string("tool"),sessionID:$0.string("session_id"),title:$0.string("title"),totals:UsageTotals($0))
        }
    }
    public func dailyBreakdown(_ query:UsageQuery,cancellation:ExportCancellation? = nil) throws -> [UsageBreakdown] {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:query.timeZoneID) ?? .current
        let earliest=try conn.scalarInt("SELECT COALESCE(MIN(ts),0) FROM usage_events WHERE time_quality!='unallocated'")
        guard earliest>0 else { return [] }
        let end=query.end ?? nowMs(),start=query.start ?? earliest
        var day=calendar.startOfDay(for:Date(timeIntervalSince1970:Double(start)/1000)),rows:[UsageBreakdown]=[]
        let formatter=DateFormatter();formatter.calendar=calendar;formatter.timeZone=calendar.timeZone;formatter.dateFormat="yyyy-MM-dd"
        while Int64(day.timeIntervalSince1970*1000)<end {
            try cancellation?.check()
            let next=calendar.date(byAdding:.day,value:1,to:day)!
            var interval=query;interval.start=max(start,Int64(day.timeIntervalSince1970*1000));interval.end=min(end,Int64(next.timeIntervalSince1970*1000))
            rows.append(UsageBreakdown(id:formatter.string(from:day),totals:try usageTotals(interval)));day=next
        }
        return rows
    }
}

public struct ProjectIdentity: Sendable, Identifiable {
    public var id:String,name:String
}
extension UsageStore {
    public func projectRegistry() throws -> [ProjectIdentity] {
        try conn.query("SELECT id,name FROM projects ORDER BY name,id").map{ProjectIdentity(id:$0.string("id"),name:$0.string("name"))}
    }
    public func createProject(id:String,name:String) throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=200,id != "unassigned" else { throw SQLiteError(message:"项目名称无效") }
        _ = try conn.execute("INSERT INTO projects(id,name) VALUES (?,?)",[id,name]);try conn.commit()
    }
}
