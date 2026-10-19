using TokenTracker.Core.Json;
using TokenTracker.Core.Quotas;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Billing;

/// <summary>四家官方配额抓取的入口：缓存合并 + 结果转 OfficialResult（移植 OfficialQuotaService.swift）。</summary>
public sealed class OfficialQuotaService(BillingContext? ctx = null, OfficialCache? cache = null)
{
    public BillingContext Ctx { get; } = ctx ?? new BillingContext();
    public OfficialCache Cache { get; } = cache ?? new OfficialCache();

    /// <summary>原始抓取（无缓存）。name ∈ claude-oauth / kimi / codex / go。</summary>
    public Dictionary<string, object?> Fetch(string name) => name switch
    {
        "claude-oauth" => new ClaudeBilling(Ctx).OAuthUsage(),
        "kimi" => new KimiBilling(Ctx).Usage(),
        "codex" => new CodexBilling(Ctx).Usage(),
        "go" => new GoBilling(Ctx).Usage(),
        _ => new Dictionary<string, object?> { ["error"] = "unknown_provider" },
    };

    /// <summary>带缓存的抓取（kimi 挂凭据文件版本；codex 按账号区分缓存）。</summary>
    public Dictionary<string, object?> Cached(string name, bool force = false)
    {
        var cacheKey = name;
        Func<string>? versionFn = null;
        if (name == "codex") cacheKey += ":" + PythonJson.Sha256Hex(new CodexBilling(Ctx).AccountId());
        if (name == "kimi") versionFn = new KimiBilling(Ctx).CredentialsVersion;
        return Cache.Cached(cacheKey, () => Fetch(name), force, versionFn);
    }

    public OfficialResult ProviderResult(string name, bool force = false) => ToOfficialResult(Cached(name, force));

    /// <summary>Python 字典语义 → OfficialResult。</summary>
    public static OfficialResult ToOfficialResult(Dictionary<string, object?> raw)
    {
        Dictionary<string, OfficialWindow>? windows = null;
        if (raw.GetDict("windows") is { } rawWindows)
        {
            windows = new Dictionary<string, OfficialWindow>();
            foreach (var (key, value) in rawWindows)
            {
                if (value is not Dictionary<string, object?> w) continue;
                string? resetsAt = null;
                if (PyJson.AsLong(w.Get("resets_at")) is { } ms && ms > 0)
                    resetsAt = DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",
                        System.Globalization.CultureInfo.InvariantCulture);
                windows[key] = new OfficialWindow(BillingNet.Pct(w.Get("pct")), PyJson.AsNumber(w.Get("used")),
                    PyJson.AsNumber(w.Get("limit")), resetsAt, w.Get("unit") as string);
            }
        }
        return new OfficialResult(windows, PyJson.AsNumber(raw.Get("_sampled_at")), (int?)PyJson.AsLong(raw.Get("_stale_min")),
            raw.Get("error") as string, raw.Get("detail") as string ?? raw.Get("_err") as string, raw.Get("plan") as string,
            raw.Get("_via") as string);
    }
}
