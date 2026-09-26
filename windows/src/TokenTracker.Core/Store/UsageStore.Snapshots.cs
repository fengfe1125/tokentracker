using TokenTracker.Core.Json;
using TokenTracker.Core.Pricing;

namespace TokenTracker.Core.Store;

public sealed partial class UsageStore
{
    /// <summary>
    /// 聚合快照引擎：持久化一次累计观测，只入库其差量（不 commit）。
    /// 首次观测没有可靠事件时间；不变的观测也会推进区间下界；计数器下降则建立新基线，不产生负事件。
    /// </summary>
    public (int Added, int CounterResets) PutSnapshot(string tool, string sourceScope, string identity,
        string sessionId, string project, string model, long input = 0, long output = 0, long cacheRead = 0,
        long cacheWrite = 0, double? nativeCost = null, string costSource = "native", PriceTable? prices = null,
        string? legacyKey = null, long? observedAt = null)
    {
        prices ??= PriceTable.Default;
        if (!Conn.InTransaction) Conn.BeginImmediate();
        var now = observedAt ?? NowMs();
        var digest = PythonJson.Sha256Hex(PythonJson.Dumps(new object?[] { sourceScope, identity }));
        var values = new Dictionary<string, object?>
        {
            ["input"] = Math.Max(0, input),
            ["output"] = Math.Max(0, output),
            ["cache_read"] = Math.Max(0, cacheRead),
            ["cache_write"] = Math.Max(0, cacheWrite),
            ["native_cost"] = nativeCost,
            ["native_source"] = nativeCost is not null ? costSource : null,
        };

        var row = Conn.QueryOne("SELECT * FROM aggregate_snapshots WHERE tool=? AND source_scope=? AND identity=?",
            tool, sourceScope, identity);
        Dictionary<string, object?>? previous = null;
        long? start = null;
        long revision = -1;
        if (row is not null)
        {
            previous = PyJson.ParseObject(row.Str("values_json")) ?? new Dictionary<string, object?>();
            start = row.IntOrNull("observed_at");
            revision = row.Int("revision");
        }
        else if (legacyKey is not null)
        {
            var legacy = Conn.QueryOne("SELECT * FROM usage_events WHERE tool=? AND src_key=? AND source_scope=''",
                tool, legacyKey);
            if (legacy is not null)
            {
                var prev = new Dictionary<string, object?>();
                foreach (var k in TokenColumns) prev[k] = legacy.Int(k);
                prev["accounted_cost"] = legacy.DoubleOrNull("cost") ?? 0;
                var legacySource = legacy.Str("cost_source");
                var legacyNative = legacySource is "native" or "provider_estimate" ? legacySource : null;
                prev["native_source"] = legacyNative;
                prev["native_cost"] = legacyNative is not null ? legacy.DoubleOrNull("cost") : null;
                prev["legacy_key"] = legacyKey;
                Conn.Execute("UPDATE usage_events SET time_quality='unallocated',source_kind='aggregate_snapshot',source_scope=? WHERE id=?",
                    sourceScope, legacy.Int("id"));
                previous = prev;
            }
        }
        var adoptedKey = previous.Get("legacy_key") as string ?? legacyKey;

        const string ledgerWhere = "tool=? AND (src_key LIKE ? OR (src_key=? AND source_scope=?))";
        object?[] ledgerArgs = [tool, $"aggregate|{digest}|%", adoptedKey ?? "", sourceScope];
        double LedgerCost() =>
            Conn.QueryOne($"SELECT COALESCE(SUM(cost),0) AS c FROM usage_events WHERE {ledgerWhere}", ledgerArgs)
                ?.Double("c") ?? 0;

        var costOffset = PyJson.AsNumber(previous.Get("cost_offset")) ?? 0;
        double accounted;
        if (previous is not null && previous.ContainsKey("accounted_cost"))
            accounted = PyJson.AsNumber(previous["accounted_cost"]) ?? 0;
        else
            accounted = LedgerCost() - costOffset; // 成本账本出现之前的快照：真实账本减去旧纪元留存

        long PrevInt(string key) => PyJson.AsLong(previous.Get(key)) ?? 0;
        long Val(string key) => (long)values[key]!;
        var reset = previous is not null && TokenColumns.Any(k => Val(k) < PrevInt(k));
        var delta = TokenColumns.ToDictionary(k => k, k => Val(k) - (previous is not null ? PrevInt(k) : 0));

        var added = 0;
        void Emit(Dictionary<string, long> counters, double? cost, string origin, string quality)
        {
            revision += 1;
            added += PutEvent(tool, $"aggregate|{digest}|{revision}", sessionId, project, now, model,
                counters["input"], counters["output"], counters["cache_read"], counters["cache_write"],
                cost, timeQuality: quality, intervalStart: quality == "observed" ? start : null,
                costSource: origin, sourceKind: "aggregate_snapshot", sourceScope: sourceScope);
        }

        if (!reset)
        {
            var prevNative = PyJson.AsNumber(previous.Get("native_cost"));
            var continuousNative = previous is not null && nativeCost is not null && prevNative is not null
                                   && previous.Get("native_source") as string == costSource
                                   && nativeCost.Value >= prevNative.Value;
            if (previous is not null && nativeCost is not null && !continuousNative)
                accounted = LedgerCost() - costOffset; // reprice 可能已回填 NULL 成本：对账真实账本
            double? cost;
            string origin;
            if (nativeCost is not null && (previous is null || continuousNative))
            {
                cost = nativeCost.Value - (prevNative ?? 0);
                origin = costSource;
            }
            else
            {
                cost = prices.Cost(model, delta["input"], delta["output"], delta["cache_read"], delta["cache_write"]);
                origin = "estimate";
            }
            if (delta.Values.Any(v => v != 0) || (cost is not null && cost != 0))
            {
                Emit(delta, cost, origin, start is not null ? "observed" : "unallocated");
                accounted += cost ?? 0;
            }
            if (previous is not null && nativeCost is not null && !continuousNative)
            {
                // 首个权威累计成本（或来源切换）对账历史，不落入当前时间桶。
                var correction = nativeCost.Value - accounted;
                if (Math.Abs(correction) > 1e-9)
                    Emit(TokenColumns.ToDictionary(k => k, _ => 0L), correction, "native_adjustment", "unallocated");
                accounted = nativeCost.Value;
                // 这些未知单价已并入累计调整；后续 reprice 不得重复收费。
                Conn.Execute($"UPDATE usage_events SET cost=0,cost_source='native_included' WHERE {ledgerWhere} AND cost IS NULL",
                    ledgerArgs);
            }
            values["cost_offset"] = costOffset;
        }
        else
        {
            revision += 1;
            // 计数器重启：未来 native 成本相对此基线，而非旧纪元留存。
            accounted = nativeCost ?? prices.Cost(model, Val("input"), Val("output"), Val("cache_read"),
                Val("cache_write")) ?? 0;
            values["cost_offset"] = LedgerCost() - accounted;
        }
        values["accounted_cost"] = accounted;
        values["legacy_key"] = adoptedKey;

        var stored = values.Where(kv => kv.Value is not null).ToDictionary(kv => kv.Key, kv => kv.Value);
        Conn.Execute("INSERT OR REPLACE INTO aggregate_snapshots VALUES (?,?,?,?,?,?)",
            tool, sourceScope, identity, PyJson.Serialize(stored), now, revision);
        return (added, reset ? 1 : 0);
    }
}
