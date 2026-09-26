using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using TokenTracker.Windows.ViewModels;

namespace TokenTracker.Windows.Views;

/// <summary>
/// 会话记录（移植 SessionsView.swift）：可排序表 + 右侧详情栏。数据刷新会替换行集合，
/// 这里记住用户的排序并在刷新后重新套用；默认按时间倒序（查询本身的顺序）。
/// </summary>
public partial class SessionsPage : UserControl
{
    string? _sortPath;
    ListSortDirection _sortDirection;

    public SessionsPage()
    {
        InitializeComponent();
        DependencyPropertyDescriptor.FromProperty(ItemsControl.ItemsSourceProperty, typeof(DataGrid))
            .AddValueChanged(Table, (_, _) => ReapplySort());
    }

    AppViewModel Vm => (AppViewModel)DataContext;

    void OnSorting(object sender, DataGridSortingEventArgs e)
    {
        _sortPath = e.Column.SortMemberPath;
        _sortDirection = e.Column.SortDirection == ListSortDirection.Ascending
            ? ListSortDirection.Descending
            : ListSortDirection.Ascending;
    }

    void ReapplySort()
    {
        if (_sortPath is null) return;
        var view = CollectionViewSource.GetDefaultView(Table.ItemsSource);
        if (view is null) return;
        view.SortDescriptions.Clear();
        view.SortDescriptions.Add(new SortDescription(_sortPath, _sortDirection));
        foreach (var column in Table.Columns)
            column.SortDirection = column.SortMemberPath == _sortPath ? _sortDirection : null;
    }

    void OnShowDetail(object sender, RoutedEventArgs e)
    {
        if (Table.SelectedItem is SessionRowModel row) Vm.SelectedSession = row;
    }

    void OnCloseDetail(object sender, RoutedEventArgs e) => Vm.SelectedSession = null;

    void OnOpenProject(object sender, RoutedEventArgs e)
    {
        var project = Vm.SelectedSession?.Project;
        if (string.IsNullOrEmpty(project) || !Directory.Exists(project)) return;
        Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { project }, UseShellExecute = false });
    }

    void OnCopyId(object sender, RoutedEventArgs e)
    {
        if (Vm.SelectedSession is { } row) Clipboard.SetText(row.SessionId);
    }
}
