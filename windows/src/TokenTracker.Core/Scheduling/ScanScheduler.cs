using TokenTracker.Core.Scanners;

namespace TokenTracker.Core.Scheduling;

public sealed record ScanLast
{
    public double StartedAt { get; init; }
    public double FinishedAt { get; init; }
    public string Source { get; init; } = "";
    public bool Done { get; init; }
    public string? Error { get; init; }
    public int Added { get; init; }
    public int ActivityAdded { get; init; }
    public int ActivityUpdated { get; init; }
    public int Repriced { get; init; }
    public int CounterResets { get; init; }
    public IReadOnlyList<string> Warnings { get; init; } = [];
}

public sealed record ScanSchedulerStatus(bool Running, ScanLast? Last);

/// <summary>
/// 移植 ScanScheduler.swift（server.py 的 ScanService）：一次只跑一个扫描，手动与定时共用；
/// 失败记录后释放；Stop 不取消进行中的事务，只阻止新扫描并有界等待。
/// </summary>
public sealed class ScanScheduler
{
    public delegate (Dictionary<string, ScanOutcome> Results, int Repriced) ScanFunc(IReadOnlyList<string>? tools, bool full);

    readonly ScanFunc _scan;
    readonly Func<double> _clock;
    readonly object _lock = new();
    readonly ManualResetEventSlim _stopSignal = new(false);
    double _interval;
    bool _stopped;
    ScanSchedulerStatus _status = new(false, null);
    Thread? _worker;
    Thread? _timer;

    /// <summary>扫描完成回调（在扫描线程上调用，调用方负责切 UI 线程）。</summary>
    public event Action? Finished;

    public ScanScheduler(ScanFunc scan, double interval = 60, Func<double>? clock = null)
    {
        _scan = scan;
        _interval = interval;
        _clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
    }

    public ScanSchedulerStatus Snapshot()
    {
        lock (_lock) return _status;
    }

    public double IntervalSeconds
    {
        get
        {
            lock (_lock) return _interval;
        }
    }

    /// <summary>运行中热改间隔：自动循环每轮等待前读最新值。</summary>
    public void SetInterval(double seconds)
    {
        if (seconds <= 0) return;
        lock (_lock) _interval = seconds;
    }

    /// <summary>请求一次扫描；运行中/已停止返回 false。</summary>
    public bool Request(IReadOnlyList<string>? tools = null, bool full = false, string source = "manual")
    {
        Thread worker;
        lock (_lock)
        {
            if (_stopped || _status.Running) return false;
            _status = new ScanSchedulerStatus(true, new ScanLast { StartedAt = _clock(), Source = source });
            worker = new Thread(() => Run(tools, full)) { IsBackground = true, Name = "tt-scan", Priority = ThreadPriority.BelowNormal };
            _worker = worker;
        }
        worker.Start();
        return true;
    }

    void Run(IReadOnlyList<string>? tools, bool full)
    {
        string? scanError = null;
        int added = 0, activityAdded = 0, activityUpdated = 0, repriced = 0, resets = 0;
        var warnings = new List<string>();
        try
        {
            var (results, rep) = _scan(tools, full);
            repriced = rep;
            var errors = new List<string>();
            foreach (var (name, outcome) in results)
            {
                if (outcome.Error is not null) errors.Add($"{name}: {outcome.Error}");
                if (outcome.Warning is not null) warnings.Add(outcome.Warning);
                added += outcome.Added;
                activityAdded += outcome.ActivityAdded;
                activityUpdated += outcome.ActivityUpdated;
                resets += outcome.CounterResets;
            }
            if (errors.Count > 0) scanError = string.Join("; ", errors);
        }
        catch (Exception e)
        {
            // 失败的扫描不得污染共享锁
            scanError = e.Message;
        }
        lock (_lock)
        {
            _status = new ScanSchedulerStatus(false, (_status.Last ?? new ScanLast()) with
            {
                Done = true, FinishedAt = _clock(), Error = scanError, Added = added, ActivityAdded = activityAdded,
                ActivityUpdated = activityUpdated, Repriced = repriced, CounterResets = resets, Warnings = warnings,
            });
        }
        Finished?.Invoke();
    }

    /// <summary>启动自动调度：立即扫一次，此后每 interval 秒增量扫描。</summary>
    public void StartAuto()
    {
        Thread timer;
        lock (_lock)
        {
            if (_stopped || _timer is not null) return;
            timer = new Thread(AutoLoop) { IsBackground = true, Name = "tt-scan-timer" };
            _timer = timer;
        }
        timer.Start();
    }

    void AutoLoop()
    {
        Request(source: "automatic");
        while (!_stopSignal.Wait(TimeSpan.FromSeconds(IntervalSeconds)))
            Request(source: "automatic");
    }

    /// <summary>停止调度：不取消进行中的 SQLite 事务；阻止新扫描并有界等待。</summary>
    public void Stop()
    {
        Thread? worker, timer;
        lock (_lock)
        {
            _stopped = true;
            worker = _worker;
            timer = _timer;
        }
        _stopSignal.Set();
        foreach (var thread in new[] { worker, timer })
            if (thread is not null && thread != Thread.CurrentThread) thread.Join(TimeSpan.FromSeconds(2));
    }
}
