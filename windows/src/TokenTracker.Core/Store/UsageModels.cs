namespace TokenTracker.Core.Store;

public sealed record TimeSummary(long UnallocatedTokens, double UnallocatedCost, long UnallocatedEvents,
    long EstimatedTokens);

public sealed class ToolStats
{
    public string Tool { get; set; } = "";
    public long Sessions { get; set; }
    public long Input { get; set; }
    public long Output { get; set; }
    public long CacheRead { get; set; }
    public long CacheWrite { get; set; }
    public long Tokens { get; set; }
    public long Events { get; set; }
    public long Unpriced { get; set; }
    public long EstimatedTokens { get; set; }
    public long UnallocatedTokens { get; set; }
    public double Cost { get; set; }

    /// <summary>缓存命中只属于输入侧；模型输出不能进入命中率分母。</summary>
    public long InputSideTokens => Input + CacheRead + CacheWrite;

    public double? CacheHitRate => InputSideTokens > 0 ? (double)CacheRead / InputSideTokens * 100 : null;

    public ToolStats()
    {
    }

    internal ToolStats(Row row)
    {
        Tool = row.Str("tool");
        Sessions = row.Int("sessions");
        Input = row.Int("input");
        Output = row.Int("output");
        CacheRead = row.Int("cache_read");
        CacheWrite = row.Int("cache_write");
        Tokens = row.Int("tokens");
        Events = row.Int("events");
        Unpriced = row.Int("unpriced");
        EstimatedTokens = row.Int("estimated_tokens");
        UnallocatedTokens = row.Int("unallocated_tokens");
        Cost = row.Double("cost");
    }
}

public sealed record StatsResult(List<ToolStats> Rows, ToolStats Total, TimeSummary Summary);

public sealed record DailyRow(string Tool, string Day, ToolStats Stats);

public sealed record ModelRow(string Tool, string Model, ToolStats Stats);

public sealed record ActivitySummaryRow(string Name, long Calls, long Sessions, long Agents, long Success,
    long Errors, long Denied, long Unknown, long Exact, long Derived, long LastUsed);

public sealed record ObservationInterval(long? IntervalStart, long Ts, long Tokens);

public sealed class SessionDetail
{
    public string Project { get; set; } = "";
    public ToolStats Total { get; set; } = new();
    public long? FirstTs { get; set; }
    public long? LastTs { get; set; }
    public List<ModelRow> Models { get; set; } = [];
    public List<ObservationInterval> ObservationIntervals { get; set; } = [];
    public List<Activity.ActivityEvent> Activity { get; set; } = [];
    public List<ActivitySummaryRow> ActivitySummary { get; set; } = [];
}

public sealed class SessionRow
{
    public required string Tool { get; init; }
    public required string SessionId { get; init; }
    public string Project { get; init; } = "";
    public string? LastSeen { get; init; }
    public long? Ts { get; init; }
    public string Model { get; init; } = "";
    public string? Title { get; init; }
    public required ToolStats Stats { get; init; }
    public long ActivityExact { get; set; }
    public long ActivityDerived { get; set; }
    public long Skills { get; set; }
}
