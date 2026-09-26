using System.IO;
using Microsoft.Win32;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;

namespace TokenTracker.Windows.Lifecycle;

/// <summary>启动策略（移植 AppLaunchPolicy.swift）：手动启动显示主面板；开机自启（--autostart）只驻留托盘。</summary>
public static class LaunchPolicy
{
    public const string AutostartArgument = "--autostart";

    public static bool IsAutostart(IEnumerable<string> args) =>
        args.Any(a => string.Equals(a, AutostartArgument, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// 单实例：命名 Mutex 占位 + 命名事件唤起。重复手动启动时通知已有实例显示主面板后退出；
/// 带 --autostart 的重复启动静默退出。
/// </summary>
public sealed class SingleInstance : IDisposable
{
    const string MutexName = @"Local\TokenTracker.Windows.SingleInstance";
    const string EventName = @"Local\TokenTracker.Windows.Activate";

    readonly Mutex _mutex;
    readonly EventWaitHandle _activate;
    readonly CancellationTokenSource _stop = new();

    SingleInstance(Mutex mutex, EventWaitHandle activate)
    {
        _mutex = mutex;
        _activate = activate;
    }

    /// <summary>成为首个实例返回句柄；已有实例时按需唤起它并返回 null。</summary>
    public static SingleInstance? TryAcquire(bool signalExisting)
    {
        var mutex = new Mutex(true, MutexName, out var created);
        var activate = new EventWaitHandle(false, EventResetMode.AutoReset, EventName);
        if (created) return new SingleInstance(mutex, activate);
        if (signalExisting) activate.Set();
        activate.Dispose();
        mutex.Dispose();
        return null;
    }

    /// <summary>后台线程等待唤起信号（回调在该线程上执行，调用方负责切 UI 线程）。</summary>
    public void Listen(Action onActivate)
    {
        var thread = new Thread(() =>
        {
            var handles = new WaitHandle[] { _activate, _stop.Token.WaitHandle };
            while (WaitHandle.WaitAny(handles) == 0) onActivate();
        })
        { IsBackground = true, Name = "tt-single-instance" };
        thread.Start();
    }

    public void Dispose()
    {
        _stop.Cancel();
        _activate.Dispose();
        try
        {
            _mutex.ReleaseMutex();
        }
        catch (ApplicationException)
        {
        }
        _mutex.Dispose();
    }
}

/// <summary>开机自启：HKCU\...\Run 下的 TokenTracker 值，指向 "exe" --autostart。</summary>
public static class AutoStart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "TokenTracker";

    static string Command => $"\"{Environment.ProcessPath}\" {LaunchPolicy.AutostartArgument}";

    static bool PointsToUs(string? value) =>
        value is not null && Environment.ProcessPath is { } exe
                          && value.Contains(exe, StringComparison.OrdinalIgnoreCase);

    public static bool IsRegistered()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return PointsToUs(key?.GetValue(ValueName) as string);
    }

    /// <summary>按设置启用/关闭；关闭时只删除指向本程序的值。返回是否成功。</summary>
    public static bool Apply(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            var current = key.GetValue(ValueName) as string;
            if (enabled)
            {
                if (current != Command) key.SetValue(ValueName, Command);
            }
            else if (PointsToUs(current))
            {
                key.DeleteValue(ValueName, false);
            }
            return true;
        }
        catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            return false;
        }
    }
}

/// <summary>
/// Windows 专属的本机偏好（%LOCALAPPDATA%\TokenTracker\app-state.json）：界面语言等。
/// 不写进 settings.json——那是与 macOS / Python 共用、按白名单校验的文件。
/// </summary>
public sealed class AppStateFile
{
    readonly string _path = Path.Combine(WinPaths.LocalAppData, "TokenTracker", "app-state.json");
    readonly Dictionary<string, object?> _values;

    public AppStateFile() => _values = PyJson.ReadObjectFile(_path) ?? new Dictionary<string, object?>();

    /// <summary>system / zh-Hans / en。</summary>
    public string Language
    {
        get => _values.Get("language") as string ?? "system";
        set => Set("language", value);
    }

    /// <summary>第一次关窗时提示「仍在托盘运行」，之后不再打扰。</summary>
    public bool CloseNoticeShown
    {
        get => _values.Get("close_notice_shown") is true;
        set => Set("close_notice_shown", value);
    }

    void Set(string key, object? value)
    {
        _values[key] = value;
        SharedFile.AtomicWriteText(_path, PyJson.Serialize(_values));
    }
}
