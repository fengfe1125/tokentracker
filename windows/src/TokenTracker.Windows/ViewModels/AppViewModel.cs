using System.Collections.Concurrent;
using System.IO;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TokenTracker.Core;
using TokenTracker.Core.Billing;
using TokenTracker.Core.Json;
using TokenTracker.Core.Localization;
using TokenTracker.Core.Presentation;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Quotas;
using TokenTracker.Core.Scanners;
using TokenTracker.Core.Scheduling;
using TokenTracker.Core.Settings;
using TokenTracker.Core.Store;
using TokenTracker.Core.Updates;
using TokenTracker.Windows.Lifecycle;

namespace TokenTracker.Windows.ViewModels;

/// <summary>
/// 应用状态（移植 AppState.swift 的 MVP 子集）：扫描调度 + 5s 轮询（扫描状态、设置热生效）
/// + 60s 数据与配额刷新。所有查询在后台线程各开短连接，按通道串行，代次计数丢弃过期结果。
/// </summary>
public sealed partial class AppViewModel : ObservableObject
{
    public const int SessionLimit = 300;

    readonly string _dbPath;
    readonly PriceTable _prices;
    readonly ScanRoots _roots;
    readonly SettingsStore _settingsStore = new();
    readonly OfficialQuotaService _official = new();
    readonly AppStateFile _appState = new();
    readonly Dispatcher _dispatcher;
    readonly SemaphoreSlim _queryLane = new(1, 1);
    readonly SemaphoreSlim _detailLane = new(1, 1);
    readonly DispatcherTimer _pollTimer;
    readonly DispatcherTimer _refreshTimer;
    readonly DispatcherTimer _searchDebounce;
    ScanScheduler? _scheduler;
    string _settingsFingerprint = "";
    int _dataGeneration;
    int _sessionsGeneration;
    int _detailGeneration;
    bool _quotaBusy;
    IReadOnlyList<QuotaEntryResult> _quotaResults = [];

    public AppViewModel()
    {
        _dispatcher = Dispatcher.CurrentDispatcher;
        _dbPath = UsageStore.DefaultPath;
        _prices = PriceTable.LoadEffective();
        _roots = ScanRoots.FromEnvironment();
        Settings = _settingsStore.Effective();
        _settingsFingerprint = _settingsStore.Fingerprint();
        L10n.SetLanguage(L10n.Resolve(_appState.Language));
        L10n.LanguageChanged += () => _dispatcher.Invoke(OnLanguageChanged);
        _pollTimer = new DispatcherTimer(TimeSpan.FromSeconds(5), DispatcherPriority.Background, (_, _) => Poll(), _dispatcher);
        _refreshTimer = new DispatcherTimer(TimeSpan.FromSeconds(60), DispatcherPriority.Background,
            (_, _) => { RefreshData(); RefreshQuotas(); }, _dispatcher);
        _searchDebounce = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Background,
            (_, _) => { _searchDebounce!.Stop(); RefreshSessions(); }, _dispatcher);
        _searchDebounce.Stop();
    }

    public AppStateFile AppState => _appState;

    // ------------------------------------------------------------ 托盘数据 ----

    [ObservableProperty] TodayUsage? _today;
    [ObservableProperty] IReadOnlyList<TrayQuotaEntry> _quotaEntries = [];
    [ObservableProperty] IReadOnlyList<QuotaCardModel> _quotaCards = [];
    [ObservableProperty] bool _scanning;
    [ObservableProperty] ScanLast? _lastScan;

    // ------------------------------------------------------------ 主面板数据 ----

    /// <summary>overview / sessions / tool:&lt;id&gt; / settings</summary>
    [ObservableProperty] string _page = "overview";
    [ObservableProperty] string _range = "week";
    [ObservableProperty] ToolStats _statTotal = new();
    [ObservableProperty] IReadOnlyList<TrendPoint> _trendPoints = [];
    [ObservableProperty] IReadOnlyList<ModelRowModel> _topModels = [];
    [ObservableProperty] IReadOnlyList<SessionRowModel> _sessionRows = [];
    [ObservableProperty] string _sessionSearch = "";
    [ObservableProperty] SessionRowModel? _selectedSession;
    [ObservableProperty] SessionDetailModel? _sessionDetail;
    [ObservableProperty] IReadOnlyList<ToolRowModel> _toolRows = ScannerRegistry.All.Select(t => new ToolRowModel(t, false, "")).ToList();
    [ObservableProperty] UpdateInfo? _updateInfo;
    [ObservableProperty] DateTime? _updatedAt;
    [ObservableProperty] Dictionary<string, object?> _settings;
    [ObservableProperty] string _updateStatus = "";

    public string? ToolFilter => Page.StartsWith("tool:", StringComparison.Ordinal) ? Page[5..] : null;
    public bool IsSessionsPage => Page == "sessions" || ToolFilter is not null;

    // ------------------------------------------------------------ 设置 ----

    public bool UnitYi => Settings.Get("unit_yi") is true;
    public bool MenubarRing => Settings.Get("menubar_ring") is not false;
    public bool MenubarCompact => Settings.Get("menubar_compact") is true;
    public string MenubarProvider => Settings.Get("menubar_provider") as string ?? "claude";
    public long ScanIntervalSeconds => PyJson.AsLong(Settings.Get("scan_interval")) ?? 60;
    public bool LaunchAtLogin => Settings.Get("launch_at_login") is true;

    public bool UpdateSetting(string key, object? value)
    {
        if (!_settingsStore.Set(key, value)) return false;
        ApplySettings(_settingsStore.Effective());
        _settingsFingerprint = _settingsStore.Fingerprint();
        if (key == "launch_at_login" && value is bool on) AutoStart.Apply(on);
        return true;
    }

    void ApplySettings(Dictionary<string, object?> effective)
    {
        Settings = effective;
        _scheduler?.SetInterval(ScanIntervalSeconds);
        OnPropertyChanged(nameof(UnitYi));
        OnPropertyChanged(nameof(MenubarRing));
        OnPropertyChanged(nameof(MenubarCompact));
        OnPropertyChanged(nameof(MenubarProvider));
        OnPropertyChanged(nameof(ScanIntervalSeconds));
        OnPropertyChanged(nameof(LaunchAtLogin));
        OnPropertyChanged(nameof(ProviderSetting));
        OnPropertyChanged(nameof(RingSetting));
        OnPropertyChanged(nameof(UnitYiSetting));
        OnPropertyChanged(nameof(LaunchAtLoginSetting));
        RebuildDerived();
    }

    public string LanguagePreference
    {
        get => _appState.Language;
        set
        {
            if (value == _appState.Language) return;
            _appState.Language = value;
            OnPropertyChanged();
            L10n.SetLanguage(L10n.Resolve(value));
        }
    }

    void OnLanguageChanged()
    {
        RebuildDerived();
        OnPropertyChanged(string.Empty);
    }

    // ------------------------------------------------------------ 启动 ----

    public void Start()
    {
        // 开机自启与设置对齐（exe 被移动后修正路径）
        if (LaunchAtLogin) AutoStart.Apply(true);
        var path = _dbPath;
        var prices = _prices;
        var roots = _roots;
        _scheduler = new ScanScheduler((tools, full) =>
        {
            using var writeStore = new UsageStore(path, prices);
            var results = new ScanRunner(writeStore, prices, roots).RunAll(tools, full);
            var repriced = writeStore.Reprice(prices);
            return (results, repriced);
        }, ScanIntervalSeconds);
        _scheduler.Finished += () => _dispatcher.BeginInvoke(() =>
        {
            Poll();
            RefreshData();
        });
        _scheduler.StartAuto();
        _pollTimer.Start();
        _refreshTimer.Start();
        RefreshData();
        RefreshQuotas();
        // 更新检查：启动 30s 后后台一次（缓存 24h），失败静默
        Task.Delay(TimeSpan.FromSeconds(30)).ContinueWith(_ =>
        {
            var info = new UpdateChecker().Check();
            _dispatcher.BeginInvoke(() => UpdateInfo = info);
        });
    }

    public void Stop()
    {
        _pollTimer.Stop();
        _refreshTimer.Stop();
        _scheduler?.Stop();
    }

    [RelayCommand]
    public void Scan()
    {
        Scanning = true; // 立即反馈；真实状态以轮询为准
        _scheduler?.Request(source: "manual");
    }

    [RelayCommand]
    void SetRange(string range) => Range = range;

    partial void OnRangeChanged(string value) => RefreshData();

    partial void OnPageChanged(string value)
    {
        OnPropertyChanged(nameof(ToolFilter));
        OnPropertyChanged(nameof(IsSessionsPage));
        OnPropertyChanged(nameof(SessionsTitle));
        SelectedSession = null;
        RefreshData();
    }

    partial void OnSessionSearchChanged(string value)
    {
        _searchDebounce.Stop();
        _searchDebounce.Start();
    }

    partial void OnSelectedSessionChanged(SessionRowModel? value) => LoadSessionDetail(value);

    // ------------------------------------------------------------ 轮询 ----

    void Poll()
    {
        var snapshot = _scheduler?.Snapshot();
        if (snapshot is not null)
        {
            if (Scanning != snapshot.Running) Scanning = snapshot.Running;
            if (!Equals(LastScan, snapshot.Last)) LastScan = snapshot.Last;
        }
        var fingerprint = _settingsStore.Fingerprint();
        if (fingerprint == _settingsFingerprint) return;
        _settingsFingerprint = fingerprint;
        ApplySettings(_settingsStore.Effective());
    }

    // ------------------------------------------------------------ 数据 ----

    sealed record DataSnapshot(StatsResult Stats, List<DailyRow> Daily, List<ModelRow> Models, List<SessionRow> Sessions,
        StatsResult Day, Dictionary<string, DetectInfo> Detect);

    DataSnapshot? _data;

    public async void RefreshData()
    {
        var generation = ++_dataGeneration;
        var range = Range;
        var tool = ToolFilter;
        var search = SessionSearch;
        var snapshot = await OnLane(_queryLane, () =>
        {
            using var store = new UsageStore(_dbPath, _prices);
            return new DataSnapshot(store.Stats(range), store.Daily(range), store.Models(range),
                store.Sessions(range, tool, SessionLimit, search.Length == 0 ? null : search), store.Stats("day"),
                new ScanRunner(store, _prices, _roots).DetectAll());
        });
        if (snapshot is null || generation != _dataGeneration) return;
        _data = snapshot;
        var day = snapshot.Day.Total;
        Today = new TodayUsage(day.Tokens, day.Cost, day.Events > 0 && day.Unpriced == day.Events);
        StatTotal = snapshot.Stats.Total;
        if (search == SessionSearch) SetSessions(snapshot.Sessions);
        UpdatedAt = DateTime.Now;
        RebuildDerived();
    }

    void RebuildDerived()
    {
        if (_data is { } snapshot)
        {
            // 每个时间桶跨工具聚合（daily 是 分桶×工具 粒度）
            var order = new List<string>();
            var acc = new Dictionary<string, double[]>();
            foreach (var row in snapshot.Daily)
            {
                if (!acc.TryGetValue(row.Day, out var a))
                {
                    order.Add(row.Day);
                    acc[row.Day] = a = new double[5];
                }
                a[0] += row.Stats.Input;
                a[1] += row.Stats.Output;
                a[2] += row.Stats.CacheRead;
                a[3] += row.Stats.CacheWrite;
                a[4] += row.Stats.Cost;
            }
            TrendPoints = order.Select(d => new TrendPoint(d, acc[d][0], acc[d][1], acc[d][2], acc[d][3], acc[d][4])).ToList();
            TopModels = snapshot.Models.Take(10).Select((m, i) =>
                new ModelRowModel(i + 1, m.Tool, m.Model, UiFormat.Tokens(m.Stats.Tokens, UnitYi), UiFormat.Cost(m.Stats.Cost))).ToList();
            var todayByTool = snapshot.Day.Rows.ToDictionary(r => r.Tool, r => r.Tokens);
            ToolRows = ScannerRegistry.All.Select(t =>
            {
                var installed = snapshot.Detect.TryGetValue(t, out var info) && info.Installed;
                var trailing = !installed ? L10n.T("未检测到")
                    : todayByTool.TryGetValue(t, out var tokens) ? UiFormat.Tokens(tokens, UnitYi) : "";
                return new ToolRowModel(t, installed, trailing);
            }).ToList();
            SetSessions(snapshot.Sessions);
        }
        var entries = _quotaResults.Select(TrayQuotaEntry.From).ToList();
        QuotaEntries = entries;
        QuotaCards = entries.Select((e, i) => QuotaCardModel.From(e, _quotaResults[i].Note)).ToList();
        NotifyTexts();
    }

    void SetSessions(List<SessionRow> rows)
    {
        var selectedId = SelectedSession?.Id;
        SessionRows = rows.Select(r => new SessionRowModel(r, UnitYi)).ToList();
        if (selectedId is not null) SelectedSession = SessionRows.FirstOrDefault(r => r.Id == selectedId);
    }

    public async void RefreshSessions()
    {
        var generation = ++_sessionsGeneration;
        var (range, tool, search) = (Range, ToolFilter, SessionSearch);
        var rows = await OnLane(_detailLane, () =>
        {
            using var store = new UsageStore(_dbPath, _prices);
            return store.Sessions(range, tool, SessionLimit, search.Length == 0 ? null : search);
        });
        if (rows is null || generation != _sessionsGeneration || search != SessionSearch || range != Range) return;
        SetSessions(rows);
    }

    async void LoadSessionDetail(SessionRowModel? row)
    {
        var generation = ++_detailGeneration;
        SessionDetail = null;
        if (row is null) return;
        var yi = UnitYi;
        var detail = await OnLane(_detailLane, () =>
        {
            using var store = new UsageStore(_dbPath, _prices);
            return store.GetSessionDetail(row.Tool, row.SessionId);
        });
        if (detail is null || generation != _detailGeneration) return;
        SessionDetail = new SessionDetailModel(
            detail.Models.Select(m => new DetailModelRow(m.Model.Length == 0 ? L10n.T("（未知）") : m.Model,
                UiFormat.Tokens(m.Stats.Tokens, yi),
                L10n.T("输入 {0} · ", UiFormat.Tokens(m.Stats.Input, yi))
                + L10n.T("输出 {0} · ", UiFormat.Tokens(m.Stats.Output, yi))
                + L10n.T("缓存 {0} · ", UiFormat.Tokens(m.Stats.CacheRead + m.Stats.CacheWrite, yi))
                + UiFormat.Cost(m.Stats.Cost))).ToList(),
            detail.ActivitySummary.Select(a => new DetailActivityRow(a.Name, L10n.T("{0} 次", a.Calls),
                a.Derived > 0 ? L10n.T("推断 {0}", a.Derived) : L10n.T("已确认"),
                a.Derived > 0 ? UiFormat.Warn : UiFormat.Ok)).ToList(),
            detail.ObservationIntervals.Select(i =>
                $"{UiFormat.DateTime(i.IntervalStart)} → {UiFormat.DateTime(i.Ts)} · {UiFormat.Tokens(i.Tokens, yi)}").ToList());
    }

    public async void RefreshQuotas()
    {
        if (_quotaBusy) return;
        _quotaBusy = true;
        var results = await Task.Run(() =>
        {
            try
            {
                using var store = new UsageStore(_dbPath, _prices);
                var config = QuotasConfig.LoadEffective();
                // 官方抓取并行；任一失败不阻塞整体
                var official = new ConcurrentDictionary<string, OfficialResult>();
                Parallel.ForEach(config.Entries.Select(e => e.Official).OfType<string>().Distinct(),
                    name => official[name] = _official.ProviderResult(name));
                var accountId = PythonJson.Sha256Hex(new CodexBilling(_official.Ctx).AccountId())[..12];
                foreach (var (provider, result) in official)
                {
                    if (result.Error is not null || result.StaleMin is not null || result.SampledAt is not { } sampled) continue;
                    foreach (var (window, value) in result.Windows ?? new Dictionary<string, OfficialWindow>())
                    {
                        if (value.Pct is not { } pct) continue;
                        var reset = DateTimeOffset.TryParse(value.ResetsAt, out var r) ? r.ToUnixTimeMilliseconds() : 0;
                        var identity = $"{provider}:{(provider == "codex" ? accountId : "current")}:{window}";
                        store.RecordQuota(new QuotaSample(identity, (long)(sampled * 1000), pct, reset));
                    }
                }
                return QuotaEstimator.Compute(store, config, store.NowMs(), name => official.GetValueOrDefault(name));
            }
            catch (Exception e) when (e is SqliteException or IOException)
            {
                return null;
            }
        });
        _quotaBusy = false;
        if (results is null) return;
        _quotaResults = results;
        RebuildDerived();
    }

    /// <summary>在指定通道串行执行查询；读库失败（迁移中短暂锁定等）返回 null，下一轮再试。</summary>
    static async Task<T?> OnLane<T>(SemaphoreSlim lane, Func<T> query) where T : class
    {
        await lane.WaitAsync();
        try
        {
            return await Task.Run(() =>
            {
                try
                {
                    return query();
                }
                catch (Exception e) when (e is SqliteException or IOException)
                {
                    System.Diagnostics.Debug.WriteLine($"[tt] query failed: {e.Message}");
                    return null;
                }
            });
        }
        finally
        {
            lane.Release();
        }
    }

    // ------------------------------------------------------------ 更新 ----

    public string Version => AppInfo.Version;

    public bool UpdateAvailable => UpdateChecker.UpdateAvailable(UpdateInfo, AppInfo.Version);

    partial void OnUpdateInfoChanged(UpdateInfo? value) => OnPropertyChanged(nameof(UpdateAvailable));

    [RelayCommand]
    async Task CheckUpdate()
    {
        UpdateStatus = L10n.T("检查中…");
        var info = await Task.Run(() => new UpdateChecker().Check(force: true));
        UpdateInfo = info;
        UpdateStatus = info is null ? L10n.T("检查失败，请稍后重试")
            : UpdateAvailable ? L10n.T("发现新版本 {0} →", info.Latest) : L10n.T("已是最新版本");
    }
}
