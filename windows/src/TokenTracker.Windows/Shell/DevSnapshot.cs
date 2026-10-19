using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using TokenTracker.Windows.ViewModels;

namespace TokenTracker.Windows.Shell;

/// <summary>
/// 开发自检（对齐 macOS 的 TT_UI_PREVIEW / TT_SELFCHECK）：设置 TT_SNAPSHOT_DIR 后，
/// 启动数秒把三个页面（及滚动区全文）渲染成 PNG，并写出托盘标题；TT_SNAPSHOT_QUIT=1 时随后退出。
/// 普通启动不会触发。
/// </summary>
static class DevSnapshot
{
    public static void ScheduleIfRequested(MainWindow window, AppViewModel vm, Action quit)
    {
        if (Environment.GetEnvironmentVariable("TT_SNAPSHOT_DIR") is not { Length: > 0 } dir) return;
        Directory.CreateDirectory(dir);
        var steps = new Queue<Action>();
        foreach (var page in new[] { "overview", "sessions", "settings" })
        {
            steps.Enqueue(() => vm.Page = page);
            if (page == "sessions")
                steps.Enqueue(() => vm.SelectedSession = vm.SessionRows.FirstOrDefault());
            steps.Enqueue(() =>
            {
                Save(window, Path.Combine(dir, $"{page}.png"));
                SaveScrollContent(window, Path.Combine(dir, $"{page}-full.png"));
            });
        }
        steps.Enqueue(() =>
        {
            File.WriteAllText(Path.Combine(dir, "tray.txt"), vm.TrayTitle);
            if (Environment.GetEnvironmentVariable("TT_SNAPSHOT_QUIT") == "1") quit();
        });
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
        timer.Tick += (_, _) =>
        {
            timer.Interval = TimeSpan.FromSeconds(2);
            if (steps.Count == 0) timer.Stop();
            else steps.Dequeue()();
        };
        timer.Start();
    }

    static void Save(Window window, string path)
    {
        if (window.Content is FrameworkElement root) Render(window, root, path);
    }

    /// <summary>当前页面第一个滚动区的全部内容（含视口外部分）。</summary>
    static void SaveScrollContent(Window window, string path)
    {
        if (window is MainWindow main && FindChild<ScrollViewer>(main.PageHost) is { Content: FrameworkElement content })
            Render(window, content, path);
    }

    static T? FindChild<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match && (child is not FrameworkElement fe || fe.IsVisible)) return match;
            if (FindChild<T>(child) is { } nested) return nested;
        }
        return null;
    }

    static void Render(Window window, FrameworkElement element, string path)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        var width = element.ActualWidth;
        var height = element.ActualHeight;
        if (width <= 0 || height <= 0) return;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var background = window.TryFindResource("ApplicationBackgroundBrush") as Brush ?? Brushes.White;
            dc.DrawRectangle(background, null, new Rect(0, 0, width, height));
            dc.DrawRectangle(new VisualBrush(element) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top },
                null, new Rect(0, 0, width, height));
        }
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(width * dpi.DpiScaleX), (int)Math.Ceiling(height * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
