using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

/// <summary>
/// 移植 HermesScanner.swift（scanners/hermes.py）：&lt;home&gt;/state.db（含 profiles/*/state.db）。
/// session_model_usage 按六元组身份记录累计用量；按来源库持久化快照。
/// Windows 差异：Hermes 有两处数据目录（~/.hermes 与 %LOCALAPPDATA%\hermes），都扫描；
/// state-snapshots 是备份，不扫描；缺 session_model_usage 表的库只读活动并给出警告，不让整个工具失败。
/// </summary>
public sealed class HermesScanner : IScanner
{
    static readonly string[] IdentityKeys = ["session_id", "model", "billing_provider", "billing_base_url", "billing_mode", "task"];

    public string Name => "hermes";
    public string Detail => "~/.hermes/state.db (session_model_usage)";
    public IReadOnlyList<string> Homes { get; }

    /// <summary>测试缝：覆盖 DbFiles()。</summary>
    public List<string>? DbFilesOverride { get; init; }

    public HermesScanner(IEnumerable<string> homes) => Homes = homes.Select(WinPaths.Expand).ToList();

    public List<string> DbFiles()
    {
        if (DbFilesOverride is not null) return DbFilesOverride;
        var output = new List<string>();
        foreach (var home in Homes)
        {
            var root = Path.Combine(home, "state.db");
            if (File.Exists(root)) output.Add(root);
            var profiles = Path.Combine(home, "profiles");
            if (!Directory.Exists(profiles)) continue;
            IEnumerable<string> entries;
            try
            {
                entries = Directory.EnumerateDirectories(profiles).Select(WinPaths.LastComponent)
                    .OrderBy(n => n, StringComparer.Ordinal).ToList();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (var entry in entries)
            {
                var candidate = Path.Combine(profiles, entry, "state.db");
                if (File.Exists(candidate)) output.Add(candidate);
            }
        }
        return output;
    }

    public bool Detect() => DbFiles().Count > 0;

    sealed record Source(string Path, List<Row> Rows, List<Row> Messages, bool HasUsage);

    static Source ReadSource(string path)
    {
        using var src = SqliteDb.OpenReadOnly(path);
        var tables = src.Query("SELECT name FROM sqlite_master WHERE type='table'").Select(r => r.Str("name")).ToHashSet();
        var hasUsage = tables.Contains("session_model_usage");
        var rows = hasUsage
            ? src.Query(tables.Contains("sessions")
                ? "SELECT u.*, s.display_name FROM session_model_usage u LEFT JOIN sessions s ON s.id = u.session_id"
                : "SELECT u.*, NULL AS display_name FROM session_model_usage u")
            : [];
        List<Row> messages = [];
        if (tables.Contains("messages"))
        {
            try
            {
                messages = src.Query("SELECT id,session_id,role,tool_call_id,tool_calls,tool_name,effect_disposition,timestamp FROM messages ORDER BY id");
            }
            catch (SqliteException)
            {
                // 旧版 messages 表缺列：只放弃活动元数据，用量照常入库
                if (ScanDiagnostics.Current is { } d) d.ReadErrors++;
            }
        }
        return new Source(path, rows, messages, hasUsage);
    }

    /// <summary>身份六元组（元素可为 NULL，对齐 Python 的 None）。</summary>
    static string?[] Identity(Row row) => IdentityKeys.Select(k => row[k] as string).ToArray();

    static string IdentityKey(string?[] parts) => string.Join("|", parts.Select(p => p ?? "None"));

    static (long, long, long, long) Counts(Row row) =>
        (row.Int("input_tokens"), row.Int("output_tokens"), row.Int("cache_read_tokens"), row.Int("cache_write_tokens"));

    (int Added, int Updated) ScanActivity(UsageStore store, Source source)
    {
        int added = 0, updated = 0;
        string? realPath = null;
        foreach (var row in source.Messages)
        {
            var rawTs = row.Double("timestamp");
            var ts = (long)(rawTs > 0 && rawTs < 1e12 ? rawTs * 1000 : rawTs);
            long? at = ts == 0 ? null : ts;
            if (row.Str("role") == "assistant" && row.StrOrNull("tool_calls") is { } callsText
                                             && PyJson.TryParse(callsText, out var parsed))
            {
                var calls = parsed switch
                {
                    List<object?> list => list.OfType<Dictionary<string, object?>>().ToList(),
                    Dictionary<string, object?> one => [one],
                    _ => [],
                };
                for (var index = 0; index < calls.Count; index++)
                {
                    var call = calls[index];
                    var fn = call.GetDict("function") ?? call;
                    var rawName = PyJson.OrString(fn.Get("name"), call.Get("name"));
                    var callId = PyJson.OrString(call.Get("call_id"), call.Get("id"), call.Get("tool_call_id"));
                    if (rawName.Length == 0) continue;
                    realPath ??= WinPaths.Real(source.Path);
                    var change = store.RecordActivity(Name,
                        $"{realPath}|message|{row.Int("id")}|{(callId.Length == 0 ? index.ToString() : callId)}", rawName,
                        row.Str("session_id"), callId: callId, startedAt: at, sourceKind: "hermes_messages",
                        arguments: fn.Get("arguments"));
                    added += change.Added;
                    updated += change.Updated;
                }
            }
            else if (row.Str("role") == "tool" && row.StrOrNull("tool_call_id") is { } toolCallId)
            {
                var status = ActivityNormalizer.Status(row["effect_disposition"]);
                if (status == "unknown") status = "success";
                updated += store.CompleteActivity(Name, toolCallId, status, at);
            }
        }
        return (added, updated);
    }

    /// <summary>旧全局键的归属仲裁：先精确匹配，再单候选/单调延续；有歧义的保留旧行。</summary>
    Dictionary<string, string?> LegacyOwners(UsageStore store, List<Source> sources)
    {
        var groups = new Dictionary<string, List<(string Path, Row Row)>>();
        foreach (var source in sources)
        foreach (var row in source.Rows)
        {
            var key = IdentityKey(Identity(row));
            if (!groups.TryGetValue(key, out var list)) groups[key] = list = [];
            list.Add((source.Path, row));
        }
        var owners = new Dictionary<string, string?>();
        foreach (var (key, candidates) in groups)
        {
            var old = store.Conn.QueryOne("SELECT * FROM usage_events WHERE tool=? AND src_key=? AND source_scope=''", Name, key);
            if (old is null) continue;
            var oldCounts = (old.Int("input"), old.Int("output"), old.Int("cache_read"), old.Int("cache_write"));
            var exact = candidates.Where(c => Counts(c.Row) == oldCounts
                                              && (c.Row.StrOrNull("display_name") ?? c.Row.StrOrNull("session_id") ?? "")
                                              == old.Str("project")).ToList();
            var monotonic = candidates.Where(c =>
            {
                var n = Counts(c.Row);
                return n.Item1 >= oldCounts.Item1 && n.Item2 >= oldCounts.Item2 && n.Item3 >= oldCounts.Item3
                       && n.Item4 >= oldCounts.Item4;
            }).ToList();
            var selected = exact.Count > 0 ? exact : candidates.Count == 1 ? candidates : monotonic;
            owners[key] = selected.Count > 0 ? selected[0].Path : null; // null = 有歧义，保留旧行
        }
        return owners;
    }

    (int Added, int Updated, int Resets) ScanOne(UsageStore store, Source source, PriceTable prices,
        Dictionary<string, string?> owners)
    {
        int added = 0, resets = 0;
        var observedAt = store.NowMs();
        var scope = WinPaths.Real(source.Path);
        foreach (var row in source.Rows)
        {
            var parts = Identity(row);
            var key = IdentityKey(parts);
            // 新版 hermes 常把 actual 记为 0 / unknown：视为未知成本，交给价格表估算。
            var actual = row.DoubleOrNull("actual_cost_usd") ?? 0;
            var estimated = row.DoubleOrNull("estimated_cost_usd") ?? 0;
            double? native;
            string origin;
            if (actual > 0) (native, origin) = (actual, "native");
            else if (estimated > 0) (native, origin) = (estimated, "provider_estimate");
            else (native, origin) = (null, "priced");
            // Python: key if key not in owners or owners[key] == path else None
            var legacyKey = !owners.TryGetValue(key, out var owner) ? key : owner == source.Path ? key : null;
            var c = Counts(row);
            var result = store.PutSnapshot(Name, scope, PythonJson.Dumps(parts), row.Str("session_id"),
                row.StrOrNull("display_name") ?? row.StrOrNull("session_id") ?? "", row.Str("model"),
                c.Item1, c.Item2, c.Item3, c.Item4, native, origin, prices, legacyKey, observedAt);
            store.SetSessionTitle(Name, row.Str("session_id"), row.StrOrNull("display_name") ?? "");
            added += result.Added;
            resets += result.CounterResets;
        }
        return (added, source.Rows.Count, resets);
    }

    public ScanOutcome Scan(UsageStore store, PriceTable prices, bool full)
    {
        var files = DbFiles();
        if (!store.Conn.InTransaction) store.Conn.BeginImmediate();
        var sources = files.Select(ReadSource).ToList();
        var owners = LegacyOwners(store, sources);
        var outcome = new ScanOutcome { Files = files.Count };
        var missingUsage = 0;
        foreach (var source in sources)
        {
            if (!source.HasUsage) missingUsage++;
            var (a, u, r) = ScanOne(store, source, prices, owners);
            outcome.Added += a;
            outcome.Updated += u;
            outcome.CounterResets += r;
            var (aa, au) = ScanActivity(store, source);
            outcome.ActivityAdded += aa;
            outcome.ActivityUpdated += au;
        }
        var unresolved = store.Conn.ScalarInt(
            "SELECT COUNT(*) FROM usage_events WHERE tool=? AND source_scope='' AND time_quality='unallocated'", Name);
        var cursor = new Dictionary<string, object?> { ["mode"] = "snapshots" };
        ActivityNormalizer.MarkCurrent(cursor);
        store.SetScanCursor(Name, cursor);
        var warnings = new List<string>();
        if (unresolved > 0) warnings.Add($"保留 {unresolved} 条无法映射 profile 的未分配历史，可能与现存来源重叠");
        if (missingUsage > 0) warnings.Add($"{missingUsage} 个 state.db 缺少 session_model_usage 表，已跳过其用量");
        if (warnings.Count > 0) outcome.Warning = string.Join("；", warnings);
        return outcome;
    }
}
