using System.Text;
using System.Text.RegularExpressions;
using TokenTracker.Core.Json;
using TokenTracker.Core.Localization;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Presentation;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Scanners;
using TokenTracker.Core.Settings;
using TokenTracker.Core.Store;
using Xunit;

namespace TokenTracker.Core.Tests;

public sealed class VersionTests
{
    [Fact]
    public void AssemblyVersionMatchesSwiftConstant()
    {
        var swift = File.ReadAllText(TestSupport.Repo("swift", "Sources", "TokenTrackerCore", "TokenTrackerCore.swift"));
        var expected = Regex.Match(swift, "public static let version = \"([^\"]+)\"").Groups[1].Value;
        Assert.NotEmpty(expected);
        Assert.Equal(expected, AppInfo.Version);
    }
}

public sealed class PythonJsonTests
{
    [Theory]
    [InlineData("abc", "\"abc\"")]
    [InlineData("a\"b\\c", "\"a\\\"b\\\\c\"")]
    [InlineData("中文", "\"\\u4e2d\\u6587\"")]
    [InlineData("😀", "\"\\ud83d\\ude00\"")]
    [InlineData("\u0001\n\u007f", "\"\\u0001\\n\\u007f\"")]
    public void DumpsStringMatchesCPython(string input, string expected) => Assert.Equal(expected, PythonJson.DumpsString(input));

    [Fact]
    public void DumpsListUsesPythonSeparatorsAndNone() =>
        Assert.Equal("[\"a\", null, 1]", PythonJson.Dumps(new object?[] { "a", null, 1L }));

    [Theory]
    [InlineData(0.1, "0.1")]
    [InlineData(1.0, "1.0")]
    [InlineData(1e16, "1e+16")]
    [InlineData(1.5e-7, "1.5e-07")]
    [InlineData(0.0001, "0.0001")]
    [InlineData(123456.789, "123456.789")]
    [InlineData(-2.5, "-2.5")]
    public void FloatReprMatchesPython(double value, string expected) => Assert.Equal(expected, PyJson.PyFloatRepr(value));

    [Fact]
    public void DuplicateKeysKeepLastLikePython()
    {
        var obj = PyJson.ParseObject("{\"a\":1,\"a\":2}")!;
        Assert.Equal(2L, obj["a"]);
    }

    [Fact]
    public void IntegersStayIntegersAndFloatsStayFloats()
    {
        var obj = PyJson.ParseObject("{\"i\":3,\"f\":3.0,\"e\":1e2,\"b\":true}")!;
        Assert.IsType<long>(obj["i"]);
        Assert.IsType<double>(obj["f"]);
        Assert.IsType<double>(obj["e"]);
        Assert.Null(PyJson.StrictNonNegativeInt(obj["b"]));
        Assert.Equal(1, PyJson.JInt(obj["b"]));
    }
}

public sealed class PriceTableTests
{
    [Fact]
    public void LongestSubstringWinsAndUnknownFallsBack()
    {
        var table = PriceTable.Default;
        Assert.Equal(PythonJson.RoundHalfEven((1_000_000 * 2.0 + 1_000_000 * 12.0) / 1e6, 8),
            table.Cost("openai/GPT-5.6-luna-latest", 1_000_000, 1_000_000));
        Assert.Equal(1.25, table.Cost("gpt-5", 1_000_000, 0));
        Assert.Equal(2.0, table.Cost("totally-unknown", 1_000_000, 0));
        Assert.Null(table.Cost("", 1, 1));
        Assert.Null(new PriceTable(null, []).Cost("x", 1, 1));
    }

    [Fact]
    public void EmbeddedRepoPricesParse() => Assert.NotEmpty(PriceTable.LoadEffective().Models);
}

public sealed class ScannerSupportTests
{
    [Theory]
    [InlineData("2026-08-25T03:00:00Z", 1787626800000L)]
    [InlineData("2026-08-25T03:00:00.123Z", 1787626800123L)]
    [InlineData("2026-08-25T11:00:00+08:00", 1787626800000L)]
    [InlineData("2026-08-25T03:00:00.123456+00:00", 1787626800123L)]
    public void ParsesIsoWithOffset(string input, long expected) => Assert.Equal(expected, ScannerSupport.ParseIsoDateMs(input));

    [Fact]
    public void NaiveIsoIsRejectedLikeSwift() => Assert.Null(ScannerSupport.ParseIsoDateMs("2026-08-25T03:00:00"));

    [Fact]
    public void DeltaReadSeesAppendsWhileWriterKeepsFileOpen()
    {
        using var temp = new TempDir();
        var path = temp.File("中文 session.jsonl");
        using var writer = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        void Append(string text)
        {
            writer.Write(Encoding.UTF8.GetBytes(text));
            writer.Flush();
        }
        Append("{\"a\":1}\r\n");
        var first = FileIdentity.Of(path)!.Value;
        var (items, offset) = ScannerSupport.ReadJsonlDelta(path, 0);
        Assert.Single(items);
        Append("{\"a\":2}\n{\"a\":3");
        var second = FileIdentity.Of(path)!.Value;
        Assert.NotEqual(first, second);
        var cursor = new Dictionary<string, object?> { [path] = first.AsDict() };
        Assert.True(FileIdentity.Changed(cursor, path));
        var (more, offset2) = ScannerSupport.ReadJsonlDelta(path, offset);
        Assert.Single(more); // 未写完的尾行留给下次
        Assert.Equal(2L, more[0].Obj["a"]);
        Append("}\n");
        var (last, _) = ScannerSupport.ReadJsonlDelta(path, offset2);
        Assert.Equal(3L, Assert.Single(last).Obj["a"]);
    }

    [Fact]
    public void LongPathsAreReadable()
    {
        using var temp = new TempDir();
        var dir = temp.Path;
        while (dir.Length < 300) dir = Path.Combine(dir, new string('d', 40));
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "x.jsonl");
        File.WriteAllText(path, "{\"a\":1}\n");
        Assert.NotNull(FileIdentity.Of(path));
        Assert.Single(ScannerSupport.IterJsonl(path));
        Assert.Single(WinPaths.EnumerateFilesRelative(temp.Path, rel => rel.EndsWith(".jsonl", StringComparison.Ordinal)));
    }

    [Fact]
    public void EnumerationSortsLikePosixPaths()
    {
        using var temp = new TempDir();
        Directory.CreateDirectory(temp.File("a-b"));
        Directory.CreateDirectory(temp.File("a"));
        File.WriteAllText(Path.Combine(temp.Path, "a-b", "x.jsonl"), "");
        File.WriteAllText(Path.Combine(temp.Path, "a", "y.jsonl"), "");
        Assert.Equal(["a-b/x.jsonl", "a/y.jsonl"], WinPaths.EnumerateFilesRelative(temp.Path, _ => true));
    }

    [Theory]
    [InlineData(@"C:\Users\me\code", true)]
    [InlineData("/Users/me/code", true)]
    [InlineData("webapp", false)]
    [InlineData(@"C:relative", false)]
    [InlineData("", false)]
    public void AbsoluteProjectPaths(string path, bool expected) => Assert.Equal(expected, WinPaths.IsAbsoluteProjectPath(path));
}

public sealed class StoreTests
{
    [Fact]
    public void FreshDatabaseUsesSharedSchemaVersion()
    {
        using var temp = new TempDir();
        using (var store = temp.Store())
            Assert.Equal(UsageStore.SchemaVersion, store.Conn.ScalarInt("PRAGMA user_version"));
        using var raw = new SqliteDb(temp.File("usage.db"));
        var tables = raw.Query("SELECT name FROM sqlite_master WHERE type='table'").Select(r => r.Str("name")).ToHashSet();
        Assert.Superset(new HashSet<string> { "usage_events", "agent_activity_events", "project_paths", "quota_samples" }, tables);
    }

    [Fact]
    public void NewerDatabaseIsRefused()
    {
        using var temp = new TempDir();
        using (var raw = new SqliteDb(temp.File("usage.db"))) raw.Execute("PRAGMA user_version=99");
        Assert.Throws<SqliteException>(() => temp.Store());
    }

    [Fact]
    public void WindowsProjectPathsAreRecorded()
    {
        using var temp = new TempDir();
        using var store = temp.Store();
        store.Conn.BeginImmediate();
        store.PutEvent("codex", "k1", "s1", temp.Path, 1_787_626_800_000, "gpt-5", 10, 1);
        store.Conn.Commit();
        var path = store.Conn.QueryOne("SELECT path FROM project_sources WHERE src_key='k1'")?.Str("path");
        Assert.Equal(WinPaths.Real(temp.Path), path);
    }

    [Fact]
    public void SnapshotCounterResetKeepsHistory()
    {
        using var temp = new TempDir();
        using var store = temp.Store();
        store.PutSnapshot("opencode", "scope", "id", "id", "p", "m", input: 100, observedAt: 1000);
        store.PutSnapshot("opencode", "scope", "id", "id", "p", "m", input: 150, observedAt: 2000);
        var reset = store.PutSnapshot("opencode", "scope", "id", "id", "p", "m", input: 20, observedAt: 3000);
        store.Conn.Commit();
        Assert.Equal(1, reset.CounterResets);
        Assert.Equal(150, store.Conn.ScalarInt("SELECT SUM(input) FROM usage_events"));
    }
}

public sealed class LocalizationTests
{
    [Fact]
    public void SharedTablesParseWithIdenticalKeys()
    {
        var zh = L10n.Table("zh-Hans");
        var en = L10n.Table("en");
        Assert.True(zh.Count >= 499, $"zh-Hans 只有 {zh.Count} 条");
        Assert.Equal(zh.Keys.OrderBy(k => k, StringComparer.Ordinal), en.Keys.OrderBy(k => k, StringComparer.Ordinal));
    }

    [Fact]
    public void PlaceholdersReplaceInOnePass()
    {
        var parsed = StringsFile.Parse("\"k {0} {1}\" = \"v {1} {0}\";\r\n/* c */ \"q\" = \"a\\\"b\";");
        Assert.Equal("v {1} {0}", parsed["k {0} {1}"]);
        Assert.Equal("a\"b", parsed["q"]);
    }
}

public sealed class TrayFormatterTests
{
    static readonly TrayQuotaEntry Claude = new("claude", "Claude Code",
        [new TrayQuotaWindow(42.4, "local", false, "5 小时"), new TrayQuotaWindow(12, "official", false, "周 (7天)")]);

    [Fact]
    public void TitleShowsTokensGlyphAndEstimateMarker() =>
        Assert.Equal("⚡ 1.23M · C ≈42%", TrayFormatter.Title(new TodayUsage(1_234_567, 1.5), [Claude], "claude"));

    [Fact]
    public void RingTitleOmitsPercentage() =>
        Assert.Equal("1.23M · C≈", TrayFormatter.Title(new TodayUsage(1_234_567, 1.5), [Claude], "claude", ring: true));

    [Fact]
    public void YiUnitsAndOffProvider()
    {
        Assert.Equal("0.01亿", TrayFormatter.FmtTokens(1_000_000, yi: true));
        Assert.Equal("⚡ —", TrayFormatter.Title(null, [Claude], "off"));
    }

    [Fact]
    public void RingSpecUsesTightestWindowUrgency()
    {
        Assert.Equal((42.4, "quota_ok"), TrayFormatter.RingSpec([Claude], "claude"));
        Assert.Equal((null, "quota_none"), TrayFormatter.RingSpec([Claude], "codex"));
    }
}

public sealed class SettingsTests
{
    [Fact]
    public void RejectsUnknownAndInvalidValues()
    {
        using var temp = new TempDir();
        var settings = new SettingsStore(temp.File("settings.json"));
        Assert.False(settings.Set("unknown", true));
        Assert.False(settings.Set("scan_interval", 45L));
        Assert.True(settings.Set("scan_interval", 300L));
        Assert.True(settings.Set("menubar_provider", "codex"));
        Assert.Equal(300, settings.Int("scan_interval"));
        Assert.Equal("codex", settings.String("menubar_provider"));
        File.WriteAllText(settings.Path, "{\"unit_yi\":\"yes\",\"menubar_ring\":false}");
        Assert.False(settings.Bool("unit_yi"));
        Assert.False(settings.Bool("menubar_ring"));
    }
}
