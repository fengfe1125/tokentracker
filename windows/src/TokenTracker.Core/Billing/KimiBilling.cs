using System.Text.RegularExpressions;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;

namespace TokenTracker.Core.Billing;

/// <summary>
/// Kimi 官方配额（移植 KimiBilling.swift，Windows 只读版）：只读现有凭据，access_token 过期时
/// 不自刷新、不写回（refresh_token 每次轮换，与 kimi-code 并发刷新会把它登出），提示打开 Kimi Code。
/// </summary>
public sealed class KimiBilling(BillingContext ctx)
{
    static readonly Dictionary<string, string> PlanNames = new()
    {
        ["LEVEL_BASIC"] = "基础版", ["LEVEL_INTERMEDIATE"] = "中级版", ["LEVEL_PREMIUM"] = "高级版",
        ["LEVEL_UNLIMITED"] = "无限版", ["LEVEL_PRO"] = "专业版",
    };

    string Root => WinPaths.Expand(ctx.Env("KIMI_CODE_HOME") is { Length: > 0 } env ? env : Path.Combine(ctx.Home, ".kimi-code"));

    public string CredentialsPath => Path.Combine(Root, "credentials", "kimi-code.json");

    /// <summary>凭据文件版本（仅元数据，不含 token 值）：Kimi 凭据更新后下轮轮询重读。</summary>
    public string CredentialsVersion() =>
        FileIdentity.Of(CredentialsPath) is { } id ? $"{CredentialsPath}|{id.I}|{id.M}|{id.S}" : $"{CredentialsPath}|missing";

    /// <summary>OAuth host：环境变量覆盖 → region 文件 → CN 默认。</summary>
    internal string OAuthHost()
    {
        if ((ctx.Env("KIMI_CODE_OAUTH_HOST") ?? ctx.Env("KIMI_OAUTH_HOST")) is { Length: > 0 } env)
            return env.TrimEnd('/');
        var region = SharedFile.ReadAllText(Path.Combine(Root, "region"))?.Trim();
        return !string.IsNullOrEmpty(region) && region != "mainland-cn" ? "https://auth.kimi.ai" : "https://auth.kimi.com";
    }

    /// <summary>usages 等业务 API 前缀：与 OAuth host 同域族（auth.kimi.com ↔ api.kimi.com）。</summary>
    internal string ApiBase()
    {
        var host = OAuthHost();
        var match = Regex.Match(host, @"^(https://)auth\.(.+)$");
        return match.Success ? $"{match.Groups[1].Value}api.{match.Groups[2].Value}/coding/v1" : "https://api.kimi.com/coding/v1";
    }

    static Dictionary<string, object?>? Window(Dictionary<string, object?> detail, string resetKey)
    {
        if (PyJson.AsNumber(detail.Get("limit")) is not { } lim) return null;
        var used = PyJson.AsNumber(detail.Get("used"));
        if (used is null && PyJson.AsNumber(detail.Get("remaining")) is { } remaining) used = lim - remaining;
        if (used is null) return null;
        return new Dictionary<string, object?>
        {
            ["pct"] = lim == 0 ? null : used / lim * 100, ["resets_at"] = BillingNet.IsoMs(detail.Get(resetKey)),
            ["used"] = used, ["limit"] = lim, ["unit"] = "requests",
        };
    }

    public Dictionary<string, object?> Usage()
    {
        var bytes = SharedFile.ReadAllBytes(CredentialsPath);
        if (bytes is null) return BillingNet.Error("no_credentials", "无法读取 Kimi 凭据，请检查 KIMI_CODE_HOME 或打开 Kimi Code");
        if (PyJson.ParseObject(bytes) is not { } cred) return BillingNet.Error("parse", "Kimi 凭据格式暂不可读，等待 Kimi Code 更新");
        if (!cred.ContainsKey("access_token")) return BillingNet.Error("no_token", "Kimi 凭据暂为空，等待 Kimi Code 更新登录态");
        if (cred["access_token"] is not string token) return BillingNet.Error("parse", "Kimi access_token 格式异常");
        if (token.Trim().Length == 0) return BillingNet.Error("no_token", "Kimi 凭据暂为空，等待 Kimi Code 更新登录态");
        if (cred.Get("expires_at") is string) return BillingNet.Error("parse", "Kimi 凭据有效期格式异常");
        var expires = PyJson.AsDouble(cred.Get("expires_at")) ?? 0;
        if (!double.IsFinite(expires) || expires < 0) return BillingNet.Error("parse", "Kimi 凭据有效期格式异常");
        if (expires > 0 && expires <= ctx.Clock())
            return BillingNet.Error("expired", "Kimi 访问令牌已过期（Windows 版不自动刷新），运行一次 Kimi Code 后自动恢复");
        var (status, data) = ctx.Http($"{ApiBase()}/usages", new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {token}", ["Accept"] = "application/json",
        }, null, "GET");
        if (status == 401) return BillingNet.Error("expired", "Kimi 访问令牌已过期，运行一次 Kimi Code 后自动恢复");
        if (status != 200) return BillingNet.Error($"http_{status}", $"Kimi usages 接口返回 {status}", data.Get("_retry_after"));
        // 周期配额（周/计划周期）；used 缺省时用 limit-remaining 反推
        var windows = new Dictionary<string, object?>();
        if (data.GetDict("usage") is { } usage && Window(usage, "resetTime") is { } weekly) windows["7d"] = weekly;
        // 5 小时窗口（limits[].window.duration=300 分钟）
        foreach (var lt in (data.Get("limits") as List<object?> ?? []).OfType<Dictionary<string, object?>>())
        {
            if (lt.GetDict("detail") is not { } detail || Window(detail, "resetTime") is not { } w) continue;
            var key = PyJson.PyStr(lt.GetDict("window").Get("duration") ?? "") == "300" ? "5h" : "7d";
            windows[key] = w;
        }
        if (windows.Count == 0) return BillingNet.Error("no_windows", "Kimi 接口未返回可用配额");
        var level = data.GetDict("user").GetDict("membership").Get("level") as string;
        return new Dictionary<string, object?>
        {
            ["windows"] = windows,
            ["plan"] = level is not null ? PlanNames.GetValueOrDefault(level, level) : "",
            ["unit"] = "requests",
        };
    }
}
