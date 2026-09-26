using System.Reflection;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Tests;

static class TestSupport
{
    public static string RepoRoot { get; } =
        typeof(TestSupport).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .First(a => a.Key == "RepoRoot").Value!;

    public static string Repo(params string[] parts) => Path.Combine([RepoRoot, .. parts]);
}

/// <summary>临时目录（测试结束删除；SQLite 句柄可能稍后才释放，删除带重试）。</summary>
sealed class TempDir : IDisposable
{
    public string Path { get; } =
        System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tt_test_" + Guid.NewGuid().ToString("N"));

    public TempDir() => Directory.CreateDirectory(Path);

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public UsageStore Store(long nowMs = 1_787_626_800_000) => new(File("usage.db")) { NowMs = () => nowMs };

    public void Dispose()
    {
        for (var i = 0; i < 10; i++)
        {
            try
            {
                if (Directory.Exists(Path)) Directory.Delete(Path, true);
                return;
            }
            catch (IOException)
            {
                Thread.Sleep(100);
            }
            catch (UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }
    }
}
