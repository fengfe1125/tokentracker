using System.Globalization;
using System.Net.Http.Headers;
using TokenTracker.Core.Json;
using TokenTracker.Core.Scanners;

namespace TokenTracker.Core.Billing;

/// <summary>同步 JSON HTTP 调用签名：(url, headers, body, method) → (status, 响应对象)。status=0 表示网络错误。</summary>
public delegate (int Status, Dictionary<string, object?> Data) BillingHttp(string url,
    IReadOnlyDictionary<string, string> headers, byte[]? body, string method);

/// <summary>
/// 官方配额抓取共用的注入上下文（移植 BillingContext.swift）。Windows 版只读：
/// 没有钥匙串、没有凭据写回接口。
/// </summary>
public sealed class BillingContext
{
    public string Home { get; init; } = Platform.WinPaths.Home;
    public string AppData { get; init; } = Platform.WinPaths.AppData;
    public Func<string, string?> Env { get; init; } = Environment.GetEnvironmentVariable;
    public Func<double> Clock { get; init; } = () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    public BillingHttp Http { get; init; } = BillingNet.HttpJson;
    public Func<string, string?> CliResolver { get; init; } = Platform.CliFind.Resolve;
}

/// <summary>移植 BillingHTTP.swift：timeout=8s；Retry-After 支持秒数与 HTTP-date。</summary>
public static class BillingNet
{
    static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        // 跟随 Windows 系统代理（chatgpt.com / anthropic.com 在部分网络需要代理）
        UseProxy = true,
        AutomaticDecompression = System.Net.DecompressionMethods.All,
    })
    {
        Timeout = TimeSpan.FromSeconds(8),
    };

    public static (int Status, Dictionary<string, object?> Data) HttpJson(string url,
        IReadOnlyDictionary<string, string> headers, byte[]? body, string method)
    {
        try
        {
            using var request = new HttpRequestMessage(new HttpMethod(method), url);
            string? contentType = null;
            foreach (var (key, value) in headers)
            {
                if (key.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))
                {
                    contentType = value;
                    continue;
                }
                request.Headers.TryAddWithoutValidation(key, value);
            }
            if (body is not null)
            {
                request.Content = new ByteArrayContent(body);
                if (contentType is not null) request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
            }
            using var response = Client.Send(request);
            var bytes = response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
            var obj = bytes.Length > 0 ? PyJson.ParseObject(bytes) ?? new Dictionary<string, object?>() : new Dictionary<string, object?>();
            if (response.Headers.RetryAfter is { } retry)
            {
                long? seconds = retry.Delta is { } delta
                    ? (long)delta.TotalSeconds
                    : retry.Date is { } date ? (long)Math.Ceiling((date - DateTimeOffset.UtcNow).TotalSeconds) : null;
                if (seconds > 0) obj["_retry_after"] = seconds;
            }
            return ((int)response.StatusCode, obj);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException
                                       or UriFormatException or FormatException)
        {
            return (0, new Dictionary<string, object?> { ["error"] = e.Message });
        }
    }

    /// <summary>ISO 时间串 → epoch 毫秒（对齐 billing._iso_ms）。</summary>
    public static long? IsoMs(object? value)
    {
        if (value is null) return null;
        var s = PyJson.PyStr(value);
        return s.Length == 0 ? null : ScannerSupport.ParseIsoDateMs(s);
    }

    /// <summary>官方 utilization 字段是百分比（含 &lt;1% 的值）；无效/非有限数返回 null。</summary>
    public static double? Pct(object? value)
    {
        double p;
        if (PyJson.AsNumber(value) is { } n) p = n;
        else if (value is string s && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)) p = parsed;
        else return null;
        return double.IsFinite(p) ? p : null;
    }

    public static Dictionary<string, object?> Error(string error, string detail, object? retryAfter = null)
    {
        var d = new Dictionary<string, object?> { ["error"] = error, ["detail"] = detail };
        if (retryAfter is not null) d["_retry_after"] = retryAfter;
        return d;
    }
}
