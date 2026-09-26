using System.Globalization;
using System.Windows.Media;
using TokenTracker.Core.Localization;
using TokenTracker.Core.Presentation;

namespace TokenTracker.Windows.ViewModels;

/// <summary>界面格式化（移植 TokenTrackerApp/Formatting.swift）。</summary>
public static class UiFormat
{
    static string F(string format, double value) => value.ToString(format, CultureInfo.InvariantCulture);

    /// <summary>万/亿只在中文界面启用。</summary>
    public static string Tokens(long n, bool yi) => TrayFormatter.FmtTokens(n, yi && !L10n.IsEnglish);

    public static string Number(long n) => n.ToString("N0", CultureInfo.InvariantCulture);

    /// <summary>$%.2f；≥1000 → $%.2fK</summary>
    public static string Cost(double v) => v >= 1000 ? "$" + F("0.00", v / 1000) + "K" : "$" + F("0.00", v);

    /// <summary>精确成本：$%.4f；≥1000 仍走 $%.2fK</summary>
    public static string CostPrecise(double v) => v >= 1000 ? "$" + F("0.00", v / 1000) + "K" : "$" + F("0.0000", v);

    /// <summary>「万」换算：≥1万 → "≈ x.xx 万"，否则原样数字。</summary>
    public static string Wan(long n)
    {
        if (L10n.IsEnglish) return "≈ " + Tokens(n, false);
        return n >= 10_000 ? L10n.Format("≈ %.2f 万", n / 10_000.0) : "≈ " + n.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>概览卡副标签：开启「亿」时只转换真正达到 1 亿的数值，较小数值仍用「万」。</summary>
    public static string OverviewTokens(long n, bool yi)
    {
        if (L10n.IsEnglish) return "≈ " + Tokens(n, false);
        return yi && n >= 100_000_000 ? L10n.Format("≈ %.2f 亿", n / 100_000_000.0) : Wan(n);
    }

    /// <summary>本地时间 "yyyy-MM-dd HH:mm"。</summary>
    public static string DateTime(long? ms) =>
        ms is > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(ms.Value).LocalDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) : "—";

    public static string Percent(double? v) => v is { } p ? F("0.0", p) + "%" : "—";

    public static string TodayString => System.DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>只本地化内置窗口名，自定义配额名保持原样。</summary>
    public static string QuotaLabel(string label) =>
        label is "5 小时" or "周 (7天)" or "月度" or "5h" or "7d" ? L10n.T(label) : label;

    public static string ToolName(string id) => id switch
    {
        "claude" => "Claude Code", "codex" => "Codex", "opencode" => "opencode", "dsh" => "DSH",
        "hermes" => "Hermes", "kimi" => "Kimi", "pi" => "Pi", "go" => "OpenCode Go", _ => id,
    };

    static readonly Dictionary<string, SolidColorBrush> ToolBrushes = new();

    public static Brush ToolBrush(string id)
    {
        if (ToolBrushes.TryGetValue(id, out var cached)) return cached;
        var brush = TrayFormatter.ToolHex.TryGetValue(id, out var hex)
            ? new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex))
            : new SolidColorBrush(Color.FromRgb(0x8a, 0x8a, 0x8a));
        brush.Freeze();
        ToolBrushes[id] = brush;
        return brush;
    }

    public static readonly SolidColorBrush Accent = Frozen(0xD9, 0x77, 0x57);
    public static readonly SolidColorBrush Ok = Frozen(0x34, 0xA8, 0x53);
    public static readonly SolidColorBrush Warn = Frozen(0xF0, 0x8C, 0x00);
    public static readonly SolidColorBrush Crit = Frozen(0xE0, 0x3E, 0x3E);
    public static readonly SolidColorBrush Muted = Frozen(0x8A, 0x8A, 0x8A);

    static SolidColorBrush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    public static Brush UrgencyBrush(string role) => role switch
    {
        "quota_crit" => Crit,
        "quota_warn" => Warn,
        "quota_ok" => Ok,
        _ => Muted,
    };
}
