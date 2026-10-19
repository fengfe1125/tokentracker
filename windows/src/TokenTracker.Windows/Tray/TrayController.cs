using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using H.NotifyIcon;
using TokenTracker.Core.Localization;
using TokenTracker.Core.Presentation;
using TokenTracker.Windows.ViewModels;

namespace TokenTracker.Windows.Tray;

/// <summary>
/// 托盘（移植 StatusItemController.swift）。Windows 托盘没有文字标题：
/// 图标 = 所选配额最紧窗口的圆环，tooltip = 今日用量 + 配额，左键开关主面板，
/// 右键菜单每次打开时重建（对齐 menuNeedsUpdate）。Explorer 重启后由 H.NotifyIcon 重新登记图标。
/// </summary>
public sealed class TrayController : IDisposable
{
    readonly AppViewModel _vm;
    readonly Action _toggleMain;
    readonly Action _showMain;
    readonly Action _showSettings;
    readonly Action _quit;
    readonly TaskbarIcon _icon;
    readonly RingIconRenderer _renderer = new();
    readonly System.Drawing.Icon _appIcon;

    public TrayController(AppViewModel vm, Action toggleMain, Action showMain, Action showSettings, Action quit)
    {
        _vm = vm;
        _toggleMain = toggleMain;
        _showMain = showMain;
        _showSettings = showSettings;
        _quit = quit;
        using (var stream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/TokenTracker.ico"))!.Stream)
            _appIcon = new System.Drawing.Icon(stream, 16, 16);
        _icon = new TaskbarIcon
        {
            NoLeftClickDelay = true,
            ContextMenu = new ContextMenu(),
        };
        _icon.TrayLeftMouseUp += (_, _) => _toggleMain();
        _icon.PreviewTrayContextMenuOpen += (_, _) => RebuildMenu();
        _icon.ForceCreate(false);
        _vm.PropertyChanged += OnViewModelChanged;
        L10n.LanguageChanged += () => _icon.Dispatcher.BeginInvoke(UpdateVisuals);
        UpdateVisuals();
    }

    void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppViewModel.Today) or nameof(AppViewModel.QuotaEntries) or nameof(AppViewModel.Scanning)
            or nameof(AppViewModel.Settings) or "") UpdateVisuals();
    }

    void UpdateVisuals()
    {
        var provider = _vm.MenubarProvider;
        var (pct, role) = TrayFormatter.RingSpec(_vm.QuotaEntries, provider);
        var icon = _vm.MenubarRing || _vm.Scanning
            ? _renderer.Render(pct, role, _vm.Scanning)
            : _appIcon;
        _icon.UpdateIcon(icon);
        _icon.ToolTipText = Tooltip();
    }

    /// <summary>tooltip（上限 127 字）：应用名 / 今日用量 / 所选配额最紧窗口。</summary>
    string Tooltip()
    {
        var lines = new List<string> { "TokenTracker" };
        if (_vm.Scanning) lines.Add(L10n.T("扫描中…"));
        lines.Add(Plain(TodaySegments()));
        var entry = _vm.QuotaEntries.FirstOrDefault(e => e.Id == _vm.MenubarProvider);
        if (entry is not null && TrayFormatter.BestWindow(entry) is { } best)
            lines.Add($"{entry.Name} · {UiFormat.QuotaLabel(best.Label)} {TrayFormatter.FmtQuota(best)}");
        var text = string.Join("\n", lines);
        return text.Length <= 127 ? text : text[..126] + "…";
    }

    List<Segment> TodaySegments() =>
        TrayFormatter.TodayLineSegments(_vm.Today, _vm.UnitYi && !L10n.IsEnglish)
            .Select(s => s with { Text = s.Role is "tokens" ? s.Text : L10n.T(s.Text) }).ToList();

    static string Plain(IEnumerable<Segment> segments) => string.Concat(segments.Select(s => s.Text));

    static Brush RoleBrush(string role)
    {
        if (role.StartsWith("dot_", StringComparison.Ordinal)) return UiFormat.ToolBrush(role[4..]);
        return role switch
        {
            "tokens" or "cost" => UiFormat.Accent,
            "dim" => UiFormat.Muted,
            "quota_ok" or "quota_warn" or "quota_crit" => UiFormat.UrgencyBrush(role),
            _ => SystemColors.MenuTextBrush,
        };
    }

    static TextBlock Colored(IEnumerable<Segment> segments)
    {
        var block = new TextBlock();
        foreach (var s in segments) block.Inlines.Add(new Run(s.Text) { Foreground = RoleBrush(s.Role) });
        return block;
    }

    static MenuItem Item(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }

    void RebuildMenu()
    {
        var menu = _icon.ContextMenu!;
        menu.Items.Clear();
        var yi = _vm.UnitYi && !L10n.IsEnglish;
        menu.Items.Add(new MenuItem { Header = Colored(TodaySegments()), Command = null }.Also(i => i.Click += (_, _) => _showMain()));
        foreach (var entry in _vm.QuotaEntries.Take(4))
        {
            var best = TrayFormatter.BestWindow(entry);
            List<Segment> segments = best is null
                ? [new Segment(entry.Name, "ink")]
                :
                [
                    new("● ", "dot_" + entry.Id), new(entry.Name, "ink"),
                    new($" · {UiFormat.QuotaLabel(best.Label)} ", "dim"),
                    new(TrayFormatter.FmtQuota(best), TrayFormatter.QuotaUrgency(best.Pct)),
                ];
            menu.Items.Add(new MenuItem { Header = Colored(segments) }.Also(i => i.Click += (_, _) => _showMain()));
        }
        menu.Items.Add(new Separator());

        // 「托盘显示」子菜单：预览 + 各配额单选 + 仅今日用量
        var display = new MenuItem { Header = L10n.T("托盘显示") };
        var ring = TrayFormatter.RingSpec(_vm.QuotaEntries, _vm.MenubarProvider);
        display.Items.Add(new MenuItem
        {
            Header = L10n.T("当前：") + (_vm.MenubarRing ? TrayFormatter.RingGlyph(ring) + " " : "")
                     + TrayFormatter.Title(_vm.Today, _vm.QuotaEntries, _vm.MenubarProvider, _vm.MenubarCompact, yi, _vm.MenubarRing),
            IsEnabled = false,
        });
        display.Items.Add(new Separator());
        foreach (var entry in _vm.QuotaEntries)
        {
            var id = entry.Id;
            display.Items.Add(new MenuItem
            {
                Header = L10n.T("今日用量 + {0}", entry.Name), IsCheckable = true, IsChecked = _vm.MenubarProvider == id,
            }.Also(i => i.Click += (_, _) => _vm.UpdateSetting("menubar_provider", id)));
        }
        display.Items.Add(new MenuItem
        {
            Header = L10n.T("仅今日用量"), IsCheckable = true, IsChecked = _vm.MenubarProvider == "off",
        }.Also(i => i.Click += (_, _) => _vm.UpdateSetting("menubar_provider", "off")));
        menu.Items.Add(display);
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(L10n.T("打开主面板"), _showMain));
        menu.Items.Add(Item(L10n.T("设置…"), _showSettings));
        menu.Items.Add(Item(L10n.T("立即扫描"), () => _vm.Scan()));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(L10n.T("退出 TokenTracker"), _quit));
    }

    /// <summary>首次关窗提示：应用仍在托盘运行。</summary>
    public void ShowStillRunningNotice() =>
        _icon.ShowNotification(L10n.T("TokenTracker 仍在托盘运行"),
            L10n.T("关闭窗口不会退出。可把托盘图标从溢出区拖到任务栏，方便随时查看。"));

    public void Dispose()
    {
        _vm.PropertyChanged -= OnViewModelChanged;
        _icon.Dispose();
        _renderer.Dispose();
        _appIcon.Dispose();
    }
}

static class ObjectExtensions
{
    public static T Also<T>(this T value, Action<T> action)
    {
        action(value);
        return value;
    }
}
