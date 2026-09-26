using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using TokenTracker.Core.Localization;
using TokenTracker.Windows.ViewModels;

namespace TokenTracker.Windows.Controls;

/// <summary>
/// 手绘风使用趋势（移植 HandDrawnTrendChart.swift）：Catmull-Rom 平滑曲线 + 确定性抖动笔触，
/// 双轴极简坐标（左 tokens / 右成本，无网格线），悬停画竖向参考线 + 各曲线圆点并浮出数值卡。
/// </summary>
public sealed class TrendChart : FrameworkElement
{
    public static readonly DependencyProperty PointsProperty = DependencyProperty.Register(nameof(Points),
        typeof(IReadOnlyList<TrendPoint>), typeof(TrendChart),
        new FrameworkPropertyMetadata(Array.Empty<TrendPoint>(), FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty IsHourlyProperty = DependencyProperty.Register(nameof(IsHourly),
        typeof(bool), typeof(TrendChart), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));

    public IReadOnlyList<TrendPoint> Points
    {
        get => (IReadOnlyList<TrendPoint>)GetValue(PointsProperty);
        set => SetValue(PointsProperty, value);
    }

    public bool IsHourly
    {
        get => (bool)GetValue(IsHourlyProperty);
        set => SetValue(IsHourlyProperty, value);
    }

    sealed record Series(string Key, Color Color, double Width, bool Dashed, Func<TrendPoint, double> Value)
    {
        public bool IsCost => Key == "成本";
    }

    static readonly Series[] SeriesList =
    [
        new("缓存命中", Color.FromRgb(0xA8, 0x55, 0xF7), 2.0, false, p => p.CacheRead),
        new("非缓存输入", Color.FromRgb(0x3B, 0x82, 0xF6), 1.6, false, p => p.Input),
        new("输出", Color.FromRgb(0x22, 0xC5, 0x5E), 1.6, false, p => p.Output),
        new("缓存创建", Color.FromRgb(0xF5, 0x9E, 0x0B), 1.6, false, p => p.CacheWrite),
        new("成本", Color.FromRgb(0xEF, 0x44, 0x44), 1.4, true, p => p.Cost),
    ];

    int? _hoverIndex;
    Point _hover;

    public TrendChart()
    {
        Height = 220;
        L10n.LanguageChanged += () => Dispatcher.BeginInvoke(InvalidateVisual);
    }

    double MaxTokens => Math.Max(Points.SelectMany(p => new[] { p.Input, p.Output, p.CacheRead, p.CacheWrite }).DefaultIfEmpty(0).Max(), 1);
    double MaxCost => Math.Max(Points.Select(p => p.Cost).DefaultIfEmpty(0).Max(), 0.0001);

    /// <summary>plot 区：左 44（tokens 刻度）/ 右 48（成本刻度）/ 下 20（x 标签）。</summary>
    Rect PlotRect => new(44, 8, Math.Max(ActualWidth - 44 - 48, 10), Math.Max(ActualHeight - 8 - 20, 10));

    double X(int index, Rect plot) =>
        Points.Count > 1 ? plot.Left + plot.Width * index / (Points.Count - 1) : plot.Left + plot.Width / 2;

    static double Y(double v, double max, Rect plot) => plot.Bottom - plot.Height * v / max;

    Brush Secondary => TryFindResource("TextFillColorSecondaryBrush") as Brush ?? Brushes.Gray;
    Brush Primary => TryFindResource("TextFillColorPrimaryBrush") as Brush ?? Brushes.Black;
    Brush CardBackground => TryFindResource("SolidBackgroundFillColorBaseBrush") as Brush ?? Brushes.White;

    FormattedText Text(string text, Brush brush, double size = 11) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), size, brush,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        _hover = e.GetPosition(this);
        var plot = PlotRect;
        int? index = null;
        if (Points.Count > 0 && _hover.X >= plot.Left - 12 && _hover.X <= plot.Right + 12)
            index = Points.Count == 1 ? 0 : Math.Clamp((int)Math.Round((_hover.X - plot.Left) / plot.Width * (Points.Count - 1)), 0, Points.Count - 1);
        _hoverIndex = index;
        InvalidateVisual();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _hoverIndex = null;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, ActualWidth, ActualHeight)); // 命中测试
        if (Points.Count == 0) return;
        if (_hoverIndex >= Points.Count) _hoverIndex = null;
        var plot = PlotRect;
        DrawAxes(dc, plot);
        DrawSeries(dc, plot);
        DrawHover(dc, plot);
    }

    void DrawAxes(DrawingContext dc, Rect plot)
    {
        var baseline = new Pen(Secondary, 1) { DashStyle = DashStyles.Solid };
        baseline.Brush = baseline.Brush.CloneCurrentValue();
        baseline.Brush.Opacity = 0.35;
        dc.DrawLine(baseline, new Point(plot.Left, plot.Bottom), new Point(plot.Right, plot.Bottom));
        foreach (var (i, frac) in new[] { (0, 0.0), (1, 0.5), (2, 1.0) })
        {
            var y = plot.Bottom - plot.Height * frac;
            var left = Text(i == 0 ? "0" : CompactTokens(MaxTokens * frac), Secondary, 10);
            dc.DrawText(left, new Point(plot.Left - 6 - left.Width, y - left.Height / 2));
            var right = Text(i == 0 ? "$0" : UiFormat.Cost(MaxCost * frac), Secondary, 10);
            dc.DrawText(right, new Point(plot.Right + 6, y - right.Height / 2));
        }
        foreach (var index in XLabelIndices())
        {
            var raw = Points[index].Day;
            var label = Text(IsHourly ? raw : raw.Length >= 5 ? raw[^5..] : raw, Secondary, 10);
            dc.DrawText(label, new Point(X(index, plot) - label.Width / 2, plot.Bottom + 4));
        }
    }

    IEnumerable<int> XLabelIndices()
    {
        var n = Points.Count;
        return n > 5 ? Enumerable.Range(0, 5).Select(i => i * (n - 1) / 4) : Enumerable.Range(0, n);
    }

    List<Point> Pixels(Func<TrendPoint, double> value, double max, Rect plot) =>
        Points.Select((p, i) => new Point(X(i, plot), Y(value(p), max, plot))).ToList();

    void DrawSeries(DrawingContext dc, Rect plot)
    {
        // 缓存命中：先铺渐变面积，再描主线
        var hit = Pixels(p => p.CacheRead, MaxTokens, plot);
        if (hit.Count > 1)
        {
            var area = SketchGeometry(hit, 0xC0FFEE, close: true, plot.Bottom);
            var fill = new LinearGradientBrush(Color.FromArgb(0x29, 0xA8, 0x55, 0xF7), Color.FromArgb(0x05, 0xA8, 0x55, 0xF7), 90);
            dc.DrawGeometry(fill, null, area);
        }
        for (var i = 0; i < SeriesList.Length; i++)
        {
            var series = SeriesList[i];
            var pts = Pixels(series.Value, series.IsCost ? MaxCost : MaxTokens, plot);
            if (pts.Count == 1)
            {
                // 只有一个时间桶时连不成线：画点，至少让数值可见
                dc.DrawEllipse(new SolidColorBrush(series.Color), null, pts[0], 3.5, 3.5);
                continue;
            }
            if (pts.Count < 2) continue;
            var pen = new Pen(new SolidColorBrush(Color.FromArgb(series.Dashed ? (byte)217 : (byte)230, series.Color.R, series.Color.G, series.Color.B)), series.Width)
            {
                StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round,
                DashStyle = series.Dashed ? new DashStyle([5 / series.Width, 4 / series.Width], 0) : DashStyles.Solid,
            };
            dc.DrawGeometry(null, pen, SketchGeometry(pts, 0x5EED + (ulong)i * 7919, close: false, 0));
        }
    }

    void DrawHover(DrawingContext dc, Rect plot)
    {
        if (_hoverIndex is not { } index) return;
        var x = X(index, plot);
        dc.DrawLine(new Pen(Secondary, 1) { DashStyle = new DashStyle([3, 3], 0) }, new Point(x, plot.Top), new Point(x, plot.Bottom));
        foreach (var series in SeriesList)
        {
            var y = Y(series.Value(Points[index]), series.IsCost ? MaxCost : MaxTokens, plot);
            dc.DrawEllipse(new SolidColorBrush(series.Color), new Pen(CardBackground, 1.2), new Point(x, y), 3, 3);
        }
        // 数值卡
        const double cardWidth = 170, cardHeight = 122;
        var tx = Math.Clamp(_hover.X + 14, 4, Math.Max(ActualWidth - cardWidth - 4, 4));
        var ty = Math.Clamp(_hover.Y - cardHeight - 10, 4, Math.Max(ActualHeight - cardHeight - 4, 4));
        var card = new Rect(tx, ty, cardWidth, cardHeight);
        dc.DrawRoundedRectangle(CardBackground, new Pen(Secondary, 0.5), card, 8, 8);
        var point = Points[index];
        var title = Text(IsHourly ? point.Day : point.Day.Length >= 5 ? point.Day[^5..] : point.Day, Secondary, 10);
        dc.DrawText(title, new Point(tx + 8, ty + 6));
        var row = ty + 8 + title.Height;
        foreach (var series in SeriesList)
        {
            dc.DrawEllipse(new SolidColorBrush(series.Color), null, new Point(tx + 11, row + 7), 3, 3);
            dc.DrawText(Text(L10n.T(series.Key), Secondary, 10), new Point(tx + 18, row));
            var value = Text(series.IsCost ? UiFormat.CostPrecise(series.Value(point)) : UiFormat.Tokens((long)series.Value(point), false), Primary, 10);
            dc.DrawText(value, new Point(tx + cardWidth - 8 - value.Width, row));
            row += 20;
        }
    }

    // -------------------------------------------------------- 手绘笔触 ----

    /// <summary>Catmull-Rom 每段采样 8 点 + 确定性双 sin 抖动（seed 固定，重绘不闪烁）。</summary>
    static StreamGeometry SketchGeometry(List<Point> pts, ulong seed, bool close, double baseline)
    {
        var samples = new List<Point>();
        for (var i = 0; i < pts.Count - 1; i++)
        {
            var p0 = pts[Math.Max(i - 1, 0)];
            var p1 = pts[i];
            var p2 = pts[i + 1];
            var p3 = pts[Math.Min(i + 2, pts.Count - 1)];
            for (var s = 0; s < 8; s++) samples.Add(CatmullRom(p0, p1, p2, p3, s / 8.0));
        }
        samples.Add(pts[^1]);
        var phase1 = Hash01(seed, 1) * 2 * Math.PI;
        var phase2 = Hash01(seed, 2) * 2 * Math.PI;
        var total = Math.Max(samples.Count - 1, 1);
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            Point Wobble(int index, Point p)
            {
                var t = (double)index / total * 6 * Math.PI; // 全图约 3 个抖动周期
                return new Point(p.X, p.Y + Math.Sin(t + phase1) * 0.7 + Math.Sin(t * 2.3 + phase2) * 0.5);
            }
            ctx.BeginFigure(Wobble(0, samples[0]), close, close);
            ctx.PolyLineTo(samples.Select((p, i) => Wobble(i, p)).Skip(1).ToList(), true, true);
            if (close)
            {
                ctx.LineTo(new Point(samples[^1].X, baseline), false, false);
                ctx.LineTo(new Point(samples[0].X, baseline), false, false);
            }
        }
        geometry.Freeze();
        return geometry;
    }

    static Point CatmullRom(Point p0, Point p1, Point p2, Point p3, double t)
    {
        var t2 = t * t;
        var t3 = t2 * t;
        double Cr(double a, double b, double c, double d) =>
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3);
        return new Point(Cr(p0.X, p1.X, p2.X, p3.X), Cr(p0.Y, p1.Y, p2.Y, p3.Y));
    }

    /// <summary>splitmix64 尾混合 → [0,1)。</summary>
    static double Hash01(ulong seed, ulong salt)
    {
        unchecked
        {
            var z = seed + 0x9E3779B97F4A7C15UL * (salt + 1);
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            z ^= z >> 31;
            return (z >> 11) / (double)(1UL << 53);
        }
    }

    /// <summary>坐标轴 tokens 紧凑格式：1.2M / 650K / 800。</summary>
    static string CompactTokens(double v) =>
        v >= 1e6 ? (v / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + "M"
        : v >= 1e3 ? (v / 1e3).ToString("0", CultureInfo.InvariantCulture) + "K"
        : Math.Round(v).ToString(CultureInfo.InvariantCulture);
}
