using TokenTracker.Core.Activity;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

public sealed class ScanOutcome
{
    public int Added { get; set; }
    public int Updated { get; set; }
    public int Files { get; set; }
    public int CounterResets { get; set; }
    public int ActivityAdded { get; set; }
    public int ActivityUpdated { get; set; }
    public string? Warning { get; set; }
    public string? Skipped { get; set; }
    public string? Error { get; set; }
}

public interface IScanner
{
    string Name { get; }
    string Detail { get; }
    bool Detect();

    /// <summary>抛错由 ScanRunner 捕获并回滚该工具的事务。</summary>
    ScanOutcome Scan(UsageStore store, PriceTable prices, bool full);
}

public sealed record DetectInfo(bool Installed, string Detail);

/// <summary>各工具数据源根目录（默认取环境变量 / 本机路径；差分测试注入语料目录）。</summary>
public sealed record ScanRoots
{
    public required string Claude { get; init; }
    public required string CodexLogsDb { get; init; }
    public required string CodexSessions { get; init; }
    public required string OpencodeDb { get; init; }
    public required string DshSessions { get; init; }
    public required IReadOnlyList<string> HermesHomes { get; init; }
    public required string KimiCodeHome { get; init; }
    public required string KimiCli { get; init; }
    public required IReadOnlyList<string> PiRoots { get; init; }

    public static ScanRoots FromEnvironment()
    {
        var home = WinPaths.Home;
        string Env(string name, string fallback) =>
            WinPaths.Expand(Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : fallback);
        var hermesEnv = Environment.GetEnvironmentVariable("HERMES_HOME");
        return new ScanRoots
        {
            Claude = Env("CLAUDE_PROJECTS_DIR", Path.Combine(home, ".claude", "projects")),
            CodexLogsDb = Env("CODEX_LOGS_DB", Path.Combine(home, ".codex", "logs_2.sqlite")),
            CodexSessions = Env("CODEX_SESSIONS_DIR", Path.Combine(home, ".codex", "sessions")),
            OpencodeDb = Env("OPENCODE_DB", Path.Combine(home, ".local", "share", "opencode", "opencode.db")),
            DshSessions = Env("DSH_SESSIONS_DIR", Path.Combine(home, ".dsh", "sessions")),
            // Hermes 在 Windows 上有两处数据目录；HERMES_HOME 显式指定时只看它。
            HermesHomes = hermesEnv is { Length: > 0 }
                ? [WinPaths.Expand(hermesEnv)]
                : [Path.Combine(home, ".hermes"), Path.Combine(WinPaths.LocalAppData, "hermes")],
            KimiCodeHome = Env("KIMI_CODE_HOME", Path.Combine(home, ".kimi-code", "server", "events")),
            KimiCli = Path.Combine(home, ".kimi", "sessions"),
            PiRoots = [Env("PI_HOME", Path.Combine(home, ".pi", "agent", "sessions")), Path.Combine(home, ".omp")],
        };
    }
}

public static class ScannerRegistry
{
    public static readonly string[] All = ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"];

    public static IScanner? Make(string name, ScanRoots roots) => name switch
    {
        "claude" => new ClaudeScanner(roots.Claude),
        "codex" => new CodexScanner(roots.CodexLogsDb, roots.CodexSessions),
        "opencode" => new OpencodeScanner(roots.OpencodeDb),
        "dsh" => new DshScanner(roots.DshSessions),
        "hermes" => new HermesScanner(roots.HermesHomes),
        "kimi" => new KimiScanner(roots.KimiCodeHome, roots.KimiCli),
        "pi" => new PiScanner(roots.PiRoots),
        _ => null,
    };
}

/// <summary>run_all：单工具出错不影响其他工具；BEGIN IMMEDIATE → scan → error ? rollback : commit。</summary>
public sealed class ScanRunner(UsageStore store, PriceTable prices, ScanRoots roots)
{
    public UsageStore Store { get; } = store;

    public Dictionary<string, DetectInfo> DetectAll()
    {
        var output = new Dictionary<string, DetectInfo>();
        foreach (var name in ScannerRegistry.All)
        {
            var adapter = ScannerRegistry.Make(name, roots);
            output[name] = adapter is null ? new DetectInfo(false, "未知工具") : new DetectInfo(adapter.Detect(), adapter.Detail);
        }
        return output;
    }

    public Dictionary<string, ScanOutcome> RunAll(IEnumerable<string>? tools = null, bool full = false)
    {
        var results = new Dictionary<string, ScanOutcome>();
        foreach (var name in tools ?? ScannerRegistry.All)
        {
            var adapter = ScannerRegistry.Make(name, roots);
            if (adapter is null) continue;
            ScanDiagnostics.Begin();
            var started = Store.NowMs();
            if (!adapter.Detect())
            {
                results[name] = new ScanOutcome { Skipped = "未检测到数据源" };
                TryRecordHealth(name, results[name], started);
                continue;
            }
            try
            {
                if (!Store.Conn.InTransaction) Store.Conn.BeginImmediate();
                var effectiveFull = full;
                var cursor = Store.GetScanCursor(name);
                if (ActivityNormalizer.NeedsBackfill(cursor))
                {
                    // 活动元数据可重建：保留 token 历史与会话元数据，只重新解析该 Agent。
                    Store.ClearActivityEvents(name);
                    effectiveFull = true;
                }
                var outcome = adapter.Scan(Store, prices, effectiveFull);
                if (outcome.Error is not null) Store.Conn.Rollback();
                else Store.Conn.Commit();
                results[name] = outcome;
            }
            catch (Exception e)
            {
                try
                {
                    Store.Conn.Rollback();
                }
                catch (SqliteException)
                {
                }
                results[name] = new ScanOutcome { Error = e.Message };
            }
            TryRecordHealth(name, results[name], started);
        }
        try
        {
            Store.Conn.Commit();
        }
        catch (SqliteException)
        {
        }
        return results;
    }

    void TryRecordHealth(string name, ScanOutcome outcome, long started)
    {
        try
        {
            Store.RecordHealth(name, outcome, started, Store.NowMs());
        }
        catch (SqliteException)
        {
        }
    }
}
