import Foundation

public struct BudgetRule: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var projectID: String?
    public var unit: String
    public var period: String
    public var limit: Double
    public init(id: String = UUID().uuidString, projectID: String? = nil, unit: String = "tokens", period: String = "month", limit: Double) {
        self.id=id; self.projectID=projectID; self.unit=unit; self.period=period; self.limit=limit
    }
    public var valid: Bool { ["tokens","usd"].contains(unit) && ["day","calendarWeek","month"].contains(period) && limit.isFinite && limit > 0 }
}
public struct RiskNotice: Identifiable, Sendable, Codable {
    public var id: String, cycle: String, title: String, detail: String
    public var projectID: String?
    public var level: Int
    public var pct: Double
    public var incomplete: Bool
}
public struct QuotaSample: Sendable {
    public var identity: String, at: Int64, pct: Double, resetsAt: Int64
    public init(identity: String, at: Int64, pct: Double, resetsAt: Int64) {
        self.identity=identity;self.at=at;self.pct=pct;self.resetsAt=resetsAt
    }
}
public struct ChangeContribution: Codable, Sendable, Identifiable {
    public var dimension: String, name: String
    public var key: String? = nil
    public var current: Double, baseline: Double
    public var id: String { dimension + ":" + (key ?? name) }
    public var delta: Double { current - baseline }
}
public struct ConsumptionExplanation: Codable, Sendable {
    public var status: String, detail: String
    public var current: Int64, baseline: Double, samples: Int
    public var anomaly: Bool
    public var contributions: [UsageBreakdown]
    public var changes: [ChangeContribution]
    public var context: [String]
}

extension UsageStore {
    public func budgets() throws -> [BudgetRule] {
        try conn.query("SELECT payload FROM budgets ORDER BY id").map {
            try JSONDecoder().decode(BudgetRule.self,from:Data($0.string("payload").utf8))
        }
    }
    public func saveBudget(_ budget: BudgetRule) throws {
        guard budget.valid else { throw SQLiteError(message:"预算必须为正数，且单位和周期有效") }
        let payload = String(decoding:try JSONEncoder().encode(budget),as:UTF8.self)
        _ = try conn.execute("INSERT OR REPLACE INTO budgets VALUES (?,?)",[budget.id,payload]);try conn.commit()
    }
    public func deleteBudget(_ id: String) throws {
        _ = try conn.execute("DELETE FROM budgets WHERE id=?",[id]);try conn.commit()
    }
    public func budgetRisks(now: Date = Date(), timeZone: TimeZone = .current) throws -> [RiskNotice] {
        try budgets().map { rule in
            var query = UsageQuery.period(rule.period,now:now,timeZone:timeZone);query.projectID=rule.projectID
            let totals = try usageTotals(query)
            let value = rule.unit == "tokens" ? Double(totals.tokens) : totals.cost
            let pct = value/rule.limit*100
            let level = pct >= 100 ? 100 : pct >= 90 ? 90 : pct >= 80 ? 80 : 0
            let incomplete = totals.unallocatedTokens > 0 || (rule.unit == "usd" && totals.unpriced > 0)
            return RiskNotice(id:"budget:"+rule.id,cycle:String(query.start ?? 0),title:rule.projectID == nil ? "全局预算" : "项目预算",
                detail:(["day":"自然日","calendarWeek":"自然周","month":"自然月"][rule.period] ?? rule.period) + " · " + String(format:"%.1f%% · %@%@",pct,rule.unit == "tokens" ? "Token" : "估算美元，非订阅账单",incomplete ? " · 统计不完整" : ""),projectID:rule.projectID,level:level,pct:pct,incomplete:incomplete)
        }
    }
    public func recordQuota(_ sample: QuotaSample) throws {
        guard sample.pct.isFinite, sample.pct >= 0, sample.pct <= 100, (sample.resetsAt == 0 || sample.resetsAt > sample.at) else { return }
        if let last = try conn.queryOne("SELECT * FROM quota_samples WHERE identity=? ORDER BY at DESC LIMIT 1",[sample.identity]),
           last.int("resets_at") != sample.resetsAt || sample.pct < last.double("pct") {
            _ = try conn.execute("DELETE FROM quota_samples WHERE identity=?",[sample.identity])
        }
        _ = try conn.execute("INSERT OR IGNORE INTO quota_samples VALUES (?,?,?,?)",[sample.identity,sample.at,sample.pct,sample.resetsAt])
        _ = try conn.execute("DELETE FROM quota_samples WHERE at<?",[sample.at-14*86400000]);try conn.commit()
    }
    public func quotaRisks(now: Int64, codexAccountID: String? = nil) throws -> [RiskNotice] {
        let rows = try conn.query("SELECT DISTINCT identity FROM quota_samples WHERE at>=?",[now-300000])
        return try rows.compactMap { identity in
            let id=identity.string("identity")
            if let account=codexAccountID, id.hasPrefix("codex:"), !id.hasPrefix("codex:"+account+":") { return nil }
            let samples = try conn.query("SELECT * FROM quota_samples WHERE identity=? AND at>=? ORDER BY at",[id,now-3600000])
            guard let first=samples.first,let last=samples.last, last.int("at") <= now, (last.int("resets_at") == 0 || last.int("resets_at") > now) else { return nil }
            let pct=last.double("pct"),level=pct >= 100 ? 100 : pct >= 90 ? 90 : pct >= 80 ? 80 : 0
            var detail=String(format:"官方用量 %.1f%%",pct),prediction=false
            let span=last.int("at")-first.int("at"),delta=pct-first.double("pct")
            if last.int("resets_at") > now,samples.count >= 4,span >= 900000,delta > 0 {
                let remaining=Double(span)*(100-pct)/delta
                if Double(now)+remaining < Double(last.int("resets_at")) {
                    prediction=true;detail += String(format:" · 按近期速度估算，约 %.0f 分钟后耗尽",remaining/60000)
                }
            }
            return RiskNotice(id:"quota:"+id,cycle:String(last.int("resets_at")),title:"官方配额",detail:detail,
                projectID:nil,level:level > 0 ? level : prediction ? 1 : 0,pct:pct,incomplete:false)
        }
    }
    public func shouldNotify(_ risk: RiskNotice, now: Int64) throws -> Bool {
        guard risk.level > 0 else { return false }
        let rows=try conn.query("SELECT level,at FROM alert_deliveries WHERE identity=? AND cycle=?",[risk.id,risk.cycle])
        if rows.contains(where: { Int($0.int("level")) >= risk.level }) { return false }
        if risk.level != 100,let last=rows.map({$0.int("at")}).max(),now-last < 3600000 { return false }
        return true
    }
    public func markNotified(_ risk: RiskNotice, now: Int64) throws {
        _ = try conn.execute("INSERT OR REPLACE INTO alert_deliveries VALUES (?,?,?,?)",[risk.id,risk.cycle,risk.level,now]);try conn.commit()
    }
    public func consumptionExplanation(now: Date = Date(), projectID: String? = nil, timeZone: TimeZone = .current, cancellation: ExportCancellation? = nil) throws -> ConsumptionExplanation {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        var query=UsageQuery.period("day",now:now,timeZone:timeZone);query.projectID=projectID
        let current=try usageTotals(query)
        var values:[Double]=[]
        var histories:[UsageQuery]=[]
        var cacheRatios:[Double]=[]
        var historicalCosts:[Double]=[]
        let costSources=Set(try breakdown(query,dimension:"cost_source").map(\.id))
        var costsComparable=current.unpriced == 0 && !costSources.contains("legacy") && !costSources.contains("recomputed")
        let start=calendar.startOfDay(for:now)
        let elapsed=calendar.dateComponents([.hour,.minute,.second],from:start,to:now)
        let currentTools=Set(try breakdown(query,dimension:"tool").map(\.id))
        var coverageChanged=false
        for day in 1...14 {
            try cancellation?.check()
            guard let historicalStart=calendar.date(byAdding:.day,value:-day,to:start),
                  let historicalEnd=calendar.date(byAdding:elapsed,to:historicalStart) else { continue }
            var sample=UsageQuery(start:Int64(historicalStart.timeIntervalSince1970*1000),end:Int64(historicalEnd.timeIntervalSince1970*1000)+1,timeZoneID:timeZone.identifier,projectID:projectID)
            sample.tool=query.tool
            let totals=try usageTotals(sample)
            if totals.records > 0, totals.unallocatedTokens == 0 {
                values.append(Double(totals.tokens));histories.append(sample)
                historicalCosts.append(totals.cost)
                let sampleSources=Set(try breakdown(sample,dimension:"cost_source").map(\.id))
                costsComparable = costsComparable && totals.unpriced == 0 && sampleSources == costSources
                let inputs=totals.input+totals.cacheRead+totals.cacheWrite
                if inputs>0 { cacheRatios.append(Double(totals.cacheRead)/Double(inputs)) }
                let tools=Set(try breakdown(sample,dimension:"tool").map(\.id))
                if !currentTools.isSubset(of:tools) { coverageChanged=true }
            }
        }
        let baseline=InsightMath.median(values),mad=InsightMath.median(values.map{abs($0-baseline)})
        let anomaly=values.count >= 7 && !coverageChanged && current.unallocatedTokens == 0 && Double(current.tokens)>2*baseline && Double(current.tokens)-baseline>3*mad
        let status=current.unallocatedTokens > 0 || coverageChanged ? "来源变化或数据不完整" : values.count < 7 ? "历史样本不足" : baseline == 0 ? "新增用量" : anomaly ? "消耗显著增加" : "消耗变化"
        let detail="与过去 14 天相同时刻比较，有效样本 \(values.count) 天；中位数 \(Int64(baseline)) Token，今天 \(current.tokens) Token。高消耗不代表浪费。"
        var changes:[ChangeContribution]=[]
        for dimension in ["project","tool","model"] {
            let currentRows=try breakdown(query,dimension:dimension)
            var sums:[String:Double]=[:],currentValues:[String:Double]=[:]
            for row in currentRows { currentValues[row.id]=Double(row.totals.tokens) }
            for historical in histories {
                try cancellation?.check()
                for row in try breakdown(historical,dimension:dimension) { sums[row.id,default:0] += Double(row.totals.tokens) }
            }
            let keys=Set(currentValues.keys).union(sums.keys)
            changes += keys.map { ChangeContribution(dimension:dimension,name:$0,current:currentValues[$0] ?? 0,baseline:(sums[$0] ?? 0)/Double(max(histories.count,1))) }
        }
        for index in changes.indices where changes[index].dimension == "project" {
            let key=changes[index].name
            changes[index].key=key
            changes[index].name = try conn.queryOne("SELECT name FROM projects WHERE id=?",[key])?.string("name") ?? "未归属"
        }
        var context=["变化贡献按有效历史日的平均值分解；异常检测使用中位数。各维度独立，不能相加。"]
        let inputs=current.input+current.cacheRead+current.cacheWrite
        if inputs>0,!cacheRatios.isEmpty,Double(current.cacheRead)/Double(inputs)<InsightMath.median(cacheRatios) {
            context.append("缓存读取占输入比例低于历史中位数；这是同时出现的变化，不能单独证明费用上涨原因。")
        }
        let costBaseline=InsightMath.median(historicalCosts),costMAD=InsightMath.median(historicalCosts.map{abs($0-costBaseline)})
        if costsComparable,!coverageChanged,values.count>=7,current.cost>2*costBaseline,current.cost-costBaseline>3*costMAD {
            context.append("相同来源口径的记录费用显著增加；历史单价未版本化，金额含估算，非订阅账单。")
        }
        return ConsumptionExplanation(status:status,detail:detail,current:current.tokens,baseline:baseline,samples:values.count,anomaly:anomaly,contributions:try breakdown(query,dimension:"model"),changes:changes.sorted{abs($0.delta)>abs($1.delta)},context:context)
    }
}
public enum InsightMath {
    public static func median(_ values:[Double]) -> Double {
        guard !values.isEmpty else { return 0 };let sorted=values.sorted(),mid=values.count/2
        return values.count % 2 == 0 ? (sorted[mid-1]+sorted[mid])/2 : sorted[mid]
    }
}
