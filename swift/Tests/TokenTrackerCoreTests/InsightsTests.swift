import XCTest
@testable import TokenTrackerCore

final class InsightsTests: XCTestCase {
    func testHealthPersistenceAndParserDiagnostics() throws {
        let store=try UsageStore(path:":memory:")
        ScanDiagnostics.begin()
        _ = parseJSONLine(Data("broken".utf8))
        try store.recordHealth(tool:"codex",outcome:ScanOutcome(),started:1000,finished:2000)
        let health=try store.health(now:2000)
        XCTAssertEqual(health.first?.state,"部分异常")
        XCTAssertEqual(health.first?.parseErrors,1)
        XCTAssertEqual(health.first?.succeededAt,2000)
        ScanDiagnostics.begin()
        try store.recordHealth(tool:"codex",outcome:ScanOutcome(),started:3000,finished:4000)
        XCTAssertEqual(try store.health(now:400000).first?.state,"过期")
    }
    func testAccountWriteStagesPreserveOldFileBeforeReplacement() throws {
        let temp=try TempDir(),path=temp.path("auth.json")
        try writeAccountJSON(path,["version":"old"])
        let original=try Data(contentsOf:URL(fileURLWithPath:path))
        for stage in [AccountWriteStage.encode,.create,.permissions,.replace] {
            XCTAssertThrowsError(try writeAccountJSON(path,["version":"new"],beforeStep:{ if $0 == stage { throw AccountPersistenceError.create } }))
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),original)
        }
        XCTAssertThrowsError(try writeAccountJSON(path,["version":"new"],beforeStep:{ if $0 == .verify { throw AccountPersistenceError.verify } }))
    }
    func testGitWorktreeGroupingAndStableDirectoryIdentity() throws {
        let temp=try TempDir(),root=temp.path("repo"),worktree=temp.path("worktree")
        func git(_ args:[String]) throws {
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/git");process.arguments=args
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        }
        try git(["init",root])
        try git(["-C",root,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","--allow-empty","-m","fixture"])
        try git(["-C",root,"worktree","add","-b","fixture-worktree",worktree])
        let store=try UsageStore(path:":memory:")
        try store.putEvent(tool:"codex",srcKey:"a",project:root,input:1)
        try store.putEvent(tool:"pi",srcKey:"b",project:worktree,input:2)
        XCTAssertEqual(try store.projectSummaries(UsageQuery()).count,1)
        XCTAssertEqual(try store.projectSummaries(UsageQuery()).first?.totals.tokens,3)
    }
    func testHistoricalMetadataBackfillDoesNotChangeLedger() throws {
        let temp=try TempDir(),root=temp.path("sessions")
        try FileManager.default.createDirectory(atPath:root,withIntermediateDirectories:true)
        let object:[String:Any] = ["type":"session_meta","payload":["id":"fixture-session","cwd":"/imaginary/backfilled"]]
        var data=try JSONSerialization.data(withJSONObject:object);data.append(0x0a)
        try data.write(to:URL(fileURLWithPath:root+"/session.jsonl"))
        let store=try UsageStore(path:":memory:")
        try store.putEvent(tool:"codex",srcKey:"a",sessionID:"fixture-session",input:99)
        var roots=ScanRoots(environment:[:]);roots.codexSessions=root;roots.claude=temp.path("missing")
        let progress=try ProjectBackfill.runBatch(store:store,roots:roots)
        XCTAssertTrue(progress.complete)
        XCTAssertEqual(try store.usageTotals(UsageQuery()).tokens,99)
        XCTAssertEqual(try store.projectSummaries(UsageQuery()).first?.name,"backfilled")
        _ = try ProjectBackfill.runBatch(store:store,roots:roots)
        XCTAssertEqual(try store.conn.scalarInt("SELECT COUNT(*) FROM usage_events"),1)
    }
    func testProjectConservationOverridesAndUnpriced() throws {
        let store=try UsageStore(path:":memory:")
        try store.putEvent(tool:"codex",srcKey:"a",sessionID:"s",project:"/imaginary/alpha",ts:1000,input:100)
        try store.putEvent(tool:"pi",srcKey:"b",sessionID:"s",project:"/imaginary/beta",ts:2000,output:20,cost:0)
        try store.putEvent(tool:"hermes",srcKey:"c",sessionID:"h",project:"a title",ts:3000,cacheRead:30,cost:1)
        let query=UsageQuery(start:1,end:4000)
        let projects=try store.projectSummaries(query)
        XCTAssertEqual(projects.count,3)
        XCTAssertEqual(projects.reduce(0){$0+$1.totals.tokens},try store.usageTotals(query).tokens)
        let alpha=projects.first{$0.name=="alpha"}!.id
        try store.assignSession(tool:"pi",sessionID:"s",projectID:alpha)
        XCTAssertEqual(try store.projectSummaries(query).first{$0.id==alpha}!.totals.tokens,120)
        try store.assignSession(tool:"pi",sessionID:"s",projectID:nil)
        XCTAssertEqual(try store.projectSummaries(query).count,3)
        XCTAssertEqual(try store.usageTotals(UsageQuery(start:1,end:1500)).costLabel,"未计价")
        XCTAssertEqual(try store.usageTotals(query).unpriced,1)
    }
    func testObservedIntervalNotAssignedAcrossBoundary() throws {
        let store=try UsageStore(path:":memory:")
        try store.putEvent(tool:"x",srcKey:"a",ts:200,input:100,timeQuality:"observed",intervalStart:50)
        let totals=try store.usageTotals(UsageQuery(start:100,end:300))
        XCTAssertEqual(totals.tokens,0);XCTAssertEqual(totals.unallocatedTokens,100)
        XCTAssertEqual(try store.usageTotals(UsageQuery(start:1,end:300)).tokens,100)
    }
    func testBudgetThresholdAndPersistentDedup() throws {
        let store=try UsageStore(path:":memory:")
        let now=Date(timeIntervalSince1970:1700000000)
        try store.putEvent(tool:"x",srcKey:"a",ts:Int64(now.timeIntervalSince1970*1000)-1000,input:95)
        try store.saveBudget(BudgetRule(limit:100))
        let risk=try store.budgetRisks(now:now)[0]
        XCTAssertEqual(risk.level,90)
        XCTAssertTrue(try store.shouldNotify(risk,now:10000))
        try store.markNotified(risk,now:10000)
        XCTAssertFalse(try store.shouldNotify(risk,now:4000000))
        var critical=risk;critical.level=100
        XCTAssertTrue(try store.shouldNotify(critical,now:10001))
        XCTAssertThrowsError(try store.saveBudget(BudgetRule(limit:Double.nan)))
    }
    func testQuotaRisksIgnoreLatePreviousAccountSamples() throws {
        let dir = try TempDir()
        let store = try UsageStore(path: dir.path("usage.db"))
        let now = store.nowMs()
        try store.recordQuota(QuotaSample(identity:"codex:previous:weekly",at:now,pct:99,resetsAt:now+3600000))
        try store.recordQuota(QuotaSample(identity:"codex:active:weekly",at:now,pct:20,resetsAt:now+3600000))
        let risks = try store.quotaRisks(now:now,codexAccountID:"active")
        XCTAssertEqual(risks.count,1)
        XCTAssertEqual(risks.first?.pct,20)
        XCTAssertTrue(try store.quotaRisks(now:now,codexAccountID:"unknown").isEmpty)
    }

    func testQuotaPredictionResetStalenessAndMinimumSamples() throws {
        let store=try UsageStore(path:":memory:")
        let now:Int64=2000000,reset:Int64=4000000
        for i in 0..<4 { try store.recordQuota(QuotaSample(identity:"a",at:now-900000+Int64(i)*300000,pct:Double(20+i*15),resetsAt:reset)) }
        let risks=try store.quotaRisks(now:now)
        XCTAssertEqual(risks.first?.level,1)
        XCTAssertTrue(risks.first?.detail.contains("估算") == true)
        XCTAssertTrue(try store.quotaRisks(now:now+300001).isEmpty)
        try store.recordQuota(QuotaSample(identity:"a",at:now+1000,pct:10,resetsAt:reset))
        XCTAssertEqual(try store.quotaRisks(now:now+1000).first?.level,0)
    }
    func testUnknownQuotaCycleHasThresholdButNoForecast() throws {
        let store=try UsageStore(path:":memory:")
        let now=store.nowMs()
        for i in 0..<4 { try store.recordQuota(QuotaSample(identity:"unknown-cycle",at:now-900000+Int64(i)*300000,pct:Double(50+i*15),resetsAt:0)) }
        let risk=try XCTUnwrap(store.quotaRisks(now:now).first)
        XCTAssertEqual(risk.level,90)
        XCTAssertFalse(risk.detail.contains("分钟"))
    }
    func testWeeklyNaturalWeekAndImmutableSnapshot() throws {
        let store=try UsageStore(path:":memory:")
        let now=ISO8601DateFormatter().date(from:"2026-01-05T12:00:00Z")!
        let report=try store.generateWeeklyReport(now:now,timeZone:TimeZone(secondsFromGMT:0)!)
        XCTAssertEqual(report.query.end!-report.query.start!,7*86400000)
        XCTAssertTrue(report.markdown.contains("2025-12-29 00:00 — 2026-01-05 00:00"))
        let dst=try store.generateWeeklyReport(now:ISO8601DateFormatter().date(from:"2026-03-09T18:00:00Z")!,timeZone:TimeZone(identifier:"America/Los_Angeles")!)
        XCTAssertEqual(dst.query.end!-dst.query.start!,Int64(167*3600000))
        try store.putEvent(tool:"x",srcKey:"a",ts:report.query.start!+1000,input:100)
        XCTAssertEqual(try store.generateWeeklyReport(now:now,timeZone:TimeZone(secondsFromGMT:0)!).totals.tokens,0)
        XCTAssertEqual(try store.generateWeeklyReport(now:now,timeZone:TimeZone(secondsFromGMT:0)!,regenerate:true).totals.tokens,100)
    }
    func testExportPaginationPrivacyAndCancellation() throws {
        let temp=try TempDir(),store=try UsageStore(path:":memory:")
        try store.conn.beginImmediate()
        for i in 0..<620 { try store.putEvent(tool:"codex",srcKey:String(i),sessionID:"PRIVATE_SESSION",project:"/PRIVATE_PATH",ts:Int64(i+1),input:1,cost:0) }
        try store.conn.commit()
        let url=URL(fileURLWithPath:temp.path("export.json"))
        try InsightExporter.export(store:store,query:UsageQuery(),kind:.usage,format:.json,destination:url)
        let data=try Data(contentsOf:url),text=String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_PATH"));XCTAssertFalse(text.contains("PRIVATE_SESSION"))
        let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertEqual((object["rows"] as! [Any]).count,620)
        let cancellation=ExportCancellation();cancellation.cancel()
        XCTAssertThrowsError(try InsightExporter.export(store:store,query:UsageQuery(),kind:.usage,format:.csv,destination:url,cancellation:cancellation))
        XCTAssertEqual(try Data(contentsOf:url),data)
        XCTAssertEqual(InsightExporter.csvField("=SUM(1,2)"),"\"'=SUM(1,2)\"")
    }
    func testCorruptAccountCannotBeOverwrittenAndWriteFailurePropagates() throws {
        let temp=try TempDir(),path=temp.path("accounts.json")
        try Data("broken".utf8).write(to:URL(fileURLWithPath:path))
        let store=CodexAccountStore(path:path)
        XCTAssertThrowsError(try store.loadChecked())
        XCTAssertThrowsError(try store.upsert(CodexAccount(id:"a",name:"a",bundle:[:])))
        XCTAssertEqual(try String(contentsOfFile:path,encoding:.utf8),"broken")
        XCTAssertThrowsError(try writeAccountJSON(path+"/child",["a":1]))
    }
    func testV4MigrationRetainsLedgerAndCreatesInsightTables() throws {
        let temp=try TempDir(),path=temp.path("usage.db")
        do {
            let conn=try SQLiteConnection(path:path)
            for sql in UsageStore.schema.split(separator:";") where !sql.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { try conn.execute(String(sql)) }
            try conn.execute("PRAGMA user_version=4")
            try conn.execute("INSERT INTO usage_events(tool,src_key,ts,input) VALUES ('x','a',1000,77)")
            try conn.commit()
        }
        let store=try UsageStore(path:path)
        XCTAssertEqual(try store.conn.scalarInt("PRAGMA user_version"),5)
        XCTAssertEqual(try store.usageTotals(UsageQuery()).tokens,77)
        XCTAssertTrue(try store.budgets().isEmpty)
    }
}
