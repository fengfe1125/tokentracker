using System.Globalization;
using System.Windows;
using System.Windows.Media;
using TokenTracker.Windows.ViewModels;

namespace TokenTracker.Windows.Controls;

/// <summary>配额圆环（卡片版，移植 OverviewView.swift 的 RingView）：轨道 + 填充弧 + 中心百分比。</summary>
public sealed class QuotaRing : FrameworkElement
{
    public static readonly DependencyProperty PctProperty = DependencyProperty.Register(nameof(Pct), typeof(double?),
        typeof(QuotaRing), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty RoleProperty = DependencyProperty.Register(nameof(Role), typeof(string),
        typeof(QuotaRing), new FrameworkPropertyMetadata("quota_none", FrameworkPropertyMetadataOptions.AffectsRender));

    public double? Pct
    {
        get => (double?)GetValue(PctProperty);
        set => SetValue(PctProperty, value);
    }

    public string Role
    {
        get => (string)GetValue(RoleProperty);
        set => SetValue(RoleProperty, value);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var size = Math.Min(ActualWidth, ActualHeight);
        if (size <= 0) return;
        const double stroke = 5;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        var radius = (size - stroke) / 2;
        var brush = UiFormat.UrgencyBrush(Pct is null ? "quota_none" : Role);
        if (Pct is not { } pct)
        {
            dc.DrawEllipse(null, new Pen(UiFormat.Muted, 1.5), center, radius, radius);
        }
        else
        {
            var track = brush.CloneCurrentValue();
            track.Opacity = 0.22;
            dc.DrawEllipse(null, new Pen(track, stroke), center, radius, radius);
            var fraction = Math.Clamp(pct / 100, 0, 1);
            if (fraction >= 0.999)
            {
                dc.DrawEllipse(null, new Pen(brush, stroke), center, radius, radius);
            }
            else if (fraction > 0)
            {
                var angle = fraction * 2 * Math.PI;
                var start = new Point(center.X, center.Y - radius);
                var end = new Point(center.X + radius * Math.Sin(angle), center.Y - radius * Math.Cos(angle));
                var geometry = new StreamGeometry();
                using (var ctx = geometry.Open())
                {
                    ctx.BeginFigure(start, false, false);
                    ctx.ArcTo(end, new Size(radius, radius), 0, fraction > 0.5, SweepDirection.Clockwise, true, false);
                }
                dc.DrawGeometry(null, new Pen(brush, stroke) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, geometry);
            }
        }
        var textBrush = TryFindResource(Pct is null ? "TextFillColorTertiaryBrush" : "TextFillColorPrimaryBrush") as Brush ?? Brushes.Gray;
        var text = new FormattedText(Pct is { } p ? p.ToString("0", CultureInfo.InvariantCulture) : "—",
            CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
            11, textBrush, VisualTreeHelper.GetDpi(this).PixelsPerDip);
        dc.DrawText(text, new Point(center.X - text.Width / 2, center.Y - text.Height / 2));
    }
}
