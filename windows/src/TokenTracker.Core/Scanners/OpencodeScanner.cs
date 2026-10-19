using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

/// <summary>
/// 移植 OpencodeScanner.swift（scanners/opencode.py）：session 累计字段按持久化快照计算差量；
/// 首次存量保留为时间未分配历史。只读打开对方数据库，读完即关，避免妨碍其 WAL 维护。
/// </summary>
public sealed class OpencodeScanner(string dbPath) : IScanner
{
    public string Name => "opencode";
    public string Detail => "~/.local/share/opencode/opencode.db";
    public string DbPath { get; } = WinPaths.Expand(dbPath);

    public bool Detect() => File.Exists(DbPath);

    /// <summary>model 字段可能是 JSON 字符串 / 对象 / 裸字符串。</summary>
    static string ModelId(object? raw)
    {
        switch (raw)
        {
            case null:
                return "";
            case string s:
                return PyJson.TryParse(s, out var parsed) ? ModelId(parsed) : s;
            case Dictionary<string, object?> dict:
                return dict.Get("id") as string ?? dict.Get("model") as string ?? dict.Get("providerID") as string ?? "";
            default:
                return PyJson.PyStr(raw);
        }
    }

    public ScanOutcome Scan(UsageStore store, PriceTable prices, bool full)
    {
        List<Row> sessions;
        List<Row>? parts = null;
        using (var src = SqliteDb.OpenReadOnly(DbPath))
        {
            sessions = src.Query("SELECT * FROM session");
            var tables = src.Query("SELECT name FROM sqlite_master WHERE type='table'").Select(r => r.Str("name")).ToHashSet();
            if (tables.Contains("part"))
                parts = src.Query("SELECT id,session_id,time_created,time_updated,data FROM part");
        }
        var observedAt = store.NowMs();
        var outcome = new ScanOutcome { Files = 1 };
        var scope = WinPaths.Real(DbPath);
        foreach (var row in sessions)
        {
            var id = row.Str("id");
            var directory = row.Str("directory");
            var result = store.PutSnapshot(Name, scope, id, id,
                directory.Length > 0 ? directory : row.Str("title"), ModelId(row["model"]),
                row.Int("tokens_input"), row.Int("tokens_output"), row.Int("tokens_cache_read"),
                row.Int("tokens_cache_write"), row.DoubleOrNull("cost"), prices: prices, legacyKey: id,
                observedAt: observedAt);
            if (WinPaths.IsAbsoluteProjectPath(directory))
                foreach (var e in store.Conn.Query("SELECT src_key FROM usage_events WHERE tool=? AND session_id=?", Name, id))
                    store.RecordProjectPath(Name, e.Str("src_key"), directory);
            store.SetSessionTitle(Name, id, row.Str("title"));
            outcome.Added += result.Added;
            outcome.CounterResets += result.CounterResets;
            outcome.Updated++;
        }
        foreach (var row in parts ?? [])
        {
            if (PyJson.ParseObject(row.StrOrNull("data")) is not { } obj
                || obj.Get("type") as string != "tool" || obj.Get("tool") is not string rawName) continue;
            var state = obj.GetDict("state");
            var timing = state.GetDict("time");
            var status = ActivityNormalizer.Status(state.Get("status"));
            var start = PyJson.OrInt(timing.Get("start"), row["time_created"]);
            var end = PyJson.OrInt(timing.Get("end"), status == "unknown" ? null : row["time_updated"]);
            var change = store.RecordActivity(Name, $"{scope}|part|{row.Str("id")}", rawName, row.Str("session_id"),
                callId: PyJson.OrString(obj.Get("callID"), obj.Get("callId")),
                startedAt: start == 0 ? null : start, endedAt: end == 0 ? null : end, status: status,
                sourceKind: "opencode_part", arguments: state.Get("input"));
            outcome.ActivityAdded += change.Added;
            outcome.ActivityUpdated += change.Updated;
        }
        var cursor = new Dictionary<string, object?> { ["mode"] = "snapshots", ["observed_at"] = observedAt };
        ActivityNormalizer.MarkCurrent(cursor);
        store.SetScanCursor(Name, cursor);
        return outcome;
    }
}
