using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;

namespace TokenTracker.Core.Billing;

/// <summary>
/// Codex 官方配额（移植 CodexBilling.swift，Windows 只读版）：主路 chatgpt.com/backend-api/wham/usage
/// 复用 ~/.codex/auth.json 的 access_token（不刷新、不写回）；失败时委托官方 CLI 的
/// `codex app-server` JSON-RPC 兜底——由官方 CLI 自己刷新并写回凭据，安全。
/// </summary>
public sealed class CodexBilling(BillingContext ctx)
{
    const string WhamUrl = "https://chatgpt.com/backend-api/wham/usage";
    const string CliUa = "codex_cli_rs/0.150.1";

    static readonly Dictionary<long, string> WinByMin = new() { [300] = "5h", [10_080] = "7d", [43_200] = "month", [44_640] = "month" };
    static readonly Dictionary<long, string> WinBySec = new() { [18_000] = "5h", [604_800] = "7d", [2_592_000] = "month", [2_678_400] = "month" };

    public string AuthPath =>
        Path.Combine(WinPaths.Expand(ctx.Env("CODEX_HOME") is { Length: > 0 } home ? home : Path.Combine(ctx.Home, ".codex")),
            "auth.json");

    /// <summary>当前登录账号（用于缓存键；不含 token）。</summary>
    public string AccountId() =>
        PyJson.ReadObjectFile(AuthPath)?.GetDict("tokens")?.Get("account_id") as string ?? "signed-out";

    static object? ResetsAt(object? raw) =>
        PyJson.AsNumber(raw) is { } resetAt ? resetAt < 1e12 ? (long)(resetAt * 1000) : (long)resetAt : null;

    internal Dictionary<string, object?> UsageWham()
    {
        if (PyJson.ReadObjectFile(AuthPath)?.GetDict("tokens") is not { } tokens || tokens.Get("access_token") is null)
            return BillingNet.Error("no_credentials", "未找到 ~/.codex/auth.json 登录态");
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {tokens.Get("access_token") as string ?? ""}",
            ["Accept"] = "application/json", ["User-Agent"] = CliUa,
        };
        if (tokens.Get("account_id") is string account) headers["ChatGPT-Account-Id"] = account;
        var (status, data) = ctx.Http(WhamUrl, headers, null, "GET");
        if (status != 200) return BillingNet.Error($"http_{status}", $"wham/usage 返回 {status}", data.Get("_retry_after"));
        var rl = data.GetDict("rate_limit");
        var windows = new Dictionary<string, object?>();
        foreach (var w in new[] { rl.GetDict("primary_window"), rl.GetDict("secondary_window") })
        {
            if (w is null || !WinBySec.TryGetValue(PyJson.AsLong(w.Get("limit_window_seconds")) ?? 0, out var key)
                || !w.ContainsKey("used_percent")) continue;
            windows[key] = new Dictionary<string, object?>
            {
                ["pct"] = PyJson.AsDouble(w.Get("used_percent")) ?? 0, ["resets_at"] = ResetsAt(w.Get("reset_at")),
            };
        }
        if (windows.Count == 0) return BillingNet.Error("no_windows", "wham/usage 无窗口数据");
        return new Dictionary<string, object?> { ["windows"] = windows, ["plan"] = data.Get("plan_type") ?? "", ["_via"] = "wham" };
    }

    /// <summary>JSON-RPC over stdio 调 codex app-server（官方 CLI 自行处理登录态）。</summary>
    Dictionary<string, object?> Rpc(string binPath)
    {
        var info = ProcessRunner.StartInfo(binPath, ["-s", "read-only", "-a", "untrusted", "app-server"]);
        info.RedirectStandardInput = true;
        info.StandardInputEncoding = new UTF8Encoding(false);
        using var process = new Process { StartInfo = info };
        var lines = new BlockingCollection<string>();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not null) lines.Add(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null) lock (stderr) stderr.AppendLine(e.Data);
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try
        {
            void Send(Dictionary<string, object?> obj)
            {
                process.StandardInput.WriteLine(PyJson.Serialize(obj));
                process.StandardInput.Flush();
            }
            Dictionary<string, object?> Receive(long wantId, TimeSpan timeout)
            {
                var deadline = DateTime.UtcNow + timeout;
                while (DateTime.UtcNow < deadline)
                {
                    if (process.HasExited && lines.Count == 0)
                        throw new InvalidOperationException(
                            $"codex 进程提前退出(code={process.ExitCode})：{stderr.ToString().Trim()[..Math.Min(200, stderr.ToString().Trim().Length)]}");
                    if (!lines.TryTake(out var line, TimeSpan.FromMilliseconds(100))) continue;
                    if (PyJson.ParseObject(line) is not { } obj || PyJson.AsLong(obj.Get("id")) != wantId) continue;
                    if (obj.GetDict("error") is { } error) throw new InvalidOperationException(error.Get("message") as string ?? "rpc error");
                    return obj.GetDict("result") ?? new Dictionary<string, object?>();
                }
                throw new TimeoutException("codex app-server 无响应");
            }
            Send(new Dictionary<string, object?>
            {
                ["id"] = 1L, ["method"] = "initialize",
                ["params"] = new Dictionary<string, object?>
                {
                    ["clientInfo"] = new Dictionary<string, object?> { ["name"] = "tokentracker", ["version"] = "0.1" },
                },
            });
            Receive(1, TimeSpan.FromSeconds(15));
            Send(new Dictionary<string, object?> { ["method"] = "initialized", ["params"] = new Dictionary<string, object?>() });
            Send(new Dictionary<string, object?> { ["id"] = 2L, ["method"] = "account/rateLimits/read", ["params"] = new Dictionary<string, object?>() });
            return Receive(2, TimeSpan.FromSeconds(15));
        }
        finally
        {
            ProcessRunner.Kill(process);
        }
    }

    internal Dictionary<string, object?> UsageRpc()
    {
        if (ctx.CliResolver("codex") is not { } bin) return BillingNet.Error("no_binary", "未找到 codex 命令");
        Dictionary<string, object?> data;
        try
        {
            data = Rpc(bin);
        }
        catch (Exception e) when (e is InvalidOperationException or TimeoutException or IOException
                                       or System.ComponentModel.Win32Exception)
        {
            return BillingNet.Error("rpc_failed", $"Codex RPC 失败：{e.Message}（请确认已登录 codex）");
        }
        if (data.GetDict("rateLimits") is not { Count: > 0 } rl) return BillingNet.Error("no_limits", "Codex 未返回限额数据");
        var windows = new Dictionary<string, object?>();
        foreach (var w in new[] { rl.GetDict("primary"), rl.GetDict("secondary") })
        {
            if (w is null || !WinByMin.TryGetValue(PyJson.AsLong(w.Get("windowDurationMins")) ?? 0, out var key)
                || PyJson.AsDouble(w.Get("usedPercent")) is not { } pct) continue;
            windows[key] = new Dictionary<string, object?> { ["pct"] = pct, ["resets_at"] = ResetsAt(w.Get("resetsAt")) };
        }
        if (windows.Count == 0) return BillingNet.Error("no_windows", "Codex 无窗口数据");
        return new Dictionary<string, object?> { ["windows"] = windows, ["plan"] = rl.Get("planType") ?? "", ["_via"] = "rpc" };
    }

    /// <summary>wham/usage 为主，app-server RPC 兜底（结果带 _via 标明走的那条路）。</summary>
    public Dictionary<string, object?> Usage()
    {
        var result = UsageWham();
        if (result.Get("error") is null || result.Get("error") as string == "http_429") return result;
        var rpc = UsageRpc();
        if (rpc.Get("error") is null) return rpc;
        return BillingNet.Error(result.Get("error") as string ?? "unknown",
            $"{result.Get("detail")}；RPC 兜底也失败：{rpc.Get("detail")}", result.Get("_retry_after"));
    }
}
