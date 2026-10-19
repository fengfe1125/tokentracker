using TokenTracker.Core.Activity;
using TokenTracker.Core.Pricing;

namespace TokenTracker.Core.Store;

public sealed partial class UsageStore
{
    static readonly string AggSelect =
        string.Join(", ", TokenColumns.Select(c => $"COALESCE(SUM({c}),0) AS {c}"))
        + $", COALESCE(SUM({TokensExpr}),0) AS tokens, COUNT(*) AS events,"
        + " COALESCE(SUM(CASE WHEN cost IS NULL THEN 1 ELSE 0 END),0) AS unpriced,"
        + $" COALESCE(SUM(CASE WHEN time_quality='observed' THEN {TokensExpr} ELSE 0 END),0) AS estimated_tokens,"
        + $" COALESCE(SUM(CASE WHEN time_quality='unallocated' THEN {TokensExpr} ELSE 0 END),0) AS unallocated_tokens,"
        + " COALESCE(SUM(cost),0) AS cost";

    /// <summary>测试可覆盖范围边界（对齐 Python 测试 patch db._range_bounds）。</summary>
    public (long Lo, long Hi)? RangeBoundsOverride { get; set; }

    static long LocalMidnightMs(DateTime localDate) =>
        new DateTimeOffset(DateTime.SpecifyKind(localDate.Date, DateTimeKind.Local)).ToUnixTimeMilliseconds();

    public (long Lo, long Hi) RangeBounds(string rangeKey)
    {
        if (RangeBoundsOverride is { } o) return o;
        var nowMs = NowMs();
        var now = DateTimeOffset.FromUnixTimeMilliseconds(nowMs).LocalDateTime;
        long lo = rangeKey switch
        {
            "day" => LocalMidnightMs(now),
            "week" => LocalMidnightMs(now.AddDays(-6)),
            "month" => LocalMidnightMs(new DateTime(now.Year, now.Month, 1)),
            _ => 0,
        };
        return (lo, nowMs + 1000);
    }

    static (string Sql, List<object?> Args) Countable(long lo, long hi) =>
        ("(time_quality='exact' OR (time_quality='observed' AND interval_start>=?)) AND ts>=? AND ts<?",
            new List<object?> { lo, lo, hi });

    (string Sql, List<object?> Args) Filter(string rangeKey, string? tool = null, string? modelPrefix = null)
    {
        string sql;
        List<object?> args;
        if (rangeKey == "all")
        {
            sql = "1";
            args = [];
        }
        else
        {
            var (lo, hi) = RangeBounds(rangeKey);
            (sql, args) = Countable(lo, hi);
        }
        return Scope(sql, args, tool, modelPrefix);
    }

    static (string Sql, List<object?> Args) Scope(string sql, List<object?> args, string? tool = null,
        string? modelPrefix = null)
    {
        if (tool is not null)
        {
            sql += " AND tool=?";
            args.Add(tool);
        }
        if (modelPrefix is not null)
        {
            sql += " AND model LIKE ?";
            args.Add(modelPrefix + "%");
        }
        return (sql, args);
    }

    static string BucketExpr(string column, string bucket)
    {
        var fmt = bucket == "hour" ? "%Y-%m-%d %H" : "%Y-%m-%d";
        return $"strftime('{fmt}', {column}/1000, 'unixepoch', 'localtime')";
    }

    static string BucketFilter(string bucket) =>
        $"(time_quality='exact' OR (time_quality='observed' AND {BucketExpr("interval_start", bucket)}={BucketExpr("ts", bucket)}))";

    public TimeSummary GetTimeSummary(string rangeKey = "all", string? bucket = null, string? tool = null)
    {
        var (whereSql, args) = Filter(rangeKey, tool);
        if (bucket is not null) whereSql += " AND " + BucketFilter(bucket);
        var estimate = Conn.QueryOne(
            $"SELECT COALESCE(SUM({TokensExpr}),0) AS t FROM usage_events WHERE {whereSql} AND time_quality='observed'",
            args.ToArray())?.Int("t") ?? 0;

        string excluded;
        List<object?> excludedArgs;
        if (rangeKey == "all")
        {
            excluded = "time_quality='unallocated'";
            excludedArgs = [];
            if (bucket is not null) excluded += " OR (time_quality='observed' AND NOT " + BucketFilter(bucket) + ")";
        }
        else
        {
            var (lo, hi) = RangeBounds(rangeKey);
            var (included, includedArgs) = Countable(lo, hi);
            if (bucket is not null) included += " AND " + BucketFilter(bucket);
            // 未知历史可能属于任何范围；区间仅在重叠时才相关。
            excluded = $"time_quality='unallocated' OR (time_quality='observed' AND ts>=? AND interval_start<? AND NOT ({included}))";
            excludedArgs = [lo, hi, .. includedArgs];
        }
        (excluded, excludedArgs) = Scope($"({excluded})", excludedArgs, tool);
        var row = Conn.QueryOne(
            $"SELECT COALESCE(SUM({TokensExpr}),0) AS tokens,COALESCE(SUM(cost),0) AS cost,COUNT(*) AS events FROM usage_events WHERE {excluded}",
            excludedArgs.ToArray());
        return new TimeSummary(row?.Int("tokens") ?? 0, row?.Double("cost") ?? 0, row?.Int("events") ?? 0, estimate);
    }

    public StatsResult Stats(string rangeKey = "all", string? tool = null)
    {
        var (whereSql, args) = Filter(rangeKey, tool);
        var rows = Conn.Query(
                $"SELECT tool,COUNT(DISTINCT session_id) AS sessions,{AggSelect} FROM usage_events WHERE {whereSql} GROUP BY tool ORDER BY tokens DESC",
                args.ToArray())
            .Select(r => new ToolStats(r)).ToList();
        var total = new ToolStats { Tool = "__total__" };
        foreach (var r in rows)
        {
            total.Sessions += r.Sessions;
            total.Input += r.Input;
            total.Output += r.Output;
            total.CacheRead += r.CacheRead;
            total.CacheWrite += r.CacheWrite;
            total.Tokens += r.Tokens;
            total.Events += r.Events;
            total.Unpriced += r.Unpriced;
            total.EstimatedTokens += r.EstimatedTokens;
            total.UnallocatedTokens += r.UnallocatedTokens;
            total.Cost += r.Cost;
        }
        total.Cost = PythonJson.RoundHalfEven(total.Cost, 6);
        return new StatsResult(rows, total, GetTimeSummary(rangeKey, tool: tool));
    }

    public List<DailyRow> Daily(string rangeKey = "all")
    {
        var bucket = rangeKey == "day" ? "hour" : "day";
        var label = bucket == "hour" ? "strftime('%H:00', ts/1000, 'unixepoch', 'localtime')" : BucketExpr("ts", bucket);
        var (whereSql, args) = Filter(rangeKey);
        return Conn.Query(
                $"SELECT tool,{label} AS d,{AggSelect} FROM usage_events WHERE {whereSql} AND {BucketFilter(bucket)} GROUP BY d,tool ORDER BY d",
                args.ToArray())
            .Select(r => new DailyRow(r.Str("tool"), r.Str("d"), new ToolStats(r))).ToList();
    }

    public List<ModelRow> Models(string rangeKey = "all", string? tool = null)
    {
        var (whereSql, args) = Filter(rangeKey, tool);
        return Conn.Query(
                $"SELECT tool,model,{AggSelect} FROM usage_events WHERE {whereSql} GROUP BY tool,model ORDER BY tokens DESC",
                args.ToArray())
            .Select(r => new ModelRow(r.Str("tool"), r.Str("model"), new ToolStats(r))).ToList();
    }

    /// <summary>窗口内可计数用量（usd=true 时返回成本）。</summary>
    public double WindowUsage(long startMs, string? tool = null, string? modelPrefix = null, bool includeCache = false,
        bool usd = false)
    {
        var (sql, args) = Countable(startMs, NowMs() + 1000);
        (sql, args) = Scope(sql, args, tool, modelPrefix);
        var expr = usd ? "cost" : includeCache ? TokensExpr : "input+output";
        var row = Conn.QueryOne($"SELECT COALESCE(SUM({expr}),0) AS v FROM usage_events WHERE {sql}", args.ToArray());
        return usd ? row?.Double("v") ?? 0 : row?.Int("v") ?? 0;
    }

    public double WindowUnallocated(long startMs, string? tool = null, string? modelPrefix = null,
        bool includeCache = false, bool usd = false)
    {
        var (sql, args) = Scope(
            "(time_quality='unallocated' OR (time_quality='observed' AND ts>=? AND interval_start<?))",
            [startMs, startMs], tool, modelPrefix);
        var expr = usd ? "cost" : includeCache ? TokensExpr : "input+output";
        var row = Conn.QueryOne($"SELECT COALESCE(SUM({expr}),0) AS v FROM usage_events WHERE {sql}", args.ToArray());
        return usd ? row?.Double("v") ?? 0 : row?.Int("v") ?? 0;
    }

    /// <summary>用价格表回填 NULL 成本（不覆盖已有成本）。</summary>
    public int Reprice(PriceTable prices)
    {
        var n = 0;
        foreach (var row in Conn.Query("SELECT * FROM usage_events WHERE cost IS NULL"))
        {
            var cost = prices.Cost(row.Str("model"), row.Int("input"), row.Int("output"), row.Int("cache_read"),
                row.Int("cache_write"));
            if (cost is null) continue;
            Conn.Execute("UPDATE usage_events SET cost=?,cost_source='estimate' WHERE id=?", cost, row.Int("id"));
            n++;
        }
        Conn.Commit();
        return n;
    }

    // ------------------------------------------------------------ 活动 ----

    static readonly HashSet<string> RangeKeys = ["day", "week", "month", "all"];

    (string Sql, List<object?> Args) ActivityFilter(string rangeKey, string? agent, string confidence,
        string? sessionId, bool skill, string? eventKind = null)
    {
        if (!RangeKeys.Contains(rangeKey) || confidence is not ("exact" or "derived" or "all"))
            throw new SqliteException("Invalid activity filter");
        var clauses = new List<string>();
        var args = new List<object?>();
        if (rangeKey != "all")
        {
            var (lo, hi) = RangeBounds(rangeKey);
            clauses.Add("COALESCE(started_at,ended_at,0)>=? AND COALESCE(started_at,ended_at,0)<?");
            args.Add(lo);
            args.Add(hi);
        }
        if (agent is not null)
        {
            clauses.Add("agent=?");
            args.Add(agent);
        }
        if (sessionId is not null)
        {
            clauses.Add("session_id=?");
            args.Add(sessionId);
        }
        if (eventKind is not null)
        {
            clauses.Add("event_kind=?");
            args.Add(eventKind);
        }
        if (confidence != "all")
        {
            clauses.Add((skill ? "skill_confidence" : "confidence") + "=?");
            args.Add(confidence);
        }
        if (skill) clauses.Add("event_kind='skill' AND skill_name!=''");
        return (clauses.Count == 0 ? "1=1" : string.Join(" AND ", clauses), args);
    }

    public List<ActivitySummaryRow> ActivitySummary(string rangeKey = "all", string? agent = null,
        string group = "tool", string confidence = "all", string? sessionId = null)
    {
        if (group is not ("agent" or "tool" or "skill")) throw new SqliteException("Invalid activity group");
        var skill = group == "skill";
        var kind = group == "tool" ? ActivityKind.Tool : skill ? ActivityKind.Skill : null;
        var (whereSql, args) = ActivityFilter(rangeKey, agent, confidence, sessionId, skill, kind);
        var name = group == "agent" ? "agent" : skill ? "skill_name" : agent is null ? "canonical_name" : "raw_name";
        var evidence = skill ? "skill_confidence" : "confidence";
        return Conn.Query($"""
            SELECT {name} AS name,COUNT(*) AS calls,COUNT(DISTINCT session_id) AS sessions,
              COUNT(DISTINCT agent) AS agents,
              SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS success,
              SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) AS error,
              SUM(CASE WHEN status='denied' THEN 1 ELSE 0 END) AS denied,
              SUM(CASE WHEN status='unknown' THEN 1 ELSE 0 END) AS unknown,
              SUM(CASE WHEN {evidence}='exact' THEN 1 ELSE 0 END) AS exact,
              SUM(CASE WHEN {evidence}='derived' THEN 1 ELSE 0 END) AS derived,
              MAX(COALESCE(ended_at,started_at,0)) AS last_used
            FROM agent_activity_events WHERE {whereSql}
            GROUP BY {name} ORDER BY calls DESC,name
            """, args.ToArray()).Select(r => new ActivitySummaryRow(r.Str("name"), r.Int("calls"), r.Int("sessions"),
            r.Int("agents"), r.Int("success"), r.Int("error"), r.Int("denied"), r.Int("unknown"), r.Int("exact"),
            r.Int("derived"), r.Int("last_used"))).ToList();
    }

    public List<ActivityEvent> ActivityTimeline(string rangeKey = "all", string? agent = null,
        string? sessionId = null, string confidence = "all", int limit = 200)
    {
        var (whereSql, args) = ActivityFilter(rangeKey, agent, confidence, sessionId, skill: false);
        args.Add(Math.Clamp(limit, 1, 1000));
        return Conn.Query($"SELECT * FROM agent_activity_events WHERE {whereSql} "
                          + "ORDER BY COALESCE(started_at,ended_at,0) DESC,id DESC LIMIT ?", args.ToArray())
            .Select(r => new ActivityEvent
            {
                Agent = r.Str("agent"), SessionId = r.Str("session_id"), TurnId = r.Str("turn_id"),
                RawName = r.Str("raw_name"), CanonicalName = r.Str("canonical_name"), Namespace = r.Str("namespace"),
                CallId = r.Str("call_id"), ParentCallId = r.Str("parent_call_id"),
                StartedAt = r.IntOrNull("started_at"), EndedAt = r.IntOrNull("ended_at"),
                DurationMs = r.IntOrNull("duration_ms"), Status = r.Str("status"), SourceKind = r.Str("source_kind"),
                Confidence = r.Str("confidence"), SkillName = r.Str("skill_name"),
                SkillConfidence = r.Str("skill_confidence"), SrcKey = r.Str("src_key"),
                EventKind = r.Str("event_kind") is { Length: > 0 } k ? k : ActivityKind.Tool,
                EventLayer = r.Str("event_layer") is { Length: > 0 } l ? l : ActivityLayer.Execution,
            }).ToList();
    }

    // ------------------------------------------------------------ 会话 ----

    public SessionDetail GetSessionDetail(string tool, string sessionId)
    {
        const string times = "MIN(CASE WHEN time_quality!='unallocated' THEN COALESCE(interval_start,ts) END) AS first_ts,"
                             + "MAX(CASE WHEN time_quality!='unallocated' THEN ts END) AS last_ts";
        var modelRows = Conn.Query(
                $"SELECT model,{AggSelect},{times} FROM usage_events WHERE tool=? AND session_id=? GROUP BY model ORDER BY tokens DESC",
                tool, sessionId)
            .Select(r => new ModelRow(tool, r.Str("model"), new ToolStats(r))).ToList();
        var totalRow = Conn.QueryOne(
            $"SELECT COALESCE(MAX(NULLIF(project,'')),'') AS project,{AggSelect},{times} FROM usage_events WHERE tool=? AND session_id=?",
            tool, sessionId);
        var intervals = Conn.Query(
            $"SELECT interval_start,ts,{TokensExpr} AS tokens FROM usage_events WHERE tool=? AND session_id=? AND time_quality='observed' ORDER BY ts",
            tool, sessionId);
        return new SessionDetail
        {
            Project = totalRow?.Str("project") ?? "",
            Total = totalRow is not null ? new ToolStats(totalRow) : new ToolStats(),
            FirstTs = totalRow?.IntOrNull("first_ts"),
            LastTs = totalRow?.IntOrNull("last_ts"),
            Models = modelRows,
            ObservationIntervals = intervals
                .Select(r => new ObservationInterval(r.IntOrNull("interval_start"), r.Int("ts"), r.Int("tokens"))).ToList(),
            Activity = ActivityTimeline(agent: tool, sessionId: sessionId, limit: 500),
            ActivitySummary = ActivitySummary(agent: tool, group: "tool", sessionId: sessionId),
        };
    }

    public List<SessionRow> Sessions(string rangeKey = "all", string? tool = null, int limit = 300,
        string? query = null)
    {
        var (whereSql, filterArgs) = Filter(rangeKey, tool);
        var baseSql = $"""
            SELECT tool,session_id,MAX(project) AS project,
            datetime(MAX(CASE WHEN time_quality!='unallocated' THEN ts END)/1000,'unixepoch','localtime') AS last_seen,
            MAX(CASE WHEN time_quality!='unallocated' THEN ts END) AS ts,MAX(model) AS model,{AggSelect}
            FROM usage_events WHERE {whereSql} GROUP BY tool,session_id ORDER BY ts DESC
            """;
        var sql = $"SELECT s.*, m.title FROM ({baseSql}) s LEFT JOIN session_meta m ON m.tool=s.tool AND m.session_id=s.session_id";
        var args = new List<object?>(filterArgs);
        if (!string.IsNullOrEmpty(query))
        {
            sql += " WHERE (m.title LIKE ? OR s.project LIKE ? OR s.session_id LIKE ? OR s.model LIKE ?)";
            for (var i = 0; i < 4; i++) args.Add($"%{query}%");
        }
        sql += " ORDER BY s.ts DESC LIMIT ?";
        args.Add(limit);
        var rows = Conn.Query(sql, args.ToArray()).Select(r => new SessionRow
        {
            Tool = r.Str("tool"), SessionId = r.Str("session_id"), Project = r.Str("project"),
            LastSeen = r.StrOrNull("last_seen"), Ts = r.IntOrNull("ts"), Model = r.Str("model"),
            Title = r.StrOrNull("title"), Stats = new ToolStats(r),
        }).ToList();
        var (lo, hi) = RangeBounds(rangeKey);
        var rangeClause = rangeKey == "all"
            ? "1=1"
            : $"COALESCE(started_at,ended_at,0)>={lo} AND COALESCE(started_at,ended_at,0)<{hi}";
        var counts = Conn.Query($"""
            SELECT agent,session_id,
              SUM(CASE WHEN confidence='exact' THEN 1 ELSE 0 END) AS activity_exact,
              SUM(CASE WHEN confidence='derived' THEN 1 ELSE 0 END) AS activity_derived,
              COUNT(DISTINCT CASE WHEN skill_name!='' THEN skill_name END) AS skills
            FROM agent_activity_events WHERE {rangeClause} GROUP BY agent,session_id
            """).ToDictionary(r => r.Str("agent") + "\0" + r.Str("session_id"));
        foreach (var row in rows)
        {
            if (!counts.TryGetValue(row.Tool + "\0" + row.SessionId, out var count)) continue;
            row.ActivityExact = count.Int("activity_exact");
            row.ActivityDerived = count.Int("activity_derived");
            row.Skills = count.Int("skills");
        }
        return rows;
    }
}
