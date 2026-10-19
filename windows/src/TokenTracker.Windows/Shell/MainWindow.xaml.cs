using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using TokenTracker.Windows.ViewModels;
using TokenTracker.Windows.Views;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace TokenTracker.Windows.Shell;

/// <summary>主面板：侧栏导航 + 概览 / 会话记录（含按工具） / 设置。快捷键 Ctrl+1/2 切视图、Ctrl+R 扫描。</summary>
public partial class MainWindow : FluentWindow
{
    readonly AppViewModel _vm;
    readonly Dictionary<string, UserControl> _pages = new();
    bool _syncing;

    public DateTime LastDeactivatedUtc { get; private set; }

    public MainWindow(AppViewModel vm)
    {
        _vm = vm;
        DataContext = vm;
        InitializeComponent();
        SystemThemeWatcher.Watch(this);
        Deactivated += (_, _) => LastDeactivatedUtc = DateTime.UtcNow;
        _vm.PropertyChanged += OnViewModelChanged;
        InputBindings.Add(new KeyBinding(new RelayAction(() => _vm.Page = "overview"), Key.D1, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayAction(() => _vm.Page = "sessions"), Key.D2, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayAction(_vm.Scan), Key.R, ModifierKeys.Control));
        ShowPage(_vm.Page);
    }

    void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppViewModel.Page)) ShowPage(_vm.Page);
        else if (e.PropertyName is nameof(AppViewModel.ToolRows)) SyncSelection(_vm.Page);
    }

    void ShowPage(string page)
    {
        var key = page.StartsWith("tool:", StringComparison.Ordinal) ? "sessions" : page;
        if (!_pages.TryGetValue(key, out var view))
        {
            view = key switch
            {
                "sessions" => new SessionsPage(),
                "settings" => new SettingsPage(),
                _ => new OverviewPage(),
            };
            _pages[key] = view;
        }
        PageHost.Content = view;
        SyncSelection(page);
    }

    /// <summary>三个列表共同组成一个单选侧栏。</summary>
    void SyncSelection(string page)
    {
        _syncing = true;
        MainNav.SelectedItem = MainNav.Items.OfType<ListBoxItem>().FirstOrDefault(i => (string)i.Tag == page);
        SettingsNav.SelectedItem = SettingsNav.Items.OfType<ListBoxItem>().FirstOrDefault(i => (string)i.Tag == page);
        ToolNav.SelectedItem = _vm.ToolRows.FirstOrDefault(t => "tool:" + t.Id == page);
        _syncing = false;
    }

    void OnNavSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || e.AddedItems.Count == 0) return;
        _vm.Page = e.AddedItems[0] switch
        {
            ListBoxItem { Tag: string tag } => tag,
            ToolRowModel tool => "tool:" + tool.Id,
            _ => _vm.Page,
        };
        SyncSelection(_vm.Page);
    }

    sealed class RelayAction(Action action) : ICommand
    {
        public event EventHandler? CanExecuteChanged
        {
            add { }
            remove { }
        }

        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => action();
    }
}
