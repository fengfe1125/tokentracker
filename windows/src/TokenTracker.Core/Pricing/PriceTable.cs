using TokenTracker.Core.Json;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Pricing;

/// <summary>单档费率（美元 / 百万 token；字段缺失按 0）。</summary>
public sealed record PriceRate(double Input = 0, double Output = 0, double CacheRead = 0, double CacheWrite = 0);

/// <summary>
/// 价格表（移植 Pricing/PriceTable.swift，匹配语义以 pricing.py 为准）：
/// 模型名先精确、再最长子串（不区分大小写，按文件顺序、仅更长才替换），最后回退 default；
/// 未匹配返回 null（只统计 token、不计费）。
/// </summary>
public sealed class PriceTable
{
    public PriceRate? Fallback { get; }
    public IReadOnlyList<KeyValuePair<string, PriceRate>> Models { get; }
    readonly Dictionary<string, PriceRate> _exact;

    public PriceTable(PriceRate? fallback, IEnumerable<KeyValuePair<string, PriceRate>> models)
    {
        Fallback = fallback;
        Models = models.ToList();
        _exact = new Dictionary<string, PriceRate>(StringComparer.Ordinal);
        foreach (var (k, v) in Models) _exact[k] = v;
    }

    /// <summary>与 Python DEFAULT_PRICES 一致的兜底表（文件缺失/损坏时使用）。</summary>
    public static PriceTable Default { get; } = new(
        new PriceRate(2.0, 10.0, 0.4, 2.0),
        [
            new("claude-opus-4-5", new PriceRate(5.0, 25.0, 0.5, 1.25)),
            new("claude-sonnet-4-5", new PriceRate(3.0, 15.0, 0.3, 0.75)),
            new("claude-haiku", new PriceRate(1.0, 5.0, 0.1, 0.25)),
            new("gpt-5", new PriceRate(1.25, 10.0, 0.125, 1.25)),
            new("gpt-5.6-luna", new PriceRate(2.0, 12.0, 0.2, 2.0)),
            new("deepseek-v4-flash", new PriceRate(0.22, 0.66, 0.007, 0.22)),
            new("deepseek-v4-pro", new PriceRate(0.66, 1.98, 0.022, 0.66)),
            new("kimi-k2", new PriceRate(0.6, 2.5, 0.1, 0.6)),
            new("kimi-k3", new PriceRate(0.6, 2.5, 0.1, 0.6)),
            new("grok-4.6", new PriceRate(3.0, 15.0, 0.3, 3.0)),
        ]);

    /// <summary>解析 prices.json 文本。含 "models" 键 → {models, 顶层 default}；否则整表视为 models。</summary>
    public static PriceTable? Parse(string? text)
    {
        var dict = PyJson.ParseObject(text);
        if (dict is null) return null;
        static PriceRate? Rate(object? value)
        {
            if (value is not Dictionary<string, object?> d) return null;
            double Num(string key) => PyJson.AsDouble(d.Get(key)) ?? 0;
            return new PriceRate(Num("input"), Num("output"), Num("cache_read"), Num("cache_write"));
        }
        static IEnumerable<KeyValuePair<string, PriceRate>> Rates(Dictionary<string, object?> source) =>
            source.Select(kv => (kv.Key, Rate: Rate(kv.Value)))
                .Where(x => x.Rate is not null)
                .Select(x => new KeyValuePair<string, PriceRate>(x.Key, x.Rate!));

        if (dict.Get("models") is Dictionary<string, object?> nested)
            return new PriceTable(Rate(dict.Get("default")), Rates(nested));
        return new PriceTable(null, Rates(dict));
    }

    public static PriceTable Load(string path) =>
        Parse(Platform.SharedFile.ReadAllText(path)) ?? Default;

    /// <summary>运行时价格表：TOKENTRACKER_PRICES → 构建时嵌入的仓库 prices.json → 内置默认。</summary>
    public static PriceTable LoadEffective()
    {
        if (Environment.GetEnvironmentVariable("TOKENTRACKER_PRICES") is { Length: > 0 } env) return Load(env);
        return Parse(EmbeddedResources.ReadText("TokenTracker.prices.json")) ?? Default;
    }

    /// <summary>返回成本（美元）；模型为空或无费率可匹配时返回 null。</summary>
    public double? Cost(string model, long input, long output, long cacheRead = 0, long cacheWrite = 0)
    {
        if (string.IsNullOrEmpty(model)) return null;
        var m = model.ToLowerInvariant();
        if (!_exact.TryGetValue(m, out var rate))
        {
            // 子串匹配取最长命中键，避免 "gpt-5" 抢先命中 "gpt-5.6-luna"
            var best = -1;
            foreach (var (key, value) in Models)
            {
                var k = key.ToLowerInvariant();
                if (m.Contains(k, StringComparison.Ordinal) && k.Length > best)
                {
                    best = k.Length;
                    rate = value;
                }
            }
        }
        var resolved = rate ?? Fallback;
        if (resolved is null) return null;
        var cost = (input * resolved.Input + output * resolved.Output
                    + cacheRead * resolved.CacheRead + cacheWrite * resolved.CacheWrite) / 1e6;
        // Python round(x, 8) 是 half-even
        return PythonJson.RoundHalfEven(cost, 8);
    }
}
