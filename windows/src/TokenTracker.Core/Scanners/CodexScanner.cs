using System.Text.RegularExpressions;
using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

/// <summary>
/// 移植 CodexScanner.swift（scanners/codex.py）：rollout JSONL 优先，SQLite turn 遥测补缺。
/// input 归一化为不含缓存读/写。同 turn 优先 JSONL，SQLite 只补其缺少的差额；
/// 没有可靠 turn 身份则按整个会话选择 JSONL。
/// </summary>
public sealed class CodexScanner(string logsDb, string sessionsDir) : IScanner
{
    const int ParserVersion = 5;
    const string KindJsonl = "codex_jsonl";
    const string KindSqlite = "codex_sqlite";

    static readonly HashSet<string> ToolCallTypes =
    [
        "function_call", "custom_tool_call", "mcp_call", "local_shell_call", "shell_call", "computer_call",
        "apply_patch_call",
    ];

    static readonly HashSet<string> ToolOutputTypes =
    [
        "function_call_output", "custom_tool_call_output", "mcp_call_output", "local_shell_call_output",
        "shell_call_output", "computer_call_output", "apply_patch_call_output",
    ];

    static readonly Regex FieldsRegex = new(
        @"(?<![\w])(?:codex\.turn\.token_usage\.)?(input_tokens|cached_input_tokens|cache_write_input_tokens|output_tokens)=(\d+)");

    static readonly Regex ModelRegex = new(@"\bmodel=[""']?([\w./:\-]+)");
    static readonly Regex ThreadRegex = new(@"\bthread\.id=[""']?([\w\-]+)");
    static readonly Regex TurnRegex = new(@"\bturn\.id=[""']?([\w\-]+)");
    static readonly Regex SpanRegex = new(@"\bturn\{([^{}]*)\}");

    static readonly string[][] Aliases =
    [
        ["input_tokens"],
        ["output_tokens"],
        ["cached_input_tokens"],
        ["cache_write_input_tokens", "cache_creation_input_tokens", "cache_write"],
    ];

    public string Name => "codex";
    public string Detail => "~/.codex/logs_2.sqlite 或 ~/.codex/sessions/";
    public string LogsDb { get; } = WinPaths.Expand(logsDb);
    public string SessionsDir { get; } = WinPaths.Expand(sessionsDir);

    public bool Detect() => File.Exists(LogsDb) || Directory.Exists(SessionsDir);

    // ------------------------------------------------------------ 解析 ----

    readonly record struct Counts(long Input, long Output, long Cached, long Written)
    {
        public static readonly Counts Zero = new(0, 0, 0, 0);
        public bool IsZero => this == Zero;
        public Counts Normalized() => new(Math.Max(Input - Cached - Written, 0), Output, Cached, Written);
    }

    /// <summary>校验计数器（严格非负 int、非 bool），无效返回 null。</summary>
    static Counts? ParseCounts(Dictionary<string, object?>? raw)
    {
        if (raw is null || !Aliases.SelectMany(a => a).Any(raw.ContainsKey)) return null;
        var values = new long[4];
        for (var i = 0; i < Aliases.Length; i++)
        {
            var key = Aliases[i].FirstOrDefault(raw.ContainsKey);
            if (key is null)
            {
                values[i] = 0;
                continue;
            }
            if (PyJson.StrictNonNegativeInt(raw[key]) is not { } v) return null;
            values[i] = v;
        }
        return new Counts(values[0], values[1], values[2], values[3]);
    }

    static string? RegexFirst(Regex re, string body) => re.Match(body) is { Success: true } m ? m.Groups[1].Value : null;

    static long? ItemTime(object? value, long? fallback)
    {
        var parsed = ScannerSupport.ParseTs(value);
        return parsed > 0 ? parsed : fallback;
    }

    static long? ItemDuration(Dictionary<string, object?> item, long? started, long? ended)
    {
        if (item.GetDict("duration") is { } duration)
        {
            var seconds = PyJson.JInt(duration.Get("secs"));
            var nanos = PyJson.JInt(duration.Get("nanos"));
            if (seconds > 0 || nanos > 0) return Math.Max(0, seconds * 1000 + nanos / 1_000_000);
        }
        if (started is not null && ended is not null) return Math.Max(0, ended.Value - started.Value);
        return null;
    }

    static string ItemStatus(Dictionary<string, object?> item)
    {
        var status = ActivityNormalizer.Status(item.Get("status"));
        if (status == "unknown" && item.Get("success") is bool success) status = success ? "success" : "error";
        if (status == "unknown" && PyJson.AsNumber(item.Get("exit_code")) is { } exitCode)
            status = (long)exitCode == 0 ? "success" : "error";
        return status == "unknown" ? "success" : status;
    }

    static List<Dictionary<string, object?>> ParsedCmd(Dictionary<string, object?> item) =>
        (item.Get("parsed_cmd") as List<object?>)?.OfType<Dictionary<string, object?>>().ToList() ?? [];

    static string CommandName(Dictionary<string, object?> item)
    {
        var kinds = ParsedCmd(item).Select(row => PyJson.PyStr(PyJson.Or(row.Get("type"), "")).ToLowerInvariant())
            .ToHashSet();
        if (kinds.Count != 1) return "shell";
        return kinds.First() switch
        {
            "read" => "Read",
            "search" => "Search",
            "list_files" => "ListFiles",
            _ => "shell",
        };
    }

    static (string RawName, string Kind, string ParentCallId) CompletedItem(Dictionary<string, object?> item)
    {
        var itemType = item.Get("type") as string ?? "";
        switch (itemType)
        {
            case "CommandExecution": return (CommandName(item), ActivityKind.Tool, "");
            case "FileChange": return ("apply_patch", ActivityKind.Tool, "");
            case "McpToolCall":
            {
                var server = PyJson.OrString(item.Get("server"), item.Get("server_name"));
                var tool = PyJson.OrString(PyJson.OrString(item.Get("tool"), item.Get("tool_name")),
                    PyJson.OrString(item.Get("actionName"), item.Get("name")));
                var raw = server.Length == 0 || tool.Length == 0 ? (tool.Length == 0 ? "mcp" : tool) : $"mcp__{server}__{tool}";
                return (raw, ActivityKind.Tool, "");
            }
            case "DynamicToolCall":
                return (PyJson.OrString(item.Get("tool"), item.Get("name")) is { Length: > 0 } d ? d : "dynamic_tool",
                    ActivityKind.Tool, "");
            case "ImageView": return ("image_view", ActivityKind.Tool, "");
            case "WebSearch": return ("web_search", ActivityKind.Tool, "");
            case "Plan": return ("plan", ActivityKind.Tool, "");
            case "CollabAgentToolCall":
                return (PyJson.OrString(item.Get("tool"), item.Get("name")) is { Length: > 0 } a ? a : "agent",
                    ActivityKind.Agent, PyJson.OrString(item.Get("sender_thread_id"), item.Get("parent_call_id")));
            case "SubAgentActivity":
                return ($"subagent.{(item.Get("kind") is string { Length: > 0 } k ? k : "activity")}", ActivityKind.Agent, "");
            default:
            {
                var fallback = itemType.Trim().ToLowerInvariant().Replace(" ", "_");
                return ($"codex.{(fallback.Length == 0 ? "unknown_item" : fallback)}", ActivityKind.Tool, "");
            }
        }
    }

    static List<string> SkillNames(Dictionary<string, object?> item)
    {
        var names = new List<string>();
        foreach (var row in ParsedCmd(item))
        {
            // cmd 是结构化命令文本；直接传入，避免对象编码细节遮住显式 SKILL.md 路径。
            var arguments = row.Get("cmd") ?? row.Get("command") ?? row;
            var skill = ActivityNormalizer.Skill("skill_file", arguments, allowPath: true);
            if (skill.Confidence == "derived" && skill.Name.Length > 0 && !names.Contains(skill.Name))
                names.Add(skill.Name);
        }
        return names;
    }

    // ------------------------------------------------------------ 落库 ----

    (int Added, int Updated) Put(UsageStore store, PriceTable prices, string key, string sid, string turn,
        string model, long ts, Counts counts, string kind, string project = "", string quality = "exact")
    {
        var n = counts.Normalized();
        var cost = prices.Cost(model, n.Input, n.Output, n.Cached, n.Written);
        var exists = store.Conn.QueryOne("SELECT 1 FROM usage_events WHERE tool=? AND src_key=?", Name, key) is not null;
        store.PutEvent(Name, key, sid, project, ts > 0 ? ts : 1, model, n.Input, n.Output, n.Cached, n.Written, cost,
            replace: true, timeQuality: ts > 0 ? quality : "unallocated", costSource: "estimate", sourceKind: kind,
            sourceScope: turn);
        return exists ? (0, 1) : (1, 0);
    }

    bool CoveredByJsonl(UsageStore store, string sid, string turn)
    {
        var sql = "SELECT 1 FROM usage_events WHERE tool=? AND session_id=? AND source_kind=?";
        var args = new List<object?> { Name, sid, KindJsonl };
        if (turn.Length > 0)
        {
            sql += " AND (source_scope=? OR source_scope='')";
            args.Add(turn);
        }
        return store.Conn.QueryOne(sql + " LIMIT 1", args.ToArray()) is not null;
    }

    Counts JsonlCounts(UsageStore store, string sid, string turn)
    {
        var row = store.Conn.QueryOne(
            "SELECT COALESCE(SUM(input+cache_read+cache_write),0) AS a,COALESCE(SUM(output),0) AS b,"
            + "COALESCE(SUM(cache_read),0) AS c,COALESCE(SUM(cache_write),0) AS d FROM usage_events "
            + "WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?", Name, sid, KindJsonl, turn);
        return new Counts(row?.Int("a") ?? 0, row?.Int("b") ?? 0, row?.Int("c") ?? 0, row?.Int("d") ?? 0);
    }

    static Counts RawRow(Row row) =>
        new(row.Int("input") + row.Int("cache_read") + row.Int("cache_write"), row.Int("output"),
            row.Int("cache_read"), row.Int("cache_write"));

    /// <summary>减去四个互斥事件类别，而不是用包含缓存的 input 去减独立缓存计数。</summary>
    static Counts Remaining(Counts total, Counts known)
    {
        var tn = total.Normalized();
        var kn = known.Normalized();
        var inp = Math.Max(tn.Input - kn.Input, 0);
        var output = Math.Max(tn.Output - kn.Output, 0);
        var cached = Math.Max(tn.Cached - kn.Cached, 0);
        var written = Math.Max(tn.Written - kn.Written, 0);
        return new Counts(inp + cached + written, output, cached, written);
    }

    /// <summary>选取唯一填充的 span，绝不合并两个嵌套 turn。</summary>
    static string SqliteBody(string body)
    {
        var candidates = SpanRegex.Matches(body).Select(m => m.Groups[1].Value)
            .Where(s => s.Contains("codex.turn.token_usage.input_tokens=", StringComparison.Ordinal)).ToList();
        return candidates.Count > 0 ? candidates[^1] : body;
    }

    // -------------------------------------------------------- SQLite 源 ----

    (int Added, int Updated, int Files) ScanSqlite(UsageStore store, PriceTable prices,
        Dictionary<string, object?> cursor, bool full)
    {
        if (!File.Exists(LogsDb)) return (0, 0, 0);
        if (FileIdentity.Of(LogsDb) is not { } st) return (0, 0, 0);
        int added = 0, updated = 0;
        var identity = new List<object?> { st.D, st.I, LogsDb };
        var identityMatches = cursor.Get("logs2_identity") is List<object?> { Count: 3 } stored
                              && PyJson.AsLong(stored[0]) == st.D && PyJson.AsLong(stored[1]) == st.I
                              && stored[2] as string == LogsDb;
        var last = full || !identityMatches ? 0 : PyJson.AsLong(cursor.Get("logs2_last_id")) ?? 0;
        List<Row> rows;
        using (var src = SqliteDb.OpenReadOnly(LogsDb))
        {
            var maximum = src.ScalarInt("SELECT COALESCE(MAX(id),0) FROM logs");
            if (maximum < last) last = 0;
            rows = src.Query(
                "SELECT id,ts,ts_nanos,feedback_log_body FROM logs WHERE id>? "
                + "AND feedback_log_body LIKE '%codex.turn.token_usage.input_tokens=%' ORDER BY id", last);
        }
        foreach (var row in rows)
        {
            last = row.Int("id");
            var body = SqliteBody(row.Str("feedback_log_body"));
            var fields = new Dictionary<string, object?>();
            foreach (Match match in FieldsRegex.Matches(body))
            {
                // Python dict 推导：后出现的覆盖先出现的
                if (long.TryParse(match.Groups[2].Value, out var v)) fields[match.Groups[1].Value] = v;
                else fields.Remove(match.Groups[1].Value);
            }
            if (ParseCounts(fields) is not { IsZero: false } parsedCounts) continue;
            var thread = RegexFirst(ThreadRegex, body);
            var turn = RegexFirst(TurnRegex, body) ?? "";
            var sid = thread ?? (turn.Length > 0 ? turn : row.Int("id").ToString());
            var model = RegexFirst(ModelRegex, body) ?? "";
            var tsRaw = row.Int("ts");
            long ts;
            if (tsRaw > (long)1e14)
            {
                ts = tsRaw / 1_000_000;
            }
            else
            {
                ts = ScannerSupport.ParseTs(tsRaw == 0 ? null : tsRaw);
                if (tsRaw > 0 && tsRaw < (long)1e11) ts += row.Int("ts_nanos") / 1_000_000;
            }
            var key = $"logs2|{row.Int("id")}";
            var old = store.Conn.QueryOne("SELECT * FROM usage_events WHERE tool=? AND src_key=?", Name, key);
            // 被替换的数据源可能复用了属于其他会话的行 ID。
            if (old is not null && (old.Str("session_id") != sid
                                    || (old.Str("source_scope").Length > 0 && old.Str("source_scope") != turn)))
                key = $"logs2|{sid}|{turn}|{row.Int("id")}";
            if (CoveredByJsonl(store, sid, turn))
            {
                var unscoped = store.Conn.QueryOne(
                    "SELECT 1 FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope='' LIMIT 1",
                    Name, sid, KindJsonl) is not null;
                if (turn.Length == 0 || unscoped)
                {
                    store.Conn.Execute("DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?", Name, key, sid);
                    continue;
                }
                // 还在增长的 rollout 可能只包含该 turn 的一部分；保留已核实的余额。
                parsedCounts = Remaining(parsedCounts, JsonlCounts(store, sid, turn));
                if (parsedCounts.IsZero)
                {
                    store.Conn.Execute(
                        "DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
                        Name, sid, KindSqlite, turn);
                    store.Conn.Execute("DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?", Name, key, sid);
                    continue;
                }
            }
            if (turn.Length > 0)
            {
                var same = store.Conn.QueryOne(
                    "SELECT * FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=? ORDER BY id LIMIT 1",
                    Name, sid, KindSqlite, turn);
                if (same is not null)
                {
                    // 多条日志行携带同一 turn 总量：复用首个 src_key，保留最大完整快照。
                    if (same.Str("src_key") != key)
                        store.Conn.Execute("DELETE FROM usage_events WHERE tool=? AND src_key=? AND session_id=?", Name, key, sid);
                    key = same.Str("src_key");
                    var existing = RawRow(same);
                    if (parsedCounts.Input + parsedCounts.Output < existing.Input + existing.Output) continue;
                }
            }
            var (a, u) = Put(store, prices, key, sid, turn, model, ts, parsedCounts, KindSqlite);
            added += a;
            updated += u;
        }
        cursor["logs2_last_id"] = last;
        cursor["logs2_identity"] = identity;
        return (added, updated, 1);
    }

    // -------------------------------------------------------- JSONL 源 ----

    sealed class RolloutEvent
    {
        public string? Key;
        public string Sid = "";
        public string Turn = "";
        public string Model = "";
        public long Ts;
        public Counts Counts = Counts.Zero;
        public string Project = "";
        public string Quality = "exact";
        public string? Title;
    }

    static List<RolloutEvent> RolloutEvents(string path)
    {
        var events = new List<RolloutEvent>();
        var fileName = WinPaths.LastComponent(path);
        var sid = Path.GetFileNameWithoutExtension(fileName);
        var project = WinPaths.Parent(path);
        string model = "", turn = "";
        var sidFromMeta = false;
        Counts? previous = null;
        var fallbackSeen = new HashSet<(string, long, Counts)>();
        string? title = null;

        foreach (var (lineNo, obj) in ScannerSupport.IterJsonl(path))
        {
            if (title is null)
            {
                var text = ScannerSupport.UserText(obj);
                if (text.Length > 0) title = text;
            }
            var payload = obj.GetDict("payload") ?? new Dictionary<string, object?>();
            var kind = obj.Get("type") as string;
            var payloadType = payload.Get("type") as string;
            if (kind == "session_meta")
            {
                // 子代理/fork 的 rollout 会重放父会话的 session_meta：只有首条（自身）有权决定 sid。
                if (!sidFromMeta && payload.Get("id") is string { Length: > 0 } id)
                {
                    sid = id;
                    sidFromMeta = true;
                }
                if (payload.Get("cwd") is string { Length: > 0 } cwd) project = cwd;
                continue;
            }
            if (kind == "turn_context")
            {
                if (payload.Get("model") is string { Length: > 0 } m) model = m;
                if (payload.Get("turn_id") is string { Length: > 0 } t) turn = t;
                continue;
            }
            if (kind == "event_msg" && payloadType == "task_started")
            {
                turn = PyJson.OrString(payload.Get("turn_id"), "");
                continue;
            }
            if (kind == "event_msg" && payloadType is "task_complete" or "turn_aborted")
            {
                turn = "";
                continue;
            }
            var ts = ScannerSupport.ParseTs(obj.Get("timestamp"));
            var eventTurn = PyJson.OrString(payload.Get("turn_id"), obj.Get("turn_id"), turn);
            Counts? counts = null;
            if (kind == "event_msg" && payloadType == "token_count")
            {
                if (payload.GetDict("info") is not { } info) continue;
                var total = ParseCounts(info.GetDict("total_token_usage"));
                var last = ParseCounts(info.GetDict("last_token_usage"));
                if (total is { } t)
                {
                    if (previous is not { } prev)
                    {
                        counts = t;
                        // 续跑/分叉文件的首个 total 带着继承历史；只有 last 是本文件新发生的调用。
                        if (last is { } l && l != t) counts = l;
                    }
                    else if (t.Input < prev.Input || t.Output < prev.Output || t.Cached < prev.Cached
                             || t.Written < prev.Written)
                    {
                        // compaction 可能重置计数器：建立新基线，不产生负差量。
                        previous = t;
                        continue;
                    }
                    else
                    {
                        counts = new Counts(t.Input - prev.Input, t.Output - prev.Output, t.Cached - prev.Cached,
                            t.Written - prev.Written);
                    }
                    previous = t;
                }
                else if (last is { } l)
                {
                    counts = l;
                    if (!fallbackSeen.Add((eventTurn, ts, l))) continue;
                    // 之后的累计快照已包含这些调用。
                    var p = previous ?? Counts.Zero;
                    previous = new Counts(p.Input + l.Input, p.Output + l.Output, p.Cached + l.Cached, p.Written + l.Written);
                }
                else
                {
                    continue;
                }
            }
            else
            {
                var raw = obj.GetDict("tokens") ?? obj.GetDict("usage");
                if (ParseCounts(raw) is not { } c) continue;
                counts = c;
                if (obj.Get("thread_id") is string { Length: > 0 } threadId) sid = threadId;
                else if (obj.Get("session_id") is string { Length: > 0 } sessionId) sid = sessionId;
                if (obj.Get("model") is string { Length: > 0 } m) model = m;
                else if (obj.Get("modelId") is string { Length: > 0 } mid) model = mid;
            }
            if (counts is not { IsZero: false } finalCounts) continue;
            events.Add(new RolloutEvent
            {
                Key = $"legacy|{path}|{lineNo}", Sid = sid, Turn = eventTurn, Model = model, Ts = ts,
                Counts = finalCounts, Project = project,
            });
        }
        if (title is not null) events.Add(new RolloutEvent { Sid = sid, Project = project, Title = title });
        return events;
    }

    void ReplaceSqliteScope(UsageStore store, PriceTable prices, RolloutEvent e, Counts previousJsonl)
    {
        if (e.Turn.Length == 0)
        {
            store.Conn.Execute("DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=?", Name, e.Sid, KindSqlite);
            return;
        }
        store.Conn.Execute("DELETE FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=''",
            Name, e.Sid, KindSqlite);
        var same = store.Conn.QueryOne(
            "SELECT * FROM usage_events WHERE tool=? AND session_id=? AND source_kind=? AND source_scope=?",
            Name, e.Sid, KindSqlite, e.Turn);
        if (same is null) return;
        var raw = RawRow(same);
        var total = new Counts(raw.Input + previousJsonl.Input, raw.Output + previousJsonl.Output,
            raw.Cached + previousJsonl.Cached, raw.Written + previousJsonl.Written);
        var rest = Remaining(total, JsonlCounts(store, e.Sid, e.Turn));
        if (!rest.IsZero)
            Put(store, prices, same.Str("src_key"), e.Sid, e.Turn, same.Str("model"), same.Int("ts"), rest, KindSqlite,
                same.Str("project"), same.Str("time_quality"));
        else
            store.Conn.Execute("DELETE FROM usage_events WHERE tool=? AND src_key=?", Name, same.Str("src_key"));
    }

    (int Added, int Updated) ScanRolloutActivity(UsageStore store, string path)
    {
        var entries = ScannerSupport.IterJsonl(path);
        var fileName = WinPaths.LastComponent(path);
        var sid = fileName.EndsWith(".jsonl", StringComparison.Ordinal) ? fileName[..^".jsonl".Length] : fileName;
        foreach (var (_, obj) in entries)
        {
            if (obj.Get("type") as string == "session_meta"
                && obj.GetDict("payload").Get("id") is string { Length: > 0 } value)
            {
                sid = value;
                break;
            }
        }
        var turns = new Dictionary<int, string>();
        var turn = "";
        var completedIds = new HashSet<string>();
        foreach (var (lineNo, obj) in entries)
        {
            var payload = obj.GetDict("payload") ?? new Dictionary<string, object?>();
            var kind = obj.Get("type") as string ?? "";
            if (kind == "turn_context" && payload.Get("turn_id") is string { Length: > 0 } t) turn = t;
            else if (kind == "event_msg" && payload.Get("type") as string == "task_started")
                turn = PyJson.OrString(payload.Get("turn_id"), turn);
            turns[lineNo] = PyJson.OrString(payload.Get("turn_id"), obj.Get("turn_id"), turn);
            if (kind == "event_msg" && payload.Get("type") as string == "item_completed" && payload.GetDict("item") is { } item)
            {
                if (item.Get("id") is string { Length: > 0 } id) completedIds.Add(id);
                foreach (var key in new[] { "call_id", "callId" })
                    if (item.Get(key) is string { Length: > 0 } callKey) completedIds.Add(callKey);
            }
        }

        int added = 0, updated = 0;
        var real = WinPaths.Real(path);
        foreach (var (lineNo, obj) in entries)
        {
            var payload = obj.GetDict("payload") ?? new Dictionary<string, object?>();
            if (obj.Get("type") as string != "event_msg" || payload.Get("type") as string != "item_completed"
                || payload.GetDict("item") is not { } item) continue;
            var descriptor = CompletedItem(item);
            if (descriptor.RawName.Length == 0) continue;
            var itemId = PyJson.Identifier(item.Get("id"), payload.Get("item_id"), (long)lineNo);
            var baseTs = ScannerSupport.ParseTs(obj.Get("timestamp"));
            long? baseFallback = baseTs == 0 ? null : baseTs;
            var started = ItemTime(payload.Get("started_at_ms") ?? item.Get("started_at_ms"), baseFallback);
            var ended = ItemTime(payload.Get("completed_at_ms") ?? item.Get("completed_at_ms"), baseFallback);
            var callId = PyJson.Identifier(item.Get("call_id"), item.Get("callId"), itemId);
            var parent = descriptor.ParentCallId;
            if (parent.Length == 0)
                parent = PyJson.OrString(payload.Get("parent_call_id"),
                    descriptor.Kind == ActivityKind.Agent ? payload.Get("thread_id") : null);
            var turnId = turns.GetValueOrDefault(lineNo, "");
            var change = store.RecordActivity(Name, $"{real}|execution|{itemId}", descriptor.RawName, sid, turnId, callId,
                parent, started, ended, ItemDuration(item, started, ended), ItemStatus(item), "codex_item_completed",
                "exact", eventKind: descriptor.Kind, eventLayer: ActivityLayer.Execution);
            added += change.Added;
            updated += change.Updated;
            var skills = SkillNames(item);
            for (var index = 0; index < skills.Count; index++)
            {
                var skill = store.PutActivityEvent(new ActivityEvent
                {
                    Agent = Name, SessionId = sid, TurnId = turnId, RawName = "skill_file",
                    CanonicalName = "skill.activate", Namespace = "built-in", CallId = "", ParentCallId = itemId,
                    StartedAt = started, EndedAt = started, DurationMs = 0, Status = "success",
                    SourceKind = "codex_skill_file", Confidence = "derived", SkillName = skills[index],
                    SkillConfidence = "derived", SrcKey = $"{real}|skill|{itemId}|{index}",
                    EventKind = ActivityKind.Skill, EventLayer = ActivityLayer.Execution,
                });
                added += skill.Added;
                updated += skill.Updated;
            }
        }

        foreach (var (lineNo, obj) in entries)
        {
            if (obj.Get("type") as string != "response_item") continue;
            var payload = obj.GetDict("payload") ?? new Dictionary<string, object?>();
            var itemType = payload.Get("type") as string ?? "";
            var tsValue = ScannerSupport.ParseTs(obj.Get("timestamp"));
            long? ts = tsValue == 0 ? null : tsValue;
            var callId = PyJson.OrString(payload.Get("call_id"), payload.Get("callId"), payload.Get("id"));
            if (ToolCallTypes.Contains(itemType))
            {
                var responseId = PyJson.Identifier(payload.Get("id"), callId, (long)lineNo);
                if (completedIds.Contains(responseId) || completedIds.Contains(callId)) continue;
                var rawName = payload.Get("name") as string ?? "";
                if (rawName.Length == 0)
                {
                    rawName = itemType switch
                    {
                        "local_shell_call" or "shell_call" => "shell",
                        "apply_patch_call" => "apply_patch",
                        "computer_call" => "computer",
                        _ => "",
                    };
                }
                if (rawName.Length == 0) continue;
                var isSkill = rawName.ToLowerInvariant() is "skill" or "skill_view";
                var change = store.RecordActivity(Name, $"{real}|request|{responseId}", rawName, sid,
                    turns.GetValueOrDefault(lineNo, ""), callId, startedAt: ts, sourceKind: "codex_request_fallback",
                    confidence: isSkill ? "exact" : "derived", eventKind: isSkill ? ActivityKind.Skill : ActivityKind.Tool,
                    eventLayer: isSkill ? ActivityLayer.Execution : ActivityLayer.RequestFallback);
                added += change.Added;
                updated += change.Updated;
            }
            else if (ToolOutputTypes.Contains(itemType))
            {
                var status = ActivityNormalizer.Status(payload.Get("status"));
                if (status == "unknown" && payload.GetDict("output") is { } output)
                    status = output.Get("is_error") is true || output.Get("error") is not null ? "error" : "success";
                if (status == "unknown") status = "success";
                updated += store.CompleteActivity(Name, callId, status, ts);
            }
        }
        return (added, updated);
    }

    (int Added, int Updated, int Files, int ActivityAdded, int ActivityUpdated) ScanLegacy(UsageStore store,
        PriceTable prices, Dictionary<string, object?> cursor, bool full)
    {
        if (!Directory.Exists(SessionsDir)) return (0, 0, 0, 0, 0);
        int added = 0, updated = 0, files = 0, activityAdded = 0, activityUpdated = 0;
        var allFiles = WinPaths.EnumerateFilesRelative(SessionsDir, rel => rel.EndsWith(".jsonl", StringComparison.Ordinal))
            .Select(rel => WinPaths.JoinRelative(SessionsDir, rel));
        foreach (var path in allFiles)
        {
            if (!full && !FileIdentity.Changed(cursor, path)) continue;
            if (FileIdentity.Of(path) is not { } statKey) continue;
            files++;
            foreach (var e in RolloutEvents(path))
            {
                if (e.Key is null)
                {
                    // 会话标题事件：首个真实用户消息
                    if (e.Title is not null) store.SetSessionTitle(Name, e.Sid, e.Title);
                    continue;
                }
                // 只有经过校验的非空 payload 才有权替换。
                var previousJsonl = JsonlCounts(store, e.Sid, e.Turn);
                var (a, u) = Put(store, prices, e.Key, e.Sid, e.Turn, e.Model, e.Ts, e.Counts, KindJsonl, e.Project, e.Quality);
                ReplaceSqliteScope(store, prices, e, previousJsonl);
                added += a;
                updated += u;
            }
            var activity = ScanRolloutActivity(store, path);
            activityAdded += activity.Added;
            activityUpdated += activity.Updated;
            cursor[path] = statKey.AsDict();
        }
        return (added, updated, files, activityAdded, activityUpdated);
    }

    // ------------------------------------------------------------ 入口 ----

    public ScanOutcome Scan(UsageStore store, PriceTable prices, bool full)
    {
        var cursor = store.GetScanCursor(Name);
        var effectiveFull = full || PyJson.AsLong(cursor.Get("parser_version")) != ParserVersion
                                 || ActivityNormalizer.NeedsBackfill(cursor);
        // 数据源删除、插入、游标移动一起回滚（即使调用方捕获后继续其他工具）。
        store.Conn.Execute("SAVEPOINT codex_scan");
        try
        {
            // JSONL 先扫（主源），SQLite 后扫补缺：同一趟内去重查询就能看到最新的 JSONL 归因。
            var legacy = ScanLegacy(store, prices, cursor, effectiveFull);
            var sqlite = ScanSqlite(store, prices, cursor, effectiveFull);
            var ambiguous = store.Conn.Query(
                "SELECT old.id FROM usage_events old WHERE old.tool=? AND old.source_kind='' "
                + "AND old.src_key LIKE 'logs2|%' AND EXISTS "
                + "(SELECT 1 FROM usage_events new WHERE new.tool=old.tool AND new.session_id=old.session_id AND new.source_kind=?)",
                Name, KindJsonl);
            foreach (var row in ambiguous)
                store.Conn.Execute("UPDATE usage_events SET time_quality='unallocated' WHERE id=?", row.Int("id"));
            cursor["parser_version"] = (long)ParserVersion;
            ActivityNormalizer.MarkCurrent(cursor);
            store.Conn.Execute("INSERT OR REPLACE INTO scan_state(tool,cursor) VALUES (?,?)", Name, PyJson.Serialize(cursor));
            store.Conn.Execute("RELEASE SAVEPOINT codex_scan");
            var outcome = new ScanOutcome
            {
                Added = sqlite.Added + legacy.Added,
                Updated = sqlite.Updated + legacy.Updated,
                Files = sqlite.Files + legacy.Files,
                ActivityAdded = legacy.ActivityAdded,
                ActivityUpdated = legacy.ActivityUpdated,
            };
            if (ambiguous.Count > 0)
                outcome.Warning = $"保留 {ambiguous.Count} 条无法核实与 JSONL 对应关系的旧 Codex 日志；已标记时间未知，可能存在重复历史。";
            return outcome;
        }
        catch
        {
            try
            {
                store.Conn.Execute("ROLLBACK TO SAVEPOINT codex_scan");
                store.Conn.Execute("RELEASE SAVEPOINT codex_scan");
            }
            catch (SqliteException)
            {
            }
            throw;
        }
    }
}
