using TokenTracker.Core.Activity;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Scanners;

namespace TokenTracker.Core.Store;

public sealed record QuotaSample(string Identity, long At, double Pct, long ResetsAt);

public sealed record ScanHealth(string Tool, string State, long AttemptedAt, long? SucceededAt, double Duration,
    int Files, int Added, int Updated, string Error, int ParserVersion, int? ParseErrors, int? ReadErrors);

/// <summary>移植 Insights/InsightsStore.swift 与 InsightRules.swift 中 MVP 需要的部分。</summary>
public sealed partial class UsageStore
{
    /// <summary>扫描时每行都可能登记同一 cwd：缓存 Real() 结果，避免逐行开句柄。</summary>
    readonly Dictionary<string, string> _realPathCache = new(StringComparer.Ordinal);

    /// <summary>
    /// 登记项目路径（扫描时）。Windows 全限定路径存 Real() 之后的值；POSIX 形式的外来路径原样保留。
    /// </summary>
    public void RecordProjectPath(string tool, string srcKey, string path)
    {
        if (!WinPaths.IsAbsoluteProjectPath(path)) return;
        var posix = path.StartsWith('/');
        string normalized;
        if (posix) normalized = path;
        else if (!_realPathCache.TryGetValue(path, out normalized!))
            _realPathCache[path] = normalized = WinPaths.Real(path);
        Conn.Execute("INSERT OR REPLACE INTO project_sources(tool,src_key,path) VALUES (?,?,?)", tool, srcKey, normalized);
        if (Conn.QueryOne("SELECT path FROM project_paths WHERE path=?", normalized) is not null) return;
        var common = posix ? null : ProjectResolver.GitCommonDirectory(normalized);
        var id = common is not null ? "git:" + common : "directory:" + normalized;
        var name = common is not null ? WinPaths.LastComponent(WinPaths.Parent(common)) : WinPaths.LastComponent(normalized);
        Conn.Execute("INSERT OR IGNORE INTO projects(id,name) VALUES (?,?)", id, name);
        Conn.Execute("INSERT OR IGNORE INTO project_paths(path,automatic_id) VALUES (?,?)", normalized, id);
    }

    public void RecordHealth(string tool, ScanOutcome outcome, long started, long finished)
    {
        var diagnostics = ScanDiagnostics.Current;
        var issues = (diagnostics?.ParseErrors ?? 0) + (diagnostics?.ReadErrors ?? 0);
        var state = outcome.Skipped is not null ? "未发现"
            : outcome.Error is not null ? "失败"
            : outcome.Warning is not null || issues > 0 ? "部分异常" : "正常";
        long? success = outcome.Skipped is null && outcome.Error is null ? finished : null;
        Conn.Execute("""
            INSERT INTO scan_health VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(tool) DO UPDATE SET
            state=excluded.state,attempted_at=excluded.attempted_at,succeeded_at=COALESCE(excluded.succeeded_at,scan_health.succeeded_at),duration=excluded.duration,files=excluded.files,added=excluded.added,updated=excluded.updated,error=excluded.error,parser_version=excluded.parser_version
            """, tool, state, started, success, (finished - started) / 1000.0, outcome.Files, outcome.Added,
            outcome.Updated,
            outcome.Error is not null ? "读取或解析失败；请重新扫描" : outcome.Warning is not null ? "来源存在警告" : "",
            ActivityNormalizer.ParserVersion);
        Conn.Execute("INSERT OR REPLACE INTO scan_diagnostics VALUES (?,?,?)", tool, diagnostics?.ParseErrors,
            diagnostics?.ReadErrors);
        Conn.Execute("INSERT INTO scan_health_history(tool,at,state) VALUES (?,?,?)", tool, finished, state);
        Conn.Execute("DELETE FROM scan_health_history WHERE at<?", finished - 30L * 86400000);
        Conn.Commit();
    }

    public List<ScanHealth> Health(long now, int interval = 60) =>
        Conn.Query("SELECT h.*,d.parse_errors,d.read_errors FROM scan_health h LEFT JOIN scan_diagnostics d ON d.tool=h.tool ORDER BY h.tool")
            .Select(r =>
            {
                var success = r.IntOrNull("succeeded_at");
                var stale = r.Str("state") == "正常" && now - (success ?? 0) > Math.Max(interval * 3, 300) * 1000L;
                return new ScanHealth(r.Str("tool"), stale ? "过期" : r.Str("state"), r.Int("attempted_at"), success,
                    r.Double("duration"), (int)r.Int("files"), (int)r.Int("added"), (int)r.Int("updated"),
                    r.Str("error"), (int)r.Int("parser_version"), (int?)r.IntOrNull("parse_errors"),
                    (int?)r.IntOrNull("read_errors"));
            }).ToList();

    /// <summary>官方配额采样（供风险预测；周期变化或百分比下降时清空旧样本）。</summary>
    public void RecordQuota(QuotaSample sample)
    {
        if (!double.IsFinite(sample.Pct) || sample.Pct < 0 || sample.Pct > 100
            || !(sample.ResetsAt == 0 || sample.ResetsAt > sample.At)) return;
        var last = Conn.QueryOne("SELECT * FROM quota_samples WHERE identity=? ORDER BY at DESC LIMIT 1", sample.Identity);
        if (last is not null && (last.Int("resets_at") != sample.ResetsAt || sample.Pct < last.Double("pct")))
            Conn.Execute("DELETE FROM quota_samples WHERE identity=?", sample.Identity);
        Conn.Execute("INSERT OR IGNORE INTO quota_samples VALUES (?,?,?,?)", sample.Identity, sample.At, sample.Pct,
            sample.ResetsAt);
        Conn.Execute("DELETE FROM quota_samples WHERE at<?", sample.At - 14L * 86400000);
        Conn.Commit();
    }
}

public static class ProjectResolver
{
    /// <summary>git 仓库公共目录（worktree 归并同一项目）；超时 2s、不弹窗。</summary>
    public static string? GitCommonDirectory(string path)
    {
        var git = CliFind.Resolve("git");
        if (git is null || !Directory.Exists(path)) return null;
        try
        {
            var result = ProcessRunner.Run(git,
                ["--no-optional-locks", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                TimeSpan.FromSeconds(2));
            if (result.TimedOut || result.ExitCode != 0) return null;
            var value = result.Stdout.Trim();
            if (!Path.IsPathFullyQualified(value)) return null;
            return WinPaths.Real(value);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            return null;
        }
    }
}
