using TokenTracker.Core.Json;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Quotas;

public sealed record QuotaWindowConfig(string? Label, long? LimitTokens, double? LimitUsd);

public sealed record QuotaEntryConfig(string Id, string Name, string? Plan, string Tool, string? ModelPrefix,
    string? Official, bool? IncludeCache, IReadOnlyDictionary<string, QuotaWindowConfig> Windows);

/// <summary>配额配置（移植 Quotas/QuotaEstimator.swift 的 QuotasConfig）。</summary>
public sealed record QuotasConfig(IReadOnlyList<QuotaEntryConfig> Entries)
{
    /// <summary>与 Python DEFAULT_QUOTAS / macOS 内置配置一致。</summary>
    public static QuotasConfig Default { get; } = new(
    [
        new("claude", "Claude Code", "Pro/Max", "claude", null, "claude-oauth", null, new Dictionary<string, QuotaWindowConfig>
        {
            ["5h"] = new("5 小时", 100_000_000, null),
            ["7d"] = new("周 (7天)", 400_000_000, null),
        }),
        new("kimi", "Kimi", "Kimi for Coding", "kimi", null, "kimi", null, new Dictionary<string, QuotaWindowConfig>
        {
            ["5h"] = new("5 小时", 50_000_000, null),
            ["7d"] = new("周 (7天)", 200_000_000, null),
            ["month"] = new("月度", 800_000_000, null),
        }),
        new("go", "OpenCode Go", "GO 订阅 ($12/5h, $30/周, $60/月)", "dsh", "deepseek", "go", null,
            new Dictionary<string, QuotaWindowConfig>
            {
                ["5h"] = new("5 小时", null, 12),
                ["7d"] = new("周 (7天)", null, 30),
                ["month"] = new("月度", null, 60),
            }),
        new("codex", "Codex", "ChatGPT 订阅", "codex", null, "codex", null, new Dictionary<string, QuotaWindowConfig>
        {
            ["5h"] = new("5 小时", 100_000_000, null),
            ["7d"] = new("周 (7天)", 500_000_000, null),
        }),
    ]);

    /// <summary>解析 quotas.json；缺失或格式不符返回内置默认。</summary>
    public static QuotasConfig Load(string? path)
    {
        if (string.IsNullOrEmpty(path) || PyJson.ReadObjectFile(path)?.Get("entries") is not List<object?> list)
            return Default;
        var entries = new List<QuotaEntryConfig>();
        foreach (var item in list)
        {
            if (item is not Dictionary<string, object?> e || e.Get("id") is not string id || e.Get("name") is not string name
                || e.Get("tool") is not string tool || e.GetDict("windows") is not { } rawWindows) return Default;
            var windows = new Dictionary<string, QuotaWindowConfig>();
            foreach (var (key, value) in rawWindows)
            {
                if (value is not Dictionary<string, object?> w) return Default;
                windows[key] = new QuotaWindowConfig(w.Get("label") as string, PyJson.AsLong(w.Get("limit_tokens")),
                    PyJson.AsNumber(w.Get("limit_usd")));
            }
            entries.Add(new QuotaEntryConfig(id, name, e.Get("plan") as string, tool, e.Get("model_prefix") as string,
                e.Get("official") as string, e.Get("include_cache") as bool?, windows));
        }
        return new QuotasConfig(entries);
    }

    public static QuotasConfig LoadEffective() => Load(Environment.GetEnvironmentVariable("TOKENTRACKER_QUOTAS"));
}

/// <summary>官方窗口数据（由各 provider 填充）。</summary>
public sealed record OfficialWindow(double? Pct, double? Used = null, double? Limit = null, string? ResetsAt = null,
    string? Unit = null);

/// <summary>官方一次抓取的完整结果（含降级/过期元信息）。</summary>
public sealed record OfficialResult(IReadOnlyDictionary<string, OfficialWindow>? Windows = null, double? SampledAt = null,
    int? StaleMin = null, string? Error = null, string? Detail = null, string? Plan = null, string? Via = null);

public sealed record QuotaWindowResult(string Key, string Label, string Unit, double? Pct, double? Used, double? Limit,
    string? ResetsAt, string Source, bool Stale, double? Unallocated);

public sealed record QuotaEntryResult(string Id, string Name, string Plan, string Source, string? Via, string Note,
    IReadOnlyList<QuotaWindowResult> Windows);

/// <summary>移植 QuotaEstimator.swift（quotas.py）：固定窗口（5 小时 / 7 天 / 月度），官方数据优先、本地估算兜底。</summary>
public static class QuotaEstimator
{
    static readonly string[] WindowOrder = ["5h", "7d", "month"];

    /// <summary>窗口起点（月度=本月 1 日 00:00 本地；其余滑动窗口）。</summary>
    public static long WindowStart(string key, long nowMs)
    {
        switch (key)
        {
            case "5h": return nowMs - 5L * 3600 * 1000;
            case "7d": return nowMs - 7L * 24 * 3600 * 1000;
            case "month":
                var now = DateTimeOffset.FromUnixTimeMilliseconds(nowMs).LocalDateTime;
                return new DateTimeOffset(new DateTime(now.Year, now.Month, 1, 0, 0, 0, DateTimeKind.Local)).ToUnixTimeMilliseconds();
            default: return nowMs - 24L * 3600 * 1000;
        }
    }

    /// <summary>officialProvider 返回 null 表示该来源无官方数据（降级本地）。</summary>
    public static List<QuotaEntryResult> Compute(UsageStore store, QuotasConfig config, long nowMs,
        Func<string, OfficialResult?>? officialProvider = null)
    {
        var entries = new List<QuotaEntryResult>();
        foreach (var entry in config.Entries)
        {
            var official = entry.Official is not null ? officialProvider?.Invoke(entry.Official) : null;
            var windows = new List<QuotaWindowResult>();
            var anyOfficial = false;
            foreach (var key in WindowOrder)
            {
                if (!entry.Windows.TryGetValue(key, out var lim)) continue;
                var isUsd = lim.LimitUsd is not null;
                var unit = isUsd ? "usd" : "tokens";
                // Python: tokens 缺省 0、usd 缺省 None
                double? limit = isUsd ? lim.LimitUsd : lim.LimitTokens ?? 0;
                var start = WindowStart(key, nowMs);
                var used = store.WindowUsage(start, entry.Tool, entry.ModelPrefix, entry.IncludeCache ?? false, isUsd);
                // 官方覆盖
                if (official?.Windows is { } ow && ow.TryGetValue(key, out var w) && w.Pct is { } officialPct)
                {
                    anyOfficial = true;
                    windows.Add(new QuotaWindowResult(key, lim.Label ?? key, w.Unit ?? "pct",
                        PythonJson.RoundHalfEven(officialPct, 1), w.Used, w.Limit, w.ResetsAt, "official",
                        (official.StaleMin ?? 0) > 0, null));
                    continue;
                }
                var limitValue = limit ?? 0;
                double? pct = limitValue != 0 ? used / limitValue * 100 : used == 0 ? 0 : null;
                var unallocated = store.WindowUnallocated(start, entry.Tool, entry.ModelPrefix, entry.IncludeCache ?? false, isUsd);
                windows.Add(new QuotaWindowResult(key, lim.Label ?? key, unit,
                    pct is { } p ? PythonJson.RoundHalfEven(p, 1) : null,
                    isUsd ? PythonJson.RoundHalfEven(used, 2) : (long)used, limit, null, "local", false,
                    isUsd ? PythonJson.RoundHalfEven(unallocated, 2) : (long)unallocated));
            }
            var note = "";
            if (official is not null && (official.StaleMin ?? 0) > 0)
                note = $"官方接口暂时不可用（{official.Detail ?? official.Error ?? "限流"}），显示 {official.StaleMin ?? 0} 分钟前的官方数据";
            else if (official?.Error is not null)
                note = official.Detail ?? official.Error ?? "";
            var plan = entry.Plan ?? "";
            if (official?.Plan is { Length: > 0 } officialPlan)
            {
                // 官方 plan 与配置重复时只保留信息量更大的一边
                plan = plan.Length == 0 || plan.Contains(officialPlan, StringComparison.OrdinalIgnoreCase)
                    ? plan
                    : $"{officialPlan} · {plan}".Trim(' ', '·');
            }
            entries.Add(new QuotaEntryResult(entry.Id, entry.Name, plan, anyOfficial ? "official" : "local",
                anyOfficial ? official?.Via : null, note, windows));
        }
        return entries;
    }
}
