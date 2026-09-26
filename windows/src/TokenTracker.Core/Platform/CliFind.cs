using Microsoft.Win32;

namespace TokenTracker.Core.Platform;

/// <summary>
/// CLI 绝对路径解析（移植 CliFind.swift 的三级兜底，Windows 版）：
/// 进程 PATH + 注册表里的最新 PATH（开机自启的进程继承的是旧 PATH，相当于 macOS 的登录 shell 探测）
/// → 常见安装目录。按 PATHEXT 顺序匹配，绝不返回无扩展名的 npm sh 垫片。结果进程内缓存。
/// </summary>
public static class CliFind
{
    static readonly Dictionary<string, string?> Cache = new(StringComparer.OrdinalIgnoreCase);
    static readonly object Gate = new();

    static IEnumerable<string> CommonDirs()
    {
        var home = WinPaths.Home;
        yield return Path.Combine(WinPaths.AppData, "npm");
        yield return Path.Combine(WinPaths.LocalAppData, "Microsoft", "WinGet", "Links");
        yield return Path.Combine(home, "scoop", "shims");
        yield return Path.Combine(WinPaths.LocalAppData, "Volta", "bin");
        yield return Path.Combine(home, ".bun", "bin");
        yield return Path.Combine(home, ".local", "bin");
        yield return Path.Combine(home, ".kimi-code", "bin");
        yield return Path.Combine(home, ".opencode", "bin");
        yield return Path.Combine(home, ".cargo", "bin");
        yield return Path.Combine(WinPaths.LocalAppData, "pnpm");
    }

    static IEnumerable<string> PathDirs()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var sources = new List<string?> { Environment.GetEnvironmentVariable("PATH") };
        try
        {
            sources.Add(Registry.CurrentUser.OpenSubKey("Environment")?.GetValue("Path") as string);
            sources.Add(Registry.LocalMachine
                .OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")
                ?.GetValue("Path") as string);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
        }
        foreach (var source in sources)
        {
            if (string.IsNullOrEmpty(source)) continue;
            foreach (var raw in source.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var dir = Environment.ExpandEnvironmentVariables(raw.Trim('"'));
                if (dir.Length > 0 && seen.Add(dir)) yield return dir;
            }
        }
    }

    static string[] PathExt()
    {
        var value = Environment.GetEnvironmentVariable("PATHEXT");
        var list = string.IsNullOrEmpty(value)
            ? [".COM", ".EXE", ".BAT", ".CMD"]
            : value.Split(';', StringSplitOptions.RemoveEmptyEntries);
        return list.Where(e => e.StartsWith('.')).ToArray();
    }

    static string? Probe(string dir, string name)
    {
        foreach (var ext in PathExt())
        {
            var candidate = Path.Combine(dir, name + ext.ToLowerInvariant());
            try
            {
                if (File.Exists(candidate)) return candidate;
            }
            catch (Exception e) when (e is ArgumentException or NotSupportedException)
            {
            }
        }
        return null;
    }

    /// <summary>解析 CLI 绝对路径；找不到返回 null。</summary>
    public static string? Resolve(string name)
    {
        lock (Gate)
        {
            if (Cache.TryGetValue(name, out var cached)) return cached;
            string? path = null;
            foreach (var dir in PathDirs().Concat(CommonDirs()))
            {
                path = Probe(dir, name);
                if (path is not null) break;
            }
            Cache[name] = path;
            return path;
        }
    }

    public static void ClearCache()
    {
        lock (Gate) Cache.Clear();
    }
}
