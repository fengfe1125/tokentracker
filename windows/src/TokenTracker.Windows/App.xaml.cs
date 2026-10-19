using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using TokenTracker.Core.Platform;
using TokenTracker.Windows.Lifecycle;
using TokenTracker.Windows.Shell;
using TokenTracker.Windows.Tray;
using TokenTracker.Windows.ViewModels;
using Wpf.Ui.Appearance;

namespace TokenTracker.Windows;

/// <summary>
/// 应用生命周期（移植 AppDelegate.swift）：单实例、托盘常驻、关窗只隐藏、退出时有界停止扫描。
/// 手动启动显示主面板；开机自启（--autostart）只驻留托盘。
/// </summary>
public partial class App : Application
{
    SingleInstance? _instance;
    AppViewModel? _vm;
    TrayController? _tray;
    MainWindow? _main;
    bool _quitting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var autostart = LaunchPolicy.IsAutostart(e.Args);
        _instance = SingleInstance.TryAcquire(signalExisting: !autostart);
        if (_instance is null)
        {
            Shutdown();
            return;
        }
        DispatcherUnhandledException += OnUnhandledException;
        ApplicationThemeManager.ApplySystemTheme();
        _vm = new AppViewModel();
        _tray = new TrayController(_vm, ToggleMain, ShowMain, ShowSettings, Quit);
        _instance.Listen(() => Dispatcher.BeginInvoke(ShowMain));
        _vm.Start();
        if (!autostart) ShowMain();
        if (_main is not null) DevSnapshot.ScheduleIfRequested(_main, _vm, Quit);
    }

    MainWindow EnsureMain()
    {
        if (_main is not null) return _main;
        _main = new MainWindow(_vm!);
        _main.Closing += OnMainClosing;
        return _main;
    }

    public void ShowMain()
    {
        var main = EnsureMain();
        if (!main.IsVisible) main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
        _vm!.RefreshData();
    }

    /// <summary>
    /// 托盘左键：主面板在前台时隐藏，否则唤到前台。点击托盘会先让窗口失去焦点，
    /// 所以「刚失焦」也算在前台。
    /// </summary>
    void ToggleMain()
    {
        if (_main is { IsVisible: true } main && main.WindowState != WindowState.Minimized
            && (main.IsActive || DateTime.UtcNow - main.LastDeactivatedUtc < TimeSpan.FromMilliseconds(500)))
            main.Hide();
        else ShowMain();
    }

    void ShowSettings()
    {
        ShowMain();
        _vm!.Page = "settings";
    }

    /// <summary>关窗 = 隐藏到托盘；只有托盘「退出」才真正退出。</summary>
    void OnMainClosing(object? sender, CancelEventArgs e)
    {
        if (_quitting) return;
        e.Cancel = true;
        _main!.Hide();
        if (_vm!.AppState.CloseNoticeShown) return;
        _vm.AppState.CloseNoticeShown = true;
        _tray?.ShowStillRunningNotice();
    }

    void Quit()
    {
        _quitting = true;
        _vm?.Stop();
        _main?.Close();
        _tray?.Dispose();
        _instance?.Dispose();
        Shutdown();
    }

    void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        // 界面异常不应让常驻托盘的进程整体退出：落日志后继续
        try
        {
            Directory.CreateDirectory(WinPaths.DataDir);
            File.AppendAllText(Path.Combine(WinPaths.DataDir, "app.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] windows ui: {e.Exception}\n");
        }
        catch (IOException)
        {
        }
        e.Handled = true;
    }
}
