using TokenTracker.Core.Json;

namespace TokenTracker.Core.Billing;

/// <summary>
/// OpenCode Go 配额（移植 GoBilling.swift）：Key 自动发现（环境变量 → opencode auth.json）→
/// opencode.ai/zen/go/v1/usage。必须带浏览器 UA（否则 Cloudflare 1010）；间歇性连接重置自动重试。
/// 静态 API Key 没有轮换风险，照搬全部逻辑。
/// </summary>
public sealed class GoBilling(BillingContext ctx)
{
    const string QuotaUrl = "https://opencode.ai/zen/go/v1/usage";
    const string BrowserUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

    internal string? ApiKey()
    {
        foreach (var name in new[] { "OPENCODE_GO_API_KEY", "OPENCODE_API_KEY" })
            if (ctx.Env(name)?.Trim() is { Length: > 0 } value) return value;
        foreach (var path in new[]
                 {
                     Path.Combine(ctx.Home, ".local", "share", "opencode", "auth.json"),
                     Path.Combine(ctx.Home, ".config", "opencode", "auth.json"),
                 })
        {
            if (PyJson.ReadObjectFile(path)?.GetDict("opencode-go")?.Get("key") is string { Length: > 0 } key) return key;
        }
        return null;
    }

    public Dictionary<string, object?> Usage()
    {
        if (ApiKey() is not { } key)
            return BillingNet.Error("no_key", "未找到 OpenCode Go API Key：opencode 登录后（auth.json）或用 OPENCODE_GO_API_KEY 环境变量");
        var status = 0;
        var data = new Dictionary<string, object?>();
        var lastErr = "";
        for (var attempt = 0; attempt < 3; attempt++)
        {
            (status, data) = ctx.Http(QuotaUrl, new Dictionary<string, string>
            {
                ["Authorization"] = $"Bearer {key}", ["User-Agent"] = BrowserUa,
                ["Accept"] = "application/json, text/plain, */*", ["Connection"] = "close",
            }, null, "GET");
            if (status != 0) break;
            lastErr = data.Get("error") as string ?? "connection reset";
            if (attempt < 2) Thread.Sleep(2000);
        }
        if (status is 401 or 403) return BillingNet.Error("no_sub", "没有生效的 OpenCode Go 订阅，或 API Key 无效");
        if (status != 200) return BillingNet.Error($"http_{status}", $"Go 额度接口返回 {status}（{lastErr}）", data.Get("_retry_after"));
        if (data.GetDict("usage") is not { } usage) return BillingNet.Error("no_usage", "Go 额度响应缺少 usage 字段");
        var windows = new Dictionary<string, object?>();
        foreach (var (src, key2) in new[] { ("rolling", "5h"), ("weekly", "7d"), ("monthly", "month") })
        {
            if (usage.GetDict(src) is not { } w || PyJson.AsNumber(w.Get("percent")) is not { } percent) continue;
            windows[key2] = new Dictionary<string, object?> { ["pct"] = percent, ["resets_at"] = BillingNet.IsoMs(w.Get("resetsAt")) };
        }
        if (windows.Count == 0) return BillingNet.Error("no_windows", "Go 额度响应无可用窗口");
        return new Dictionary<string, object?> { ["windows"] = windows, ["plan"] = "OpenCode Go" };
    }
}
