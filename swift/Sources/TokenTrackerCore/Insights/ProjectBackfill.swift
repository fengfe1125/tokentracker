import Foundation

public struct ProjectBackfillProgress: Sendable {
    public var processed: Int, total: Int
    public var complete: Bool { processed >= total }
}
public enum ProjectBackfill {
    /// Metadata only: never invokes a usage scanner or modifies token counters.
    public static func runBatch(store: UsageStore, roots: ScanRoots, limit: Int = 50) throws -> ProjectBackfillProgress {
        // In these adapters an absolute project value is only produced by an
        // explicit cwd field (Kimi's CLI journal-directory fallback is excluded).
        let metadataRows=try store.conn.query("""
        SELECT u.tool,u.src_key,u.project FROM usage_events u
        LEFT JOIN project_sources p ON p.tool=u.tool AND p.src_key=u.src_key
        WHERE p.src_key IS NULL AND u.tool IN ('codex','pi','dsh','kimi')
        AND u.project LIKE '/%' AND u.src_key NOT LIKE 'cli|%' LIMIT 500
        """)
        for row in metadataRows { try store.recordProjectPath(tool:row.string("tool"),srcKey:row.string("src_key"),path:row.string("project")) }
        try store.conn.commit()
        var files:[(String,String)]=[]
        for (tool,root) in [("claude",roots.claude),("codex",roots.codexSessions)] {
            guard let entries=FileManager.default.enumerator(atPath:root) else { continue }
            for case let entry as String in entries where entry.hasSuffix(".jsonl") { files.append((tool,(root as NSString).appendingPathComponent(entry))) }
        }
        files.sort{$0.1<$1.1}
        var processed=0,batch=0
        for (tool,path) in files {
            guard let stat=StatKey(path:path) else { processed += 1;continue }
            let key="project-backfill-v1:"+path,value="\(stat.m):\(stat.s)"
            if try store.conn.queryOne("SELECT value FROM insight_state WHERE key=?",[key])?.string("value") == value { processed += 1;continue }
            if batch >= limit { continue }
            var session="",paths=Set<String>()
            // Only session-level cwd evidence with one unambiguous directory is propagated.
            for (_,object) in iterJSONL(path) {
                if tool == "codex",object["type"] as? String == "session_meta",let payload=object["payload"] as? [String:Any] {
                    session=payload["id"] as? String ?? session
                    if let cwd=payload["cwd"] as? String,cwd.hasPrefix("/") { paths.insert(cwd) }
                } else if tool == "claude" {
                    session=object["sessionId"] as? String ?? session
                    if let cwd=object["cwd"] as? String,cwd.hasPrefix("/") { paths.insert(cwd) }
                }
            }
            if !session.isEmpty,paths.count == 1,let cwd=paths.first {
                for row in try store.conn.query("SELECT src_key FROM usage_events WHERE tool=? AND session_id=?",[tool,session]) {
                    try store.recordProjectPath(tool:tool,srcKey:row.string("src_key"),path:cwd)
                }
            }
            _ = try store.conn.execute("INSERT OR REPLACE INTO insight_state VALUES (?,?)",[key,value]);try store.conn.commit()
            processed += 1;batch += 1
        }
        return ProjectBackfillProgress(processed:processed,total:files.count + (metadataRows.count == 500 ? 1 : 0))
    }
}
