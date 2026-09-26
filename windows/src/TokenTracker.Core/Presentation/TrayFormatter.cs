using System.Globalization;
using TokenTracker.Core.Quotas;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Presentation;

public sealed record TodayUsage(long Tokens, double Cost, bool Unpriced = false);

public sealed record TrayQuotaWindow(double? Pct, string Source, bool Stale, string Label);

public sealed record TrayQuotaEntry(string Id, string Name, IReadOnlyList<TrayQuotaWindow> Windows)
{
    /// <summary>从配额计算结果转换（只留展示需要的字段）。</summary>
    public static TrayQuotaEntry From(QuotaEntryResult result) =>
        new(result.Id, result.Name, result.Windows.Select(w => new TrayQuotaWindow(w.Pct, w.Source, w.Stale, w.Label)).ToList());
}

/// <summary>段落：role 与 Swift/Python 一致（tokens/dim/glyph/marker/cost/ink/quota_ok/quota_warn/quota_crit/quota_none/dot_&lt;id&gt;）。</summary>
public sealed record Segment(string Text, string Role);

/// <summary>
/// 托盘文案与配额环（移植 MenuBar/MenuBarFormatter.swift 的纯逻辑）。
/// Windows 托盘没有文字标题：标题分段用于 tooltip 与菜单「当前：」预览，配额环画成图标。
/// </summary>
public static class TrayFormatter
{
    public static readonly IReadOnlyDictionary<string, string> ProviderGlyph =
        new Dictionary<string, string> { ["claude"] = "C", ["codex"] = "X", ["kimi"] = "K", ["go"] = "G" };

    public const double WarnPct = 50;
    public const double CritPct = 80;

    /// <summary>工具标识色（菜单圆点、侧栏用）。</summary>
    public static readonly IReadOnlyDictionary<string, string> ToolHex = new Dictionary<string, string>
    {
        ["claude"] = "#d97757", ["codex"] = "#5b8def", ["opencode"] = "#34b3a0", ["dsh"] = "#b98ae0",
        ["hermes"] = "#e0a13e", ["kimi"] = "#e06a9a", ["pi"] = "#7fb069", ["go"] = "#8b7bd8",
    };

    static readonly string[] RingGlyphs = ["○", "◔", "◑", "◕", "●"];

    static string F(string format, double value) => value.ToString(format, CultureInfo.InvariantCulture);

    public static string QuotaUrgency(double? pct)
    {
        var p = pct ?? 0;
        if (p >= CritPct) return "quota_crit";
        if (p >= WarnPct) return "quota_warn";
        return "quota_ok";
    }

    /// <summary>官方过期 ~ / 本地估算 ≈ / 官方新鲜无标记。</summary>
    public static string QuotaMarker(TrayQuotaWindow window) =>
        window.Source == "official" ? window.Stale ? "~" : "" : "≈";

    public static string FmtTokens(double n, bool yi = false)
    {
        n = Math.Max(n, 0);
        if (yi && n >= 1e6) return F("0.00", n / 1e8) + "亿";
        if (n >= 1e9) return F("0.00", n / 1e9) + "B";
        if (n >= 1e6) return F("0.00", n / 1e6) + "M";
        if (n >= 1e4) return F("0.0", n / 1e3) + "K";
        if (n >= 1e3) return F("0.00", n / 1e3) + "K";
        return ((long)n).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>entry 里 pct 最高的窗口（最紧的那个）。</summary>
    public static TrayQuotaWindow? BestWindow(TrayQuotaEntry? entry)
    {
        TrayQuotaWindow? best = null;
        foreach (var w in entry?.Windows ?? [])
        {
            if (w.Pct is null) continue;
            if (best is null || w.Pct > (best.Pct ?? 0)) best = w;
        }
        return best;
    }

    public static string FmtQuota(TrayQuotaWindow window) => QuotaMarker(window) + F("0", window.Pct ?? 0) + "%";

    /// <summary>标题分段（对齐 fmtSegments；Windows 用于 tooltip 与菜单预览，ring=true 时省略 ⚡）。</summary>
    public static List<Segment> TitleSegments(TodayUsage? today, IReadOnlyList<TrayQuotaEntry>? entries, string? provider,
        bool compact = false, bool yi = false, bool ring = false)
    {
        var sep = compact ? "" : " ";
        var lead = ring ? "" : sep;
        var segs = ring ? new List<Segment>() : [new Segment("⚡", "bolt")];
        segs.Add(today is not null ? new Segment(lead + FmtTokens(today.Tokens, yi), "tokens") : new Segment(lead + "—", "dim"));
        if (provider is null or "off") return segs;
        var entry = entries?.FirstOrDefault(e => e.Id == provider);
        if (BestWindow(entry) is not { Pct: not null } best) return segs;
        var glyph = ProviderGlyph.TryGetValue(provider, out var g)
            ? g
            : (string.IsNullOrEmpty(entry?.Name) ? "?" : entry!.Name[..1]);
        var marker = QuotaMarker(best);
        segs.Add(new Segment(compact ? "·" : " · ", "dim"));
        segs.Add(new Segment(glyph, "glyph"));
        if (ring)
        {
            if (marker == "≈") segs.Add(new Segment(marker, "marker"));
            return segs;
        }
        if (marker == "≈")
        {
            segs.Add(new Segment(sep + marker, "marker"));
            segs.Add(new Segment(F("0", best.Pct ?? 0) + "%", QuotaUrgency(best.Pct)));
        }
        else
        {
            segs.Add(new Segment(sep + F("0", best.Pct ?? 0) + "%", QuotaUrgency(best.Pct)));
        }
        return segs;
    }

    public static string Title(TodayUsage? today, IReadOnlyList<TrayQuotaEntry>? entries, string? provider,
        bool compact = false, bool yi = false, bool ring = false) =>
        string.Concat(TitleSegments(today, entries, provider, compact, yi, ring).Select(s => s.Text));

    /// <summary>配额环参数：pct=null → 灰色空心圆（无配额数据 / 仅今日用量）。</summary>
    public static (double? Pct, string Role) RingSpec(IReadOnlyList<TrayQuotaEntry>? entries, string? provider)
    {
        if (provider is not null and not "off")
        {
            var entry = entries?.FirstOrDefault(e => e.Id == provider);
            if (BestWindow(entry)?.Pct is { } pct)
            {
                var clamped = Math.Clamp(pct, 0, 100);
                return (clamped, QuotaUrgency(clamped));
            }
        }
        return (null, "quota_none");
    }

    /// <summary>配额环的纯文本近似字符（菜单「当前：」预览用）。</summary>
    public static string RingGlyph((double? Pct, string Role) spec)
    {
        if (spec.Pct is not { } pct) return RingGlyphs[0];
        var idx = (int)PythonJson.RoundHalfEven(pct / 100 * (RingGlyphs.Length - 1), 0);
        return RingGlyphs[Math.Clamp(idx, 0, RingGlyphs.Length - 1)];
    }

    public static List<Segment> TodayLineSegments(TodayUsage? today, bool yi = false) =>
        today is null
            ? [new Segment("今日暂无数据（点「立即扫描」）", "dim")]
            :
            [
                new Segment("今日 ", "dim"), new Segment(FmtTokens(today.Tokens, yi), "tokens"),
                new Segment(" tokens", "dim"), new Segment(" · ", "dim"),
                new Segment(today.Unpriced ? "未计价" : "≈$" + F("0.00", today.Cost), "cost"),
            ];

    /// <summary>菜单配额行：●(工具色点) 名称 · 窗口 label pct(紧急度色)。</summary>
    public static List<Segment> QuotaLineSegments(TrayQuotaEntry entry)
    {
        var name = entry.Name.Length == 0 ? "?" : entry.Name;
        if (BestWindow(entry) is not { } best) return [new Segment(name, "ink")];
        return
        [
            new Segment("● ", "dot_" + entry.Id), new Segment(name, "ink"), new Segment($" · {best.Label} ", "dim"),
            new Segment(FmtQuota(best), QuotaUrgency(best.Pct)),
        ];
    }
}
