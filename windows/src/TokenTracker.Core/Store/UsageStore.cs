using System.Text;
using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;

namespace TokenTracker.Core.Store;

/// <summary>
/// 移植 Store/UsageStore.swift（以 tokentracker/db.py 为准）：SQLite 汇总库、事务式 schema 升级、
/// 显式时间质量。token 四列互斥：非缓存输入 / 输出 / 缓存读 / 缓存写。
/// 与 Swift / Python 版共用同一 usage.db：DDL、user_version、游标键都必须一致。
/// </summary>
public sealed partial class UsageStore : IDisposable
{
    public const int SchemaVersion = 5;
    public static readonly string[] TokenColumns = ["input", "output", "cache_read", "cache_write"];
    public const string TokensExpr = "(input+output+cache_read+cache_write)";

    internal const string Schema = """
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
        event_kind TEXT NOT NULL DEFAULT 'tool',
        event_layer TEXT NOT NULL DEFAULT 'execution',
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
    """;

    internal const string InsightsSchema = """
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
    """;

    public SqliteDb Conn { get; }
    public string DbPath { get; }

    /// <summary>测试缝：putEvent 写入前调用（可抛错模拟写入失败）。</summary>
    public Action<string, string>? PutEventHook { get; set; }

    /// <summary>注入时钟（毫秒）。测试冻结；生产为系统时间。</summary>
    public Func<long> NowMs { get; set; } = () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>迁移重定价用的价格表。</summary>
    public PriceTable PriceTableForMigration { get; set; } = PriceTable.Default;

    /// <summary>默认库路径：TOKENTRACKER_DB，否则 %USERPROFILE%\.tokentracker\usage.db。</summary>
    public static string DefaultPath =>
        Environment.GetEnvironmentVariable("TOKENTRACKER_DB") is { Length: > 0 } env
            ? env
            : Path.Combine(WinPaths.DataDir, "usage.db");

    public UsageStore(string path, PriceTable? migrationPrices = null)
    {
        DbPath = path;
        if (migrationPrices is not null) PriceTableForMigration = migrationPrices;
        if (path != ":memory:")
        {
            var dir = Path.GetDirectoryName(Path.GetFullPath(path));
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        }
        Conn = new SqliteDb(path);
        var version = (int)Conn.ScalarInt("PRAGMA user_version");
        if (version == SchemaVersion) return;
        if (path == ":memory:")
        {
            Upgrade(version);
            return;
        }
        using var migrationLock = FileLock.Acquire(path + ".migrate.lock", TimeSpan.FromSeconds(60));
        // 锁内重读：并发进程可能刚完成迁移
        version = (int)Conn.ScalarInt("PRAGMA user_version");
        Upgrade(version);
    }

    public void Dispose()
    {
        try
        {
            Conn.Commit();
        }
        catch (SqliteException)
        {
        }
        Conn.Dispose();
    }

    // ------------------------------------------------------------ 迁移 ----

    void Upgrade(int version)
    {
        if (version > SchemaVersion)
            throw new SqliteException($"Database version {version} is newer than supported {SchemaVersion}");
        if (version == SchemaVersion) return;
        var legacy = Conn.QueryOne("SELECT 1 FROM sqlite_master WHERE name='usage_events'") is not null;
        if (legacy)
        {
            var backupPath = $"{DbPath}.v{version}.backup-{DateTime.UtcNow.Ticks}.db";
            using var backup = new SqliteDb(backupPath);
            Conn.BackupTo(backup);
        }
        if (version < 3) ValidateResidualActivityTable();
        Conn.BeginImmediate();
        try
        {
            if (legacy && version < 1)
            {
                (string Column, string Declaration)[] columns =
                [
                    ("time_quality", "TEXT NOT NULL DEFAULT 'exact'"),
                    ("interval_start", "INTEGER"),
                    ("cost_source", "TEXT NOT NULL DEFAULT 'estimate'"),
                    ("source_kind", "TEXT NOT NULL DEFAULT ''"),
                    ("source_scope", "TEXT NOT NULL DEFAULT ''"),
                ];
                foreach (var (column, declaration) in columns)
                    Conn.Execute($"ALTER TABLE usage_events ADD COLUMN {column} {declaration}");
            }
            foreach (var statement in (Schema + InsightsSchema).Split(';'))
            {
                var trimmed = statement.Trim();
                if (trimmed.Length > 0) Conn.Execute(trimmed);
            }
            if (version < 4)
            {
                var columns = Conn.Query("PRAGMA table_info(agent_activity_events)").Select(r => r.Str("name")).ToHashSet();
                if (!columns.Contains("event_kind"))
                    Conn.Execute("ALTER TABLE agent_activity_events ADD COLUMN event_kind TEXT NOT NULL DEFAULT 'tool'");
                if (!columns.Contains("event_layer"))
                    Conn.Execute("ALTER TABLE agent_activity_events ADD COLUMN event_layer TEXT NOT NULL DEFAULT 'execution'");
                Conn.Execute("""
                    UPDATE agent_activity_events
                    SET event_kind=CASE WHEN lower(raw_name) IN ('skill','skill_view')
                                        OR (skill_confidence='exact' AND skill_name!='')
                                        THEN 'skill' ELSE 'tool' END,
                        event_layer=CASE WHEN agent='codex'
                                          AND source_kind IN ('codex_rollout','codex_exec_payload')
                                          THEN 'request_fallback' ELSE 'execution' END
                    """);
            }
            // v3 表在上面的 ALTER 之前没有 event_kind；两列都存在后才建新索引。
            Conn.Execute("CREATE INDEX IF NOT EXISTS idx_activity_kind_time ON agent_activity_events(event_kind, started_at)");
            if (legacy && version < 1) MigrateLegacyCosts();
            Conn.Execute($"PRAGMA user_version={SchemaVersion}");
            Conn.Commit();
        }
        catch
        {
            Conn.Rollback();
            throw;
        }
    }

    void MigrateLegacyCosts()
    {
        var prices = PriceTableForMigration;
        foreach (var row in Conn.Query("SELECT * FROM usage_events WHERE tool IN ('codex','opencode','hermes')"))
        {
            var original = row.Values.Where(kv => kv.Value is not null)
                .ToDictionary(kv => kv.Key, kv => kv.Value);
            Conn.Execute("INSERT INTO migration_history VALUES (?,?,?,?,?)",
                (long)SchemaVersion, NowMs(), row.IntOrNull("id"), PyJson.Serialize(original),
                "Preserved original counters; Codex prices recalculated using the current price table (not a historical bill).");
            if (row.Str("tool") == "codex")
            {
                var inp = Math.Max(0, row.Int("input") - row.Int("cache_read") - row.Int("cache_write"));
                var cost = prices.Cost(row.Str("model"), inp, row.Int("output"), row.Int("cache_read"),
                    row.Int("cache_write"));
                var quality = row.Str("src_key").StartsWith("legacy|", StringComparison.Ordinal) ? "unallocated" : "exact";
                Conn.Execute("UPDATE usage_events SET input=?,cost=?,cost_source='recomputed',time_quality=? WHERE id=?",
                    inp, cost, quality, row.Int("id"));
            }
            else
            {
                Conn.Execute("UPDATE usage_events SET time_quality='unallocated',cost_source='legacy' WHERE id=?",
                    row.Int("id"));
            }
        }
    }

    /// <summary>
    /// 部分回滚构建把 user_version 重置为 2 却留下完整 v3 活动表：保留该表，
    /// 但绝不猜测如何迁移一个畸形的残留 schema。
    /// </summary>
    void ValidateResidualActivityTable()
    {
        if (Conn.QueryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_activity_events'") is null)
            return;
        var expected = new HashSet<string>
        {
            "id", "agent", "session_id", "turn_id", "raw_name", "canonical_name",
            "namespace", "call_id", "parent_call_id", "started_at", "ended_at",
            "duration_ms", "status", "source_kind", "confidence", "skill_name",
            "skill_confidence", "src_key",
        };
        var expectedV4 = new HashSet<string>(expected) { "event_kind", "event_layer" };
        var columns = Conn.Query("PRAGMA table_info(agent_activity_events)").Select(r => r.Str("name")).ToHashSet();
        if (!columns.SetEquals(expected) && !columns.SetEquals(expectedV4))
            throw new SqliteException("Existing agent_activity_events schema is incompatible");
        var hasIdentity = false;
        foreach (var index in Conn.Query("PRAGMA index_list(agent_activity_events)").Where(r => r.Int("unique") == 1))
        {
            var escaped = index.Str("name").Replace("\"", "\"\"");
            var names = Conn.Query($"PRAGMA index_info(\"{escaped}\")")
                .OrderBy(r => r.Int("seqno")).Select(r => r.Str("name")).ToList();
            if (names.SequenceEqual(["agent", "src_key"]))
            {
                hasIdentity = true;
                break;
            }
        }
        if (!hasIdentity) throw new SqliteException("Existing agent_activity_events lacks UNIQUE(agent,src_key)");
    }

    // ------------------------------------------------------------ 写入 ----

    static readonly HashSet<string> TimeQualities = ["exact", "observed", "unallocated"];
    static readonly HashSet<string> ProjectPathTools = ["codex", "pi", "dsh", "kimi"];

    /// <summary>INSERT OR IGNORE（replace=true 时 OR REPLACE）。返回实际写入行数。</summary>
    public int PutEvent(string tool, string srcKey, string sessionId = "", string project = "", long ts = 0,
        string model = "", long input = 0, long output = 0, long cacheRead = 0, long cacheWrite = 0,
        double? cost = null, bool replace = false, string timeQuality = "exact", long? intervalStart = null,
        string costSource = "estimate", string sourceKind = "", string sourceScope = "")
    {
        PutEventHook?.Invoke(tool, sourceKind);
        var quality = timeQuality;
        if (!TimeQualities.Contains(quality)) throw new SqliteException($"Unknown time quality: {quality}");
        if (quality == "observed" && (intervalStart is null || intervalStart > ts)) quality = "unallocated";
        if (ts <= 0) ts = NowMs();
        var verb = replace ? "INSERT OR REPLACE" : "INSERT OR IGNORE";
        var changed = Conn.Execute(
            $"{verb} INTO usage_events (tool,src_key,session_id,project,ts,model,input,output,cache_read,cache_write,cost,"
            + "time_quality,interval_start,cost_source,source_kind,source_scope) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            tool, srcKey, sessionId, project, ts, model, input, output, cacheRead, cacheWrite,
            cost, quality, intervalStart, costSource, sourceKind, sourceScope);
        if (ProjectPathTools.Contains(tool) && WinPaths.IsAbsoluteProjectPath(project)
            && !srcKey.StartsWith("cli|", StringComparison.Ordinal))
            RecordProjectPath(tool, srcKey, project);
        return changed;
    }

    static readonly HashSet<string> Statuses = ["success", "error", "denied", "unknown"];
    static readonly HashSet<string> Confidences = ["exact", "derived"];
    static readonly HashSet<string> Kinds = [ActivityKind.Tool, ActivityKind.Skill, ActivityKind.Agent];
    static readonly HashSet<string> Layers = [ActivityLayer.Execution, ActivityLayer.RequestFallback, ActivityLayer.Lifecycle];

    public (int Added, int Updated) PutActivityEvent(ActivityEvent e)
    {
        if (!Statuses.Contains(e.Status) || !Confidences.Contains(e.Confidence)
            || (e.SkillConfidence.Length > 0 && !Confidences.Contains(e.SkillConfidence))
            || !Kinds.Contains(e.EventKind) || !Layers.Contains(e.EventLayer)
            || e.Agent.Length == 0 || e.SrcKey.Length == 0 || e.RawName.Length == 0)
            throw new SqliteException("Invalid activity event");
        const string probe =
            "SELECT status,ended_at,duration_ms,event_kind,event_layer FROM agent_activity_events WHERE agent=? AND src_key=?";
        var before = Conn.QueryOne(probe, e.Agent, e.SrcKey);
        Conn.Execute("""
            INSERT INTO agent_activity_events (
              agent,session_id,turn_id,raw_name,canonical_name,event_kind,event_layer,namespace,call_id,parent_call_id,
              started_at,ended_at,duration_ms,status,source_kind,confidence,
              skill_name,skill_confidence,src_key
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(agent,src_key) DO UPDATE SET
              session_id=CASE WHEN excluded.session_id!='' THEN excluded.session_id ELSE session_id END,
              turn_id=CASE WHEN excluded.turn_id!='' THEN excluded.turn_id ELSE turn_id END,
              event_kind=excluded.event_kind,
              event_layer=excluded.event_layer,
              ended_at=COALESCE(excluded.ended_at,ended_at),
              duration_ms=COALESCE(excluded.duration_ms,duration_ms),
              status=CASE WHEN excluded.status!='unknown' THEN excluded.status ELSE status END,
              skill_name=CASE WHEN excluded.skill_name!='' THEN excluded.skill_name ELSE skill_name END,
              skill_confidence=CASE WHEN excluded.skill_confidence!='' THEN excluded.skill_confidence ELSE skill_confidence END
            """,
            e.Agent, e.SessionId, e.TurnId, e.RawName, e.CanonicalName, e.EventKind, e.EventLayer, e.Namespace,
            e.CallId, e.ParentCallId, e.StartedAt, e.EndedAt, e.DurationMs, e.Status, e.SourceKind,
            e.Confidence, e.SkillName, e.SkillConfidence, e.SrcKey);
        var after = Conn.QueryOne(probe, e.Agent, e.SrcKey);
        var changed = before is not null && (before.Str("status") != after?.Str("status")
                                             || before.IntOrNull("ended_at") != after?.IntOrNull("ended_at")
                                             || before.IntOrNull("duration_ms") != after?.IntOrNull("duration_ms")
                                             || before.Str("event_kind") != after?.Str("event_kind")
                                             || before.Str("event_layer") != after?.Str("event_layer"));
        return (before is null ? 1 : 0, changed ? 1 : 0);
    }

    public (int Added, int Updated) RecordActivity(string agent, string srcKey, string rawName,
        string sessionId = "", string turnId = "", string callId = "", string parentCallId = "",
        long? startedAt = null, long? endedAt = null, long? durationMs = null, string status = "unknown",
        string sourceKind = "", string confidence = "exact", object? arguments = null, bool allowSkillPath = false,
        string? eventKind = null, string eventLayer = ActivityLayer.Execution)
    {
        var skill = ActivityNormalizer.Skill(rawName, arguments, allowSkillPath);
        return PutActivityEvent(new ActivityEvent
        {
            Agent = agent, SessionId = sessionId, TurnId = turnId, RawName = rawName,
            CanonicalName = ActivityNormalizer.CanonicalToolName(rawName),
            Namespace = ActivityNormalizer.NamespaceOf(rawName), CallId = callId,
            ParentCallId = parentCallId, StartedAt = startedAt, EndedAt = endedAt,
            DurationMs = durationMs, Status = status, SourceKind = sourceKind,
            Confidence = confidence, SkillName = skill.Name, SkillConfidence = skill.Confidence,
            SrcKey = srcKey, EventKind = eventKind ?? ActivityNormalizer.EventKindFor(rawName),
            EventLayer = eventLayer,
        });
    }

    /// <summary>活动元数据可重建；token 历史不动。</summary>
    public int ClearActivityEvents(string agent) =>
        agent.Length == 0 ? 0 : Conn.Execute("DELETE FROM agent_activity_events WHERE agent=?", agent);

    public int CompleteActivity(string agent, string callId, string status = "success", long? endedAt = null,
        long? durationMs = null)
    {
        if (callId.Length == 0 || !Statuses.Contains(status)) return 0;
        var row = Conn.QueryOne("SELECT id,started_at,status,ended_at,duration_ms FROM agent_activity_events "
                                + "WHERE agent=? AND call_id=? ORDER BY id DESC LIMIT 1", agent, callId);
        if (row is null) return 0;
        var duration = durationMs;
        if (duration is null && endedAt is not null && row.IntOrNull("started_at") is { } started)
            duration = Math.Max(0, endedAt.Value - started);
        var effectiveEnded = endedAt ?? row.IntOrNull("ended_at");
        var effectiveDuration = duration ?? row.IntOrNull("duration_ms");
        var changed = row.Str("status") != status || row.IntOrNull("ended_at") != effectiveEnded
                      || row.IntOrNull("duration_ms") != effectiveDuration;
        Conn.Execute("UPDATE agent_activity_events SET status=?,ended_at=COALESCE(?,ended_at),"
                     + "duration_ms=COALESCE(?,duration_ms) WHERE id=?", status, endedAt, duration, row.Int("id"));
        return changed ? 1 : 0;
    }

    public void SetScanCursor(string tool, Dictionary<string, object?> cursor)
    {
        Conn.Execute("INSERT OR REPLACE INTO scan_state(tool,cursor) VALUES (?,?)", tool, PyJson.Serialize(cursor));
        Conn.Commit();
    }

    public Dictionary<string, object?> GetScanCursor(string tool)
    {
        var text = Conn.QueryOne("SELECT cursor FROM scan_state WHERE tool=?", tool)?.StrOrNull("cursor");
        return PyJson.ParseObject(text) ?? new Dictionary<string, object?>();
    }

    /// <summary>会话标题（首个 user 消息等）。只在内容变化时更新，幂等。</summary>
    public void SetSessionTitle(string tool, string sessionId, string title)
    {
        var cleaned = TextUtil.CollapseWhitespace(title);
        if (cleaned.Length == 0 || sessionId.Length == 0) return;
        Conn.Execute("""
            INSERT INTO session_meta VALUES (?,?,?,?)
            ON CONFLICT(tool, session_id) DO UPDATE SET title=excluded.title,
            updated_at=excluded.updated_at WHERE session_meta.title != excluded.title
            """, tool, sessionId, cleaned, NowMs());
    }
}

public static class TextUtil
{
    /// <summary>Python " ".join(text.split())：按空白折叠。</summary>
    public static string CollapseWhitespace(string text)
    {
        var sb = new StringBuilder(text.Length);
        var pendingSpace = false;
        foreach (var ch in text)
        {
            if (char.IsWhiteSpace(ch) || ch is '\u001c' or '\u001d' or '\u001e' or '\u001f')
            {
                pendingSpace = sb.Length > 0;
                continue;
            }
            if (pendingSpace)
            {
                sb.Append(' ');
                pendingSpace = false;
            }
            sb.Append(ch);
        }
        return sb.ToString();
    }

    /// <summary>Python text[:120]：按码点截断。</summary>
    public static string Truncate120(string text)
    {
        var count = 0;
        var index = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (count == 120) return text[..index];
            index += rune.Utf16SequenceLength;
            count++;
        }
        return text;
    }

    public static string CleanSessionTitle(string title) => Truncate120(CollapseWhitespace(title));
}
