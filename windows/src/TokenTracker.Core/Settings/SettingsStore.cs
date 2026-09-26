using System.Text.RegularExpressions;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;

namespace TokenTracker.Core.Settings;

/// <summary>
/// ~/.tokentracker/settings.json 的读写、默认值与白名单校验（移植 SettingsStore.swift；未列出的键拒绝）。
/// 与 macOS / Python 版共用同一文件与键。
/// </summary>
public sealed class SettingsStore(string? path = null)
{
    public static readonly string[] TerminalApps = ["auto", "terminal", "iterm", "wezterm", "ghostty"];
    public static readonly long[] ScanIntervals = [30, 60, 300, 600];

    public static IReadOnlyDictionary<string, object?> Defaults { get; } = new Dictionary<string, object?>
    {
        ["menubar_provider"] = "claude", // 托盘追加显示的平台配额；"off" = 仅今日用量
        ["menubar_compact"] = false,
        ["menubar_ring"] = true, // 圆环显示配额
        ["launch_at_login"] = false,
        ["terminal_app"] = "auto",
        ["unit_yi"] = false, // 大数以「亿」显示
        ["scan_interval"] = 60L, // 自动扫描/刷新节奏（秒）
        ["publish_enabled"] = false,
        ["publish_endpoint"] = "",
        ["publish_handle"] = "",
        ["publish_days"] = 365L,
    };

    static readonly Regex ProviderPattern = new(@"^(?:off|[a-z0-9][a-z0-9_-]{0,23})$");
    static readonly Regex EndpointPattern = new(@"^https://[a-z0-9.-]{3,64}(:[0-9]{2,5})?(/[A-Za-z0-9._~/-]{0,64})?$");
    static readonly Regex HandlePattern = new(@"^[a-z0-9][a-z0-9-]{1,30}$");

    public string Path { get; } = path ?? System.IO.Path.Combine(WinPaths.DataDir, "settings.json");

    public Dictionary<string, object?> Load() => PyJson.ReadObjectFile(Path) ?? new Dictionary<string, object?>();

    public bool Save(Dictionary<string, object?> prefs) => SharedFile.AtomicWriteText(Path, PyJson.Serialize(prefs));

    public static bool IsValid(string key, object? value) => key switch
    {
        "menubar_provider" => value is string v && ProviderPattern.IsMatch(v),
        "menubar_compact" or "menubar_ring" or "launch_at_login" or "unit_yi" or "publish_enabled" => value is bool,
        "publish_endpoint" => value is string v && (v.Length == 0 || (v.Length <= 200 && EndpointPattern.IsMatch(v))),
        "publish_handle" => value is string v && (v.Length == 0 || HandlePattern.IsMatch(v)),
        "publish_days" => PyJson.AsNumber(value) is 90 or 365 or 730,
        "terminal_app" => value is string v && TerminalApps.Contains(v),
        "scan_interval" => value is long or int or double && ScanIntervals.Contains((long)PyJson.AsNumber(value)!.Value),
        _ => false,
    };

    /// <summary>默认值 + 通过白名单校验的已存值。</summary>
    public Dictionary<string, object?> Effective()
    {
        var settings = new Dictionary<string, object?>(Defaults);
        foreach (var (key, value) in Load())
            if (IsValid(key, value)) settings[key] = value;
        return settings;
    }

    /// <summary>一次校验并原子保存多个设置（与现有偏好合并）。</summary>
    public bool Set(IReadOnlyDictionary<string, object?> values)
    {
        if (!values.All(kv => IsValid(kv.Key, kv.Value))) return false;
        var prefs = Load();
        foreach (var (key, value) in values) prefs[key] = value;
        return Save(prefs);
    }

    public bool Set(string key, object? value) => Set(new Dictionary<string, object?> { [key] = value });

    public string String(string key) => Effective().Get(key) as string ?? "";
    public bool Bool(string key) => Effective().Get(key) is true;
    public long Int(string key) => PyJson.AsLong(Effective().Get(key)) ?? 0;

    /// <summary>文件指纹：mtime + 大小（设置被 CLI / 其他实例修改时热重载）。</summary>
    public string Fingerprint()
    {
        try
        {
            var info = new FileInfo(Path);
            return info.Exists ? $"{info.LastWriteTimeUtc.Ticks}:{info.Length}" : "missing";
        }
        catch (IOException)
        {
            return "error";
        }
    }
}
