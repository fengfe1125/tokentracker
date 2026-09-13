import XCTest
@testable import TokenTrackerCore

final class InsightsPerformanceTests: XCTestCase {
    func testLargeCorpusListSearchAndExportCancellation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TT_PERFORMANCE"] == "1","Opt-in 100k usage / 1m activity benchmark")
        let temporary=try TempDir(),store=try UsageStore(path:temporary.path("performance.db"))
        let now=store.nowMs()
        try store.conn.beginImmediate()
        try store.conn.execute("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000)
        INSERT INTO projects SELECT 'project-'||x,'Project '||x FROM n
        """)
        try store.conn.execute("INSERT INTO project_paths SELECT id,id,NULL FROM projects")
        try store.conn.execute("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
        INSERT INTO usage_events(tool,src_key,session_id,ts,input,output,cache_read,cost,model)
        SELECT 'codex',CAST(x AS TEXT),'session-'||(x%5000),?-x*1000,1000,200,500,0.02,'example' FROM n
        """,[now])
        try store.conn.execute("INSERT INTO project_sources SELECT tool,src_key,'project-'||((id%1000)+1) FROM usage_events")
        try store.conn.execute("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000)
        INSERT INTO agent_activity_events(agent,session_id,raw_name,canonical_name,started_at,status,confidence,src_key)
        SELECT 'codex','session-'||(x%5000),'read','file.read',?-x*100,'success','exact',CAST(x AS TEXT) FROM n
        """,[now])
        try store.conn.commit()
        let query=UsageQuery.period("week")
        _ = try store.projectSummaries(query)
        var samples:[Double]=[],listSamples:[Double]=[]
        for _ in 0..<20 {
            let listStart=Date()
            _ = try store.projectSummaries(query)
            _ = try store.usageTotals(query)
            listSamples.append(Date().timeIntervalSince(listStart)*1000)
            let start=Date()
            _ = try store.projectSummaries(query,search:"Project 1")
            samples.append(Date().timeIntervalSince(start)*1000)
        }
        let p95=samples.sorted()[18]
        print("INSIGHTS_PERFORMANCE project-search p95_ms=\(p95); usage=100000; activity=1000000; projects=1000; processors=\(ProcessInfo.processInfo.processorCount)")
        XCTAssertLessThanOrEqual(p95,500)
        let listP95=listSamples.sorted()[18]
        print("INSIGHTS_PERFORMANCE first-page-and-totals p95_ms=\(listP95)")
        XCTAssertLessThanOrEqual(listP95,500)
        let page=try store.activityTimelinePage(agent:"codex",sessionID:"session-1",limit:200)
        XCTAssertEqual(page.rows.count,200)
        let cancellation=ExportCancellation()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { cancellation.cancel() }
        let start=Date()
        XCTAssertThrowsError(try InsightExporter.export(store:store,query:UsageQuery(),kind:.activity,format:.json,destination:URL(fileURLWithPath:temporary.path("activity.json")),cancellation:cancellation))
        XCTAssertLessThan(Date().timeIntervalSince(start),2)
    }
}
