using System.Windows.Media;
using TokenTracker.Core.Localization;
using TokenTracker.Core.Presentation;

namespace TokenTracker.Windows.ViewModels;

public sealed record DetailCard(string Title, string Value, string Detail, Brush Tint);

public sealed record ProviderOption(string Id, string Label);

public sealed record LanguageOption(string Id, string Label);

/// <summary>界面展示用的派生文案（语言切换 / 数据刷新后统一通知）。</summary>
public sealed partial class AppViewModel
{
    static readonly string[] TextProperties =
    [
        nameof(UpdatedText), nameof(TotalTokensText), nameof(TotalTokensSub), nameof(EventsText), nameof(TotalCostText),
        nameof(DetailCards), nameof(HitRate), nameof(HitRateText), nameof(RangeLabel), nameof(ScanButtonText),
        nameof(IntervalIndex), nameof(HasTrend), nameof(HasModels), nameof(HasQuotas), nameof(SessionsTitle),
        nameof(SessionsSubtitle), nameof(HasSessions), nameof(EmptySessionsTitle), nameof(EmptySessionsHint),
        nameof(ProviderOptions), nameof(LanguageOptions), nameof(IsChinese),
    ];

    void NotifyTexts()
    {
        foreach (var name in TextProperties) OnPropertyChanged(name);
    }

    partial void OnStatTotalChanged(Core.Store.ToolStats value) => NotifyTexts();
    partial void OnUpdatedAtChanged(DateTime? value) => OnPropertyChanged(nameof(UpdatedText));
    partial void OnScanningChanged(bool value) => OnPropertyChanged(nameof(ScanButtonText));
    partial void OnSessionRowsChanged(IReadOnlyList<SessionRowModel> value)
    {
        OnPropertyChanged(nameof(SessionsSubtitle));
        OnPropertyChanged(nameof(HasSessions));
    }

    // ------------------------------------------------------------ 概览 ----

    public string UpdatedText => UpdatedAt is { } at
        ? L10n.T("更新于 ") + UiFormat.DateTime(new DateTimeOffset(at).ToUnixTimeMilliseconds())
        : "";

    public string TotalTokensText => UiFormat.Number(StatTotal.Tokens);
    public string TotalTokensSub => UiFormat.OverviewTokens(StatTotal.Tokens, UnitYi);
    public string EventsText => UiFormat.Number(StatTotal.Events);

    public string TotalCostText => StatTotal.Events > 0 && StatTotal.Unpriced == StatTotal.Events
        ? L10n.T("未计价")
        : UiFormat.CostPrecise(StatTotal.Cost);

    public IReadOnlyList<DetailCard> DetailCards
    {
        get
        {
            var t = StatTotal;
            var yi = UnitYi;
            return
            [
                new DetailCard(L10n.T("输入总量"), UiFormat.Number(t.InputSideTokens),
                    L10n.T("非缓存 {0} · 读取 {1} · 创建 {2}", UiFormat.OverviewTokens(t.Input, yi),
                        UiFormat.OverviewTokens(t.CacheRead, yi), UiFormat.OverviewTokens(t.CacheWrite, yi)),
                    new SolidColorBrush(Color.FromRgb(0x3B, 0x82, 0xF6))),
                new DetailCard(L10n.T("模型输出"), UiFormat.Number(t.Output), UiFormat.OverviewTokens(t.Output, yi),
                    new SolidColorBrush(Color.FromRgb(0xA8, 0x55, 0xF7))),
                new DetailCard(L10n.T("缓存创建"), UiFormat.Number(t.CacheWrite), UiFormat.OverviewTokens(t.CacheWrite, yi),
                    UiFormat.Muted),
                new DetailCard(L10n.T("缓存命中"), UiFormat.Number(t.CacheRead), UiFormat.OverviewTokens(t.CacheRead, yi),
                    new SolidColorBrush(Color.FromRgb(0x63, 0x66, 0xF1))),
            ];
        }
    }

    public double HitRate => StatTotal.CacheHitRate ?? 0;
    public string HitRateText => UiFormat.Percent(StatTotal.CacheHitRate);

    public string RangeLabel => Range switch
    {
        "day" => L10n.T("今天"),
        "week" => L10n.T("近 7 天"),
        "month" => L10n.T("本月"),
        _ => L10n.T("全部"),
    };

    public string ScanButtonText => Scanning ? L10n.T("扫描中…") : L10n.T("扫描");

    static readonly long[] Intervals = [30, 60, 300, 600];

    /// <summary>刷新间隔下拉（写设置键 scan_interval）。</summary>
    public int IntervalIndex
    {
        get => Math.Max(0, Array.IndexOf(Intervals, ScanIntervalSeconds));
        set
        {
            if (value >= 0 && value < Intervals.Length) UpdateSetting("scan_interval", Intervals[value]);
        }
    }

    public bool HasTrend => TrendPoints.Count > 0;
    public bool HasModels => TopModels.Count > 0;
    public bool HasQuotas => QuotaCards.Count > 0;

    partial void OnTrendPointsChanged(IReadOnlyList<TrendPoint> value) => OnPropertyChanged(nameof(HasTrend));
    partial void OnTopModelsChanged(IReadOnlyList<ModelRowModel> value) => OnPropertyChanged(nameof(HasModels));
    partial void OnQuotaCardsChanged(IReadOnlyList<QuotaCardModel> value)
    {
        OnPropertyChanged(nameof(HasQuotas));
        OnPropertyChanged(nameof(ProviderOptions));
    }

    // ------------------------------------------------------------ 会话 ----

    public string SessionsTitle => ToolFilter is { } tool ? L10n.T("{0} 的会话", UiFormat.ToolName(tool)) : L10n.T("会话记录");

    public string SessionsSubtitle
    {
        get
        {
            var n = SessionRows.Count;
            if (n >= SessionLimit) return L10n.T("最近 {0} 个会话（查询上限）", n);
            return SessionSearch.Length == 0 ? L10n.T("共 {0} 个会话", n) : L10n.T("匹配 {0} 个会话", n);
        }
    }

    public bool HasSessions => SessionRows.Count > 0;
    public string EmptySessionsTitle => SessionSearch.Length == 0 ? L10n.T("暂无会话") : L10n.T("没有匹配的会话");
    public string EmptySessionsHint => SessionSearch.Length == 0 ? L10n.T("换个时间范围，或到概览点「扫描」") : L10n.T("试试清空搜索词");

    // ------------------------------------------------------------ 设置 ----

    public bool IsChinese => !L10n.IsEnglish;

    public IReadOnlyList<ProviderOption> ProviderOptions =>
    [
        .. QuotaEntries.Select(e => new ProviderOption(e.Id, L10n.T("今日用量 + {0}", e.Name))),
        new ProviderOption("off", L10n.T("仅今日用量")),
    ];

    public string ProviderSetting
    {
        get => MenubarProvider;
        set
        {
            if (value is not null && value != MenubarProvider) UpdateSetting("menubar_provider", value);
        }
    }

    public bool RingSetting
    {
        get => MenubarRing;
        set => UpdateSetting("menubar_ring", value);
    }

    public bool UnitYiSetting
    {
        get => UnitYi;
        set => UpdateSetting("unit_yi", value);
    }

    public bool LaunchAtLoginSetting
    {
        get => LaunchAtLogin;
        set
        {
            UpdateSetting("launch_at_login", value);
            if (value && !Lifecycle.AutoStart.IsRegistered()) UpdateStatus = L10n.T("开机自动启动失败：无法写入注册表");
        }
    }

    public IReadOnlyList<LanguageOption> LanguageOptions =>
    [
        new("system", L10n.T("跟随系统")), new("zh-Hans", "简体中文"), new("en", "English"),
    ];

    public string ReleasesUrl => Core.Updates.UpdateChecker.ReleasesUrl;

    public string DataDirectory => Core.Platform.WinPaths.DataDir;

    /// <summary>托盘提示与菜单预览用的标题。</summary>
    public string TrayTitle => TrayFormatter.Title(Today, QuotaEntries, MenubarProvider, MenubarCompact, UnitYi && IsChinese, MenubarRing);
}
