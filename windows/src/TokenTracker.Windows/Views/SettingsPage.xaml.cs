using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using TokenTracker.Core.Platform;

namespace TokenTracker.Windows.Views;

/// <summary>
/// 设置（移植 SettingsView.swift 的 MVP 部分）：托盘显示、语言、开机自启、数据目录、关于与更新检查。
/// 与 ~/.tokentracker/settings.json 双向同步（白名单校验写入，5s 内热生效）。
/// </summary>
public partial class SettingsPage : UserControl
{
    public SettingsPage() => InitializeComponent();

    void OnOpenDataFolder(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(WinPaths.DataDir);
        Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { WinPaths.DataDir }, UseShellExecute = false });
    }
}
