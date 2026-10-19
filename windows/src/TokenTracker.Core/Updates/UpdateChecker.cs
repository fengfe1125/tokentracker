using System.Text.RegularExpressions;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;

namespace TokenTracker.Core.Updates;

public sealed record UpdateInfo(string Latest, string Url, double CheckedAt);

/// <summary>
/// GitHub Releases 更新检查（移植 UpdateChecker.swift）：缓存 24h（与 macOS 共用 update_check.json），
/// 网络失败静默。第一期只提示并打开发布页，不做应用内安装。
/// </summary>
public sealed class UpdateChecker
{
    public const string Repo = "fengfe1125/tokentracker";
    public const double CacheTtl = 24 * 3600;
    public static string ReleasesUrl => $"https://github.com/{Repo}/releases/latest";

    static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(8) };

    public string CachePath { get; init; } = Path.Combine(WinPaths.DataDir, "update_check.json");
    public Func<double> Clock { get; init; } = () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    /// <summary>注入缝：网络抓取。</summary>
    public Func<string, byte[]> Fetch { get; init; } = url =>
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", "TokenTracker-update-check");
        using var response = Client.Send(request);
        response.EnsureSuccessStatusCode();
        return response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
    };

    public static int[] ParseVersion(string v) =>
        Regex.Replace(v, "^v", "").Split('.')
            .Where(p => p.Length > 0 && p.All(char.IsAsciiDigit)).Select(int.Parse).ToArray();

    public UpdateInfo? ReadCache()
    {
        var obj = PyJson.ReadObjectFile(CachePath);
        return obj?.Get("latest") is string { Length: > 0 } latest
            ? new UpdateInfo(latest, obj.Get("url") as string ?? "", PyJson.AsNumber(obj.Get("checked_at")) ?? 0)
            : null;
    }

    /// <summary>返回最新发布信息或 null（离线/无 release 时给过期缓存或 null）。</summary>
    public UpdateInfo? Check(bool force = false)
    {
        var cached = ReadCache();
        if (!force && cached is not null && Clock() - cached.CheckedAt < CacheTtl) return cached;
        try
        {
            var obj = PyJson.ParseObject(Fetch($"https://api.github.com/repos/{Repo}/releases/latest")) ?? [];
            var info = new UpdateInfo(obj.Get("tag_name") as string ?? "", obj.Get("html_url") as string ?? "", Clock());
            SharedFile.AtomicWriteText(CachePath, PyJson.Serialize(new Dictionary<string, object?>
            {
                ["latest"] = info.Latest, ["url"] = info.Url, ["checked_at"] = info.CheckedAt,
            }));
            return info;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException)
        {
            return cached; // 失败静默
        }
    }

    public static bool UpdateAvailable(UpdateInfo? info, string current)
    {
        if (info is null || info.Latest.Length == 0) return false;
        // Python tuple 比较：逐元素，短序列前缀相等时更长者大
        var latest = ParseVersion(info.Latest);
        var currentParts = ParseVersion(current);
        for (var i = 0; i < Math.Max(latest.Length, currentParts.Length); i++)
        {
            var l = i < latest.Length ? latest[i] : 0;
            var c = i < currentParts.Length ? currentParts[i] : 0;
            if (l != c) return l > c;
        }
        return false;
    }
}
