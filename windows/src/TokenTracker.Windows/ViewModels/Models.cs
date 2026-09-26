using System.Windows.Media;
using TokenTracker.Core.Localization;
using TokenTracker.Core.Presentation;
using TokenTracker.Core.Store;

namespace TokenTracker.Windows.ViewModels;

/// <summary>每个时间桶跨工具聚合后的用量点。</summary>
public sealed record TrendPoint(string Day, double Input, double Output, double CacheRead, double CacheWrite, double Cost);

public sealed record ModelRowModel(int Rank, string Tool, string Model, string Tokens, string Cost)
{
    public Brush ToolBrush => UiFormat.ToolBrush(Tool);
    public string DisplayModel => Model.Length == 0 ? L10n.T("（未知模型）") : Model;
}

public sealed record QuotaWindowRow(string Label, string Value, Brush Brush);

/// <summary>配额卡：品牌色圆环 = 最紧窗口，右侧窗口明细行。</summary>
public sealed record QuotaCardModel(string Id, string Name, string Badge, double? RingPct, string RingRole,
    IReadOnlyList<QuotaWindowRow> Windows, string Note)
{
    public bool HasNote => Note.Length > 0;

    public static QuotaCardModel From(TrayQuotaEntry entry, string note)
    {
        var best = TrayFormatter.BestWindow(entry);
        var windows = entry.Windows.Select(w => new QuotaWindowRow(UiFormat.QuotaLabel(w.Label),
            TrayFormatter.QuotaMarker(w) + (w.Pct is { } p ? p.ToString("0", System.Globalization.CultureInfo.InvariantCulture) + "%" : "—"),
            TrayFormatter.QuotaUrgency(w.Pct) is "quota_ok" ? UiFormat.Muted : UiFormat.UrgencyBrush(TrayFormatter.QuotaUrgency(w.Pct))))
            .ToList();
        return new QuotaCardModel(entry.Id, entry.Name,
            entry.Windows.Any(w => w.Source == "official") ? L10n.T("官方") : L10n.T("本地估算"),
            best?.Pct, best?.Pct is null ? "quota_none" : TrayFormatter.QuotaUrgency(best.Pct), windows, note);
    }
}

/// <summary>侧栏工具行：色点 + 名称 + 数据源状态 + 今日量。</summary>
public sealed record ToolRowModel(string Id, bool Installed, string Trailing)
{
    public string Name => UiFormat.ToolName(Id);
    public Brush DotBrush => Installed ? UiFormat.ToolBrush(Id) : UiFormat.Muted;
    public double Opacity => Installed ? 1 : 0.55;
}

/// <summary>会话表行（移植 SessionRowModel）。</summary>
public sealed class SessionRowModel(SessionRow row, bool yi)
{
    public SessionRow Row { get; } = row;
    public string Id => $"{Row.Tool}|{Row.SessionId}";
    public string Tool => Row.Tool;
    public string ToolName => UiFormat.ToolName(Row.Tool);
    public Brush ToolBrush => UiFormat.ToolBrush(Row.Tool);
    public string SessionId => Row.SessionId;
    public string Title => !string.IsNullOrEmpty(Row.Title) ? Row.Title : Row.Project.Length == 0 ? Row.SessionId : Row.Project;
    public string Project => Row.Project;

    /// <summary>列表只显示最后一段（完整路径进 tooltip）；claude 的 slug 原样保留。</summary>
    public string ProjectShort
    {
        get
        {
            if (Row.Project.Length == 0) return "—";
            if (!Core.Platform.WinPaths.IsAbsoluteProjectPath(Row.Project)) return Row.Project;
            return Core.Platform.WinPaths.LastComponent(Row.Project);
        }
    }

    public string Model => Row.Model;

    (string Date, string Time)? LastSeenParts =>
        Row.LastSeen?.Split(' ') is [var date, var time] ? (date, time.Length >= 5 ? time[..5] : time) : null;

    public string TimeText => LastSeenParts?.Time ?? "—";

    /// <summary>当天的行省略日期。</summary>
    public string? DateText => LastSeenParts is { } p && p.Date != UiFormat.TodayString ? p.Date : null;

    public string WhenText => string.Join(" ", new[] { DateText, TimeText }.Where(s => s is not null));
    public long SortTs => Row.Ts ?? 0;
    public long ActivityExact => Row.ActivityExact;
    public string ActivityText => L10n.T("{0} 次", Row.ActivityExact);

    public string ActivitySubtitle
    {
        get
        {
            var parts = new List<string>();
            if (Row.ActivityDerived > 0) parts.Add(L10n.T("推断 {0}", Row.ActivityDerived));
            if (Row.Skills > 0) parts.Add($"Skill {Row.Skills}");
            return string.Join(" · ", parts);
        }
    }

    public long Tokens => Row.Stats.Tokens;
    public string TokensText => UiFormat.Tokens(Row.Stats.Tokens, yi);
    public double Cost => Row.Stats.Cost;
    public string CostText => UiFormat.Cost(Row.Stats.Cost);
}

public sealed record DetailModelRow(string Model, string Tokens, string Breakdown);

public sealed record DetailActivityRow(string Name, string Calls, string Evidence, Brush EvidenceBrush);

/// <summary>会话详情侧栏（MVP：会话信息 + 工具摘要 + 按模型分解 + 观察区间）。</summary>
public sealed record SessionDetailModel(IReadOnlyList<DetailModelRow> Models, IReadOnlyList<DetailActivityRow> Activity,
    IReadOnlyList<string> Intervals)
{
    public bool HasActivity => Activity.Count > 0;
    public bool HasIntervals => Intervals.Count > 0;
}
