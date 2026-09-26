using TokenTracker.Core.Json;

namespace TokenTracker.Core.Billing;

/// <summary>
/// Claude 官方配额（移植 ClaudeBilling.swift，Windows 只读版）：
/// 1. 桌面 App 采样文件 %APPDATA%\Claude\plan-usage-history.json（&lt;30min，无需凭据）；
/// 2. ~/.claude/.credentials.json 的 accessToken 调 usage 接口。
/// 与 macOS 不同：不刷新 token、不委托 CLI 刷新、不写任何凭据或快照——refresh token 会轮换，
/// 写回失败会把 Claude Code 登出，且该文件里还有其他服务的 mcpOAuth 密钥。
/// </summary>
public sealed class ClaudeBilling(BillingContext ctx)
{
    const string UsageUrl = "https://api.anthropic.com/api/oauth/usage";

    static readonly Dictionary<string, string> PlanNames = new()
    {
        ["pro"] = "Pro", ["max"] = "Max", ["team"] = "Team", ["enterprise"] = "Enterprise",
    };

    string CredentialsPath =>
        Path.Combine(ctx.Env("CLAUDE_CONFIG_DIR") is { Length: > 0 } dir ? dir : Path.Combine(ctx.Home, ".claude"),
            ".credentials.json");

    /// <summary>Claude 桌面 App 的配额采样文件（无需凭据）；样本 &lt;30 分钟认为有效。</summary>
    internal Dictionary<string, object?>? DesktopUsage()
    {
        var path = Path.Combine(ctx.AppData, "Claude", "plan-usage-history.json");
        if (PyJson.ReadObjectFile(path)?.Get("samples") is not List<object?> { Count: > 0 } samples
            || samples[^1] is not Dictionary<string, object?> last) return null;
        var t = PyJson.AsDouble(last.Get("t")) ?? 0;
        var ageMin = (ctx.Clock() * 1000 - t) / 60000;
        if (ageMin > 30 || last.GetDict("u") is not { } usage) return null;
        var windows = new Dictionary<string, object?>();
        if (usage.TryGetValue("fh", out var fh)) windows["5h"] = new Dictionary<string, object?> { ["pct"] = fh, ["resets_at"] = null };
        if (usage.TryGetValue("sd", out var sd)) windows["7d"] = new Dictionary<string, object?> { ["pct"] = sd, ["resets_at"] = null };
        if (windows.Count == 0) return null;
        return new Dictionary<string, object?>
        {
            ["windows"] = windows, ["_via"] = "desktop", ["_sample_age_min"] = (long)Math.Max(0, (int)ageMin),
        };
    }

    Dictionary<string, object?>? OAuth() =>
        PyJson.ReadObjectFile(CredentialsPath)?.GetDict("claudeAiOauth") is { } oauth
        && (oauth.Get("accessToken") is not null || oauth.Get("refreshToken") is not null)
            ? oauth
            : null;

    Dictionary<string, object?> FetchOAuth(Dictionary<string, object?> oauth)
    {
        var token = oauth.Get("accessToken") as string;
        var exp = PyJson.AsDouble(oauth.Get("expiresAt")) ?? 0;
        if (string.IsNullOrEmpty(token) || (exp > 0 && ctx.Clock() * 1000 > exp - 60_000))
            return BillingNet.Error("expired", "Claude 登录态已过期，打开 Claude Code 以刷新登录");
        var (status, data) = ctx.Http(UsageUrl, new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {token}",
            ["anthropic-beta"] = "oauth-2025-04-20",
            ["Content-Type"] = "application/json",
        }, null, "GET");
        if (status == 429) return BillingNet.Error("http_429", "Claude usage 接口限流，稍后自动重试", data.Get("_retry_after"));
        if (status == 401) return BillingNet.Error("expired", "Claude 登录态已过期，打开 Claude Code 以刷新登录");
        if (status != 200) return BillingNet.Error($"http_{status}", $"Claude usage 接口返回 {status}");
        var windows = new Dictionary<string, object?>();
        foreach (var (key, label) in new[] { ("five_hour", "5h"), ("seven_day", "7d"), ("seven_day_sonnet", "7d_sonnet"), ("seven_day_opus", "7d_opus") })
        {
            if (data.GetDict(key) is not { } w) continue;
            if (BillingNet.Pct(w.Get("utilization") ?? w.Get("used_percentage")) is { } pct)
                windows[label] = new Dictionary<string, object?> { ["pct"] = pct, ["resets_at"] = BillingNet.IsoMs(w.Get("resets_at")) };
        }
        if (windows.Count == 0) return BillingNet.Error("no_windows", "接口未返回窗口数据");
        var subscription = oauth.Get("subscriptionType") as string ?? "";
        var plan = data.Get("plan") as string ?? data.Get("rate_limit_tier") as string
            ?? PlanNames.GetValueOrDefault(subscription.ToLowerInvariant()) ?? subscription;
        return new Dictionary<string, object?> { ["windows"] = windows, ["plan"] = plan, ["_via"] = "oauth" };
    }

    public Dictionary<string, object?> OAuthUsage()
    {
        // 1) 桌面采样（桌面 App 登录态独立于 CLI）
        var desk = DesktopUsage();
        // 2) OAuth API（能拿到 resets_at 和更细的窗口，成功则用更丰富的那份）
        var oauth = OAuth();
        Dictionary<string, object?>? oauthErr = null;
        if (oauth is not null)
        {
            var result = FetchOAuth(oauth);
            if (result.Get("error") is null) return result;
            oauthErr = result;
        }
        // 3) OAuth 不可用 → 桌面采样兜底（标记来源）
        if (desk is not null)
        {
            if (oauthErr is not null)
            {
                desk["_oauth_err"] = oauthErr.Get("error");
                if (oauthErr.Get("error") as string == "http_429")
                    desk["_retry_after"] = oauthErr.Get("_retry_after") ?? OfficialCache.TtlErr;
            }
            return desk;
        }
        return oauthErr ?? BillingNet.Error("no_credentials", "未找到 Claude 登录态（~/.claude/.credentials.json 为空）");
    }
}
