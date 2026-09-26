using System.Globalization;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Scanners;
using TokenTracker.Core.Store;
using Xunit;

namespace TokenTracker.Core.Tests.Differential;

/// <summary>
/// 差分测试：同一份虚构语料，C# 扫描器的结果必须与 Python 基线（tests/differential/expected_python.json）
/// 逐字段一致。语料由 make_corpus.py 生成到临时目录，路径规范化规则与 export_python.py 相同。
/// </summary>
public sealed class DifferentialScanTests
{
    const long FixedNowMs = 1_787_626_800_000;
    const string CanonicalCorpus = "/private/tmp/tt_diff_corpus";
    const string LegacyCorpus = "/tmp/tt_diff_corpus";

    static ProcessResult RunPython(string script, string argument)
    {
        var env = new Dictionary<string, string?> { ["PYTHONUTF8"] = "1", ["PYTHONIOENCODING"] = "utf-8" };
        var configured = Environment.GetEnvironmentVariable("TT_PYTHON");
        var candidates = configured is { Length: > 0 }
            ? new[] { (configured, Array.Empty<string>()) }
            : new[] { ("python", Array.Empty<string>()), ("py", new[] { "-3" }) };
        Exception? last = null;
        foreach (var (exe, prefix) in candidates)
        {
            try
            {
                var resolved = CliFind.Resolve(exe) ?? exe;
                return ProcessRunner.Run(resolved, [.. prefix, script, argument], TimeSpan.FromMinutes(2), env);
            }
            catch (System.ComponentModel.Win32Exception e)
            {
                last = e;
            }
        }
        throw new InvalidOperationException("找不到 Python 解释器（可设置 TT_PYTHON）", last);
    }

    [Fact]
    public void BaselineLoads()
    {
        var expected = PyJson.ReadObjectFile(TestSupport.Repo("tests", "differential", "expected_python.json"));
        Assert.NotNull(expected);
        Assert.Equal((long)AppInfo.DifferentialFormatVersion, expected!.Get("format_version"));
    }

    [Fact]
    public void ScannersMatchPythonBaseline()
    {
        using var temp = new TempDir();
        var corpusDir = Path.Combine(temp.Path, "corpus");
        Directory.CreateDirectory(corpusDir);
        var corpus = WinPaths.Real(corpusDir);
        var result = RunPython(TestSupport.Repo("tests", "differential", "make_corpus.py"), corpus);
        Assert.True(result.ExitCode == 0, $"make_corpus.py 失败：{result.Stderr}{result.Stdout}");

        var roots = new ScanRoots
        {
            Claude = Path.Combine(corpus, "claude", "projects"),
            CodexLogsDb = Path.Combine(corpus, "codex", "logs_2.sqlite"),
            CodexSessions = Path.Combine(corpus, "codex", "sessions"),
            OpencodeDb = Path.Combine(corpus, "opencode", "opencode.db"),
            DshSessions = Path.Combine(corpus, "dsh", "sessions"),
            HermesHomes = [Path.Combine(corpus, "hermes")],
            KimiCodeHome = Path.Combine(corpus, "kimi-code", "server", "events"),
            KimiCli = Path.Combine(corpus, "kimi-cli-nonexistent"),
            PiRoots = [Path.Combine(corpus, "pi", "sessions")],
        };
        var prices = PriceTable.Load(TestSupport.Repo("tests", "differential", "prices.json"));
        Dictionary<string, object?> actual;
        using (var store = temp.Store(FixedNowMs))
        {
            var scanResults = new ScanRunner(store, prices, roots).RunAll();
            store.Reprice(prices);
            actual = Export(store, scanResults, corpus);
        }

        var expected = PyJson.ReadObjectFile(TestSupport.Repo("tests", "differential", "expected_python.json"))!;
        AssertRows(expected, actual, "events");
        AssertRows(expected, actual, "activities");
        AssertRows(expected, actual, "session_meta");
        AssertRows(expected, actual, "snapshots");
        var expectedScans = (Dictionary<string, object?>)expected["scan_results"]!;
        var actualScans = (Dictionary<string, object?>)actual["scan_results"]!;
        foreach (var (tool, value) in expectedScans)
        {
            Assert.True(actualScans.ContainsKey(tool), $"缺少 {tool} 扫描结果");
            AssertJsonEqual(value, actualScans[tool], $"scan_results.{tool}");
        }
    }

    static Dictionary<string, object?> Export(UsageStore store, Dictionary<string, ScanOutcome> scans, string corpus)
    {
        string Canon(string value)
        {
            if (value == corpus) return CanonicalCorpus;
            if (value.StartsWith(corpus + "\\", StringComparison.Ordinal))
                return CanonicalCorpus + value[corpus.Length..].Replace('\\', '/');
            return value;
        }
        static object? Round6(object? v) => v is double d ? Math.Round(d, 6, MidpointRounding.ToEven) : v;

        var events = store.Conn.Query(
                "SELECT tool,src_key,session_id,project,ts,model,input,output,cache_read,cache_write,cost,time_quality,"
                + "interval_start,cost_source,source_kind,source_scope FROM usage_events ORDER BY tool,src_key")
            .Select(r => r.Values.ToDictionary(kv => kv.Key, kv => kv.Key == "cost" ? Round6(kv.Value) : kv.Value)).ToList();
        var activities = store.Conn.Query(
                "SELECT agent,session_id,turn_id,raw_name,canonical_name,namespace,call_id,parent_call_id,started_at,ended_at,"
                + "duration_ms,status,source_kind,confidence,event_kind,event_layer,skill_name,skill_confidence,src_key "
                + "FROM agent_activity_events ORDER BY agent,src_key")
            .Select(r => new Dictionary<string, object?>(r.Values)).ToList();
        var meta = store.Conn.Query("SELECT tool,session_id,title FROM session_meta ORDER BY tool,session_id")
            .Select(r => new Dictionary<string, object?>(r.Values)).ToList();
        var snapshots = new List<Dictionary<string, object?>>();
        foreach (var r in store.Conn.Query(
                     "SELECT tool,source_scope,identity,values_json,observed_at,revision FROM aggregate_snapshots ORDER BY tool,source_scope,identity"))
        {
            var row = new Dictionary<string, object?>(r.Values);
            var values = PyJson.ParseObject((string)row["values_json"]!)!;
            row.Remove("values_json");
            row["values"] = values.ToDictionary(kv => kv.Key, kv => Round6(kv.Value));
            snapshots.Add(row);
        }

        // aggregate 摘要包含 source_scope：规范化语料真实路径后重算摘要。
        var digestMap = new Dictionary<string, string>();
        foreach (var snapshot in snapshots)
        {
            var scope = (string)snapshot["source_scope"]!;
            var canonical = Canon(scope);
            if (canonical == scope) continue;
            var identity = (string)snapshot["identity"]!;
            digestMap[PythonJson.Sha256Hex(PythonJson.Dumps(new object?[] { scope, identity }))] =
                PythonJson.Sha256Hex(PythonJson.Dumps(new object?[] { canonical, identity }));
            snapshot["source_scope"] = canonical;
        }
        foreach (var e in events)
        {
            e["source_scope"] = Canon((string)e["source_scope"]!);
            var key = (string)e["src_key"]!;
            if (key.StartsWith("aggregate|", StringComparison.Ordinal))
            {
                var parts = key.Split('|', 3);
                parts[1] = digestMap.GetValueOrDefault(parts[1], parts[1]);
                e["src_key"] = string.Join("|", parts);
            }
            else if (key.StartsWith("legacy|" + corpus + "\\", StringComparison.Ordinal))
            {
                // Python 基线里 legacy 键是未经 realpath 的 /tmp 路径
                var rest = key[("legacy|" + corpus).Length..];
                var bar = rest.LastIndexOf('|');
                e["src_key"] = "legacy|" + LegacyCorpus + rest[..bar].Replace('\\', '/') + rest[bar..];
            }
        }
        foreach (var a in activities) a["src_key"] = Canon((string)a["src_key"]!);
        events.Sort((x, y) => CompareKeys(x, y, "tool"));
        activities.Sort((x, y) => CompareKeys(x, y, "agent"));
        snapshots.Sort((x, y) =>
        {
            var c = string.CompareOrdinal((string)x["tool"]!, (string)y["tool"]!);
            if (c != 0) return c;
            c = string.CompareOrdinal((string)x["source_scope"]!, (string)y["source_scope"]!);
            return c != 0 ? c : string.CompareOrdinal((string)x["identity"]!, (string)y["identity"]!);
        });

        var scanResults = new Dictionary<string, object?>();
        foreach (var (tool, o) in scans)
        {
            var d = new Dictionary<string, object?>
            {
                ["added"] = (long)o.Added, ["updated"] = (long)o.Updated, ["files"] = (long)o.Files,
                ["activity_added"] = (long)o.ActivityAdded, ["activity_updated"] = (long)o.ActivityUpdated,
            };
            if (tool is "opencode" or "hermes") d["counter_resets"] = (long)o.CounterResets;
            if (o.Warning is not null) d["warning"] = o.Warning;
            if (o.Skipped is not null) d["skipped"] = o.Skipped;
            if (o.Error is not null) d["error"] = o.Error;
            scanResults[tool] = d;
        }
        return new Dictionary<string, object?>
        {
            ["events"] = events.Cast<object?>().ToList(),
            ["activities"] = activities.Cast<object?>().ToList(),
            ["session_meta"] = meta.Cast<object?>().ToList(),
            ["snapshots"] = snapshots.Cast<object?>().ToList(),
            ["scan_results"] = scanResults,
        };
    }

    static int CompareKeys(Dictionary<string, object?> x, Dictionary<string, object?> y, string first)
    {
        var c = string.CompareOrdinal((string)x[first]!, (string)y[first]!);
        return c != 0 ? c : string.CompareOrdinal((string)x["src_key"]!, (string)y["src_key"]!);
    }

    static void AssertRows(Dictionary<string, object?> expected, Dictionary<string, object?> actual, string section)
    {
        var e = (List<object?>)expected[section]!;
        var a = (List<object?>)actual[section]!;
        for (var i = 0; i < Math.Min(e.Count, a.Count); i++)
            AssertJsonEqual(e[i], a[i], $"{section}[{i}]");
        Assert.True(e.Count == a.Count,
            $"{section}: 期望 {e.Count} 行，实际 {a.Count} 行\n实际多出：{PyJson.Serialize(a.Skip(e.Count).ToList())}");
    }

    static void AssertJsonEqual(object? expected, object? actual, string path)
    {
        if (expected is Dictionary<string, object?> ed)
        {
            var ad = Assert.IsType<Dictionary<string, object?>>(actual);
            foreach (var key in ed.Keys.Union(ad.Keys))
            {
                ed.TryGetValue(key, out var ev);
                ad.TryGetValue(key, out var av);
                AssertJsonEqual(ev, av, $"{path}.{key}");
            }
            return;
        }
        if (PyJson.AsNumber(expected) is { } en && PyJson.AsNumber(actual) is { } an)
        {
            Assert.True(Math.Abs(en - an) < 1e-9,
                $"{path}: 期望 {en.ToString(CultureInfo.InvariantCulture)}，实际 {an.ToString(CultureInfo.InvariantCulture)}");
            return;
        }
        Assert.True(Equals(expected, actual),
            $"{path}: 期望 {PyJson.Serialize(expected)}，实际 {PyJson.Serialize(actual)}");
    }
}
