using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;

namespace TokenTracker.Core.Billing;

/// <summary>
/// 移植 OfficialCache.swift（billing.py 的 _cached / 磁盘兜底）：
/// 成功 120s、失败 120s 退避；429 遵守 Retry-After（force 也不绕过）；成功兜底最长 24h 并标记过期（_stale_min）；
/// 磁盘缓存跨进程共享（与 Swift/Python 同格式 {key: [ts, data]}），只存配额数字。
/// </summary>
public sealed class OfficialCache
{
    public const double TtlOk = 120;
    public const double TtlErr = 120;
    public const double StaleMax = 24 * 3600;

    sealed class State
    {
        public readonly object Lock = new();
        public int Generation;
        public (double Ts, Dictionary<string, object?> Data)? Attempt;
        public (double Ts, Dictionary<string, object?> Data)? Success;
        public double RetryUntil;
        public double RateLimitUntil;
        public string? SourceVersion;
    }

    readonly Dictionary<string, State> _states = new();
    readonly object _statesLock = new();

    public string DiskPath { get; }
    public Func<double> Clock { get; set; }

    public OfficialCache(string? diskPath = null, Func<double>? clock = null)
    {
        DiskPath = diskPath ?? Path.Combine(WinPaths.DataDir, "official_cache.json");
        Clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
    }

    /// <summary>读磁盘缓存的成功结果；仅接受 24h 内的无错误成功结果。</summary>
    public (double Ts, Dictionary<string, object?> Data)? DiskLoad(string key)
    {
        if (PyJson.ReadObjectFile(DiskPath)?.Get(key) is not List<object?> { Count: 2 } record
            || PyJson.AsNumber(record[0]) is not { } ts || record[1] is not Dictionary<string, object?> payload
            || payload.Get("error") is not null) return null;
        var age = Clock() - ts;
        return age is >= 0 and <= StaleMax ? (ts, payload) : null;
    }

    /// <summary>成功结果落盘（跨进程共享，限流时互为兜底）；文件锁串行化 + 原子替换。</summary>
    public void DiskStore(string key, double ts, Dictionary<string, object?> data)
    {
        using var fileLock = FileLock.Acquire(DiskPath + ".lock", TimeSpan.FromSeconds(5));
        if (fileLock is null) return;
        var store = PyJson.ReadObjectFile(DiskPath) ?? new Dictionary<string, object?>();
        store[key] = new List<object?> { ts, data };
        SharedFile.AtomicWriteText(DiskPath, PyJson.Serialize(store));
    }

    Dictionary<string, object?> CachedResult(string key, State state, double now)
    {
        if (state.Attempt is not { } attempt) return new Dictionary<string, object?> { ["error"] = "unknown" };
        var data = attempt.Data;
        if (data.Get("_ok") is true)
        {
            if (now - attempt.Ts < TtlOk) return data;
            // 成功兜底也可能带上游限流：普通 TTL 结束后它是旧的
            data = new Dictionary<string, object?>
            {
                ["error"] = "http_429", ["detail"] = "官方接口限流，等待 Retry-After", ["_ok"] = false,
            };
        }
        var stale = state.Success;
        if (stale is { } existing && !(now - existing.Ts is >= 0 and <= StaleMax))
        {
            state.Success = null;
            stale = null;
        }
        if (stale is null && DiskLoad(key) is { } disk)
        {
            state.Success = disk;
            stale = disk;
        }
        if (stale is { } s)
        {
            var result = new Dictionary<string, object?>(s.Data)
            {
                ["_stale_min"] = (long)Math.Max(1, (int)((now - s.Ts) / 60)),
                ["_err"] = data.Get("detail") as string ?? data.Get("error") as string ?? "",
            };
            return result;
        }
        return data;
    }

    /// <summary>
    /// 合并同 provider 请求；成功与失败尝试分开保留。force 跳过普通 TTL，绝不跳过服务端限流。
    /// versionFn：来源文件版本（如 Kimi 凭据更新后下轮轮询重读，不必等失败退避）。
    /// </summary>
    public Dictionary<string, object?> Cached(string key, Func<Dictionary<string, object?>> fn, bool force = false,
        Func<string>? versionFn = null)
    {
        State state;
        int generation;
        lock (_statesLock)
        {
            if (!_states.TryGetValue(key, out state!)) _states[key] = state = new State();
            generation = state.Generation;
        }
        lock (state.Lock)
        {
            var now = Clock();
            var effectiveForce = force && generation == state.Generation;
            var version = versionFn?.Invoke();
            var sourceChanged = version != state.SourceVersion;
            if (state.Attempt is not null
                && (now < state.RateLimitUntil || (!effectiveForce && !sourceChanged && now < state.RetryUntil)))
                return CachedResult(key, state, now);
            // 先记版本再读凭据：并发 CLI 写入会在下轮轮询被注意到
            state.SourceVersion = version;
            Dictionary<string, object?> data;
            try
            {
                data = fn();
                data["_ok"] = data.Get("error") is null;
            }
            catch (Exception e)
            {
                data = new Dictionary<string, object?> { ["error"] = "network", ["detail"] = e.Message, ["_ok"] = false };
            }
            var finishedAt = Clock();
            if (data.Get("_ok") is true) data["_sampled_at"] = finishedAt;
            state.Attempt = (finishedAt, data);
            var retryAfter = data.Get("_retry_after") switch
            {
                string s when double.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, out var v) => Math.Max(0, v),
                var o => Math.Max(0, PyJson.AsNumber(o) ?? 0),
            };
            if (!double.IsFinite(retryAfter)) retryAfter = 0;
            if (data.Get("_ok") is true)
            {
                state.Success = (finishedAt, data);
                state.RetryUntil = finishedAt + Math.Max(TtlOk, retryAfter);
                DiskStore(key, finishedAt, data);
            }
            else
            {
                state.RetryUntil = finishedAt + Math.Max(TtlErr, retryAfter);
            }
            state.RateLimitUntil = retryAfter > 0 || data.Get("error") as string == "http_429" ? state.RetryUntil : 0;
            var result = CachedResult(key, state, finishedAt);
            state.Generation++;
            return result;
        }
    }
}
