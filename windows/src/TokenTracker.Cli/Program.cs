// tt-win — TokenTracker Windows CLI（移植 swift/Sources/tt-swift/main.swift 的 detect/scan/stats/quotas），
// 与 App、Swift/Python 版共用 %USERPROFILE%\.tokentracker\usage.db。开发检查用，不进发布包。
using System.Globalization;
using System.Text;
using TokenTracker.Core.Billing;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Quotas;
using TokenTracker.Core.Scanners;
using TokenTracker.Core.Store;

Console.OutputEncoding = Encoding.UTF8;
var command = args.FirstOrDefault() ?? "help";

UsageStore OpenStore() => new(UsageStore.DefaultPath, PriceTable.LoadEffective());
static string Fmt(long n) => n.ToString("N0", CultureInfo.InvariantCulture);
static string FmtCost(double v) => "$" + v.ToString("0.00", CultureInfo.InvariantCulture);

switch (command)
{
    case "detect":
    {
        using var store = OpenStore();
        var runner = new ScanRunner(store, PriceTable.LoadEffective(), ScanRoots.FromEnvironment());
        foreach (var (name, info) in runner.DetectAll().OrderBy(kv => kv.Key, StringComparer.Ordinal))
            Console.WriteLine($"{(info.Installed ? "✅" : "—")} {name,-10} {info.Detail}");
        break;
    }
    case "scan":
    {
        using var store = OpenStore();
        var prices = PriceTable.LoadEffective();
        var runner = new ScanRunner(store, prices, ScanRoots.FromEnvironment());
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var results = runner.RunAll(full: args.Contains("--full"));
        var repriced = store.Reprice(prices);
        foreach (var tool in ScannerRegistry.All)
        {
            if (!results.TryGetValue(tool, out var r)) continue;
            if (r.Error is not null) Console.WriteLine($"✗ {tool,-10} 出错: {r.Error}");
            else if (r.Skipped is not null) Console.WriteLine($"— {tool,-10} {r.Skipped}");
            else
            {
                Console.WriteLine($"✓ {tool,-10} 新增 {r.Added} 条 / 更新 {r.Updated} 条 / 文件 {r.Files} 个");
                if (r.ActivityAdded > 0 || r.ActivityUpdated > 0)
                    Console.WriteLine($"  活动: 新增 {r.ActivityAdded} 条 / 补全 {r.ActivityUpdated} 条");
            }
            if (r.CounterResets > 0) Console.WriteLine($"⚠ {tool}: {r.CounterResets} 个累计计数器重置，已更新基线并保留历史");
            if (r.Warning is not null) Console.WriteLine($"⚠ {tool}: {r.Warning}");
        }
        if (repriced > 0) Console.WriteLine($"✓ reprice 按价格表回填 {repriced} 条成本");
        Console.WriteLine($"耗时 {watch.Elapsed.TotalSeconds:0.00}s");
        break;
    }
    case "stats":
    {
        using var store = OpenStore();
        var range = args.Length >= 3 && args[1] == "--range" ? args[2] : "all";
        var stats = store.Stats(range);
        Console.WriteLine($"范围: {range}");
        Console.WriteLine("工具        会话    tokens          成本");
        foreach (var row in stats.Rows)
            Console.WriteLine($"{row.Tool,-11} {row.Sessions}\t{Fmt(row.Tokens)}\t{FmtCost(row.Cost)}");
        Console.WriteLine($"合计        {stats.Total.Sessions}\t{Fmt(stats.Total.Tokens)}\t{FmtCost(stats.Total.Cost)}");
        if (stats.Summary.UnallocatedTokens > 0)
            Console.WriteLine($"（另有未分配时间的历史: {Fmt(stats.Summary.UnallocatedTokens)} tokens，估算: {Fmt(stats.Summary.EstimatedTokens)}）");
        break;
    }
    case "quotas":
    {
        using var store = OpenStore();
        var service = new OfficialQuotaService();
        var entries = QuotaEstimator.Compute(store, QuotasConfig.LoadEffective(), store.NowMs(),
            name => service.ProviderResult(name));
        foreach (var entry in entries)
        {
            Console.WriteLine($"{entry.Name}  {(entry.Source == "official" ? "[官方]" : "[本地]")}  {entry.Plan}");
            foreach (var w in entry.Windows)
            {
                var pct = w.Pct is { } p ? p.ToString("0.0", CultureInfo.InvariantCulture) + "%" : "—";
                var marker = w.Source == "official" ? w.Stale ? "~官方(旧)" : "官方" : "≈本地";
                Console.WriteLine($"  {w.Label,-10} {pct}  {marker}");
            }
            if (entry.Note.Length > 0) Console.WriteLine($"  ⚠ {entry.Note}");
        }
        break;
    }
    default:
        Console.WriteLine("""
            tt-win — TokenTracker Windows CLI（开发检查用）
              tt-win detect            查看各工具数据源是否被识别
              tt-win scan [--full]     扫描日志入库（增量，可重复执行）
              tt-win stats [--range day|week|month|all]
              tt-win quotas            查看全部配额窗口（官方只读 / 本地估算）
            环境变量: TOKENTRACKER_DB / TOKENTRACKER_PRICES / TOKENTRACKER_QUOTAS 等
            """);
        break;
}
