using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

/// <summary>
/// 移植 DshScanner.swift（scanners/dsh.py）：~/.dsh/sessions/**/session.jsonl.zstd。
/// 幂等键：会话内 (turn, step)。同名文件分布在不同目录，保留完整相对路径（'/' 分隔）作为兜底身份。
/// </summary>
public sealed class DshScanner(string root) : IScanner
{
    public string Name => "dsh";
    public string Detail => "~/.dsh/sessions/**/session.jsonl.zstd";
    public string Root { get; } = WinPaths.Expand(root);

    /// <summary>测试可注入解压器（对齐 Python patch iter_zstd_jsonl）。</summary>
    public Func<string, List<(int Line, Dictionary<string, object?> Obj)>> Reader { get; init; } =
        ScannerSupport.IterZstdJsonl;

    public bool Detect() => Directory.Exists(Root);

    /// <summary>仅当旧文件名兜底键的载荷已被完全入账时才删除旧行。</summary>
    int ReplaceOldFallback(UsageStore store, string oldKey, string project, long ts, string model,
        (long Inp, long Outp, long Cr, long Cw) counts)
    {
        var old = store.Conn.QueryOne("SELECT * FROM usage_events WHERE tool=? AND src_key=?", Name, oldKey);
        if (old is null || old.Str("project") != project || old.Int("ts") != ts || old.Str("model") != model
            || old.Int("input") != counts.Inp || old.Int("output") != counts.Outp
            || old.Int("cache_read") != counts.Cr || old.Int("cache_write") != counts.Cw) return 0;
        store.Conn.Execute("DELETE FROM usage_events WHERE tool=? AND src_key=?", Name, oldKey);
        return 1;
    }

    public ScanOutcome Scan(UsageStore store, PriceTable prices, bool full)
    {
        var cursor = store.GetScanCursor(Name);
        var effectiveFull = full || ActivityNormalizer.NeedsBackfill(cursor);
        var outcome = new ScanOutcome();
        var files = WinPaths.EnumerateFilesRelative(Root, rel => rel.EndsWith(".jsonl.zstd", StringComparison.Ordinal));
        foreach (var rel in files)
        {
            var path = WinPaths.JoinRelative(Root, rel);
            if (!effectiveFull && !FileIdentity.Changed(cursor, path)) continue;
            if (FileIdentity.Of(path) is not { } statKey) continue;
            outcome.Files++;
            // 一级子目录是 workspace slug，二级是 session id（rel 已统一为 '/' 分隔）
            var slash = rel.LastIndexOf('/');
            var parts = (slash < 0 ? "" : rel[..slash]).Split('/', StringSplitOptions.RemoveEmptyEntries);
            var fallbackId = rel;
            var oldFallback = WinPaths.LastComponent(rel).Replace(".jsonl.zstd", "");
            var sessionId = "";
            var project = parts.Length >= 1 ? parts[0] : "";
            var model = "";
            foreach (var (lineNo, obj) in Reader(path))
            {
                var type = obj.Get("type") as string ?? "";
                var data = obj.GetDict("data") ?? new Dictionary<string, object?>();
                switch (type)
                {
                    case "session":
                    {
                        var id = obj.Get("id") as string ?? "";
                        sessionId = id.Length > 0 ? id : parts.Length >= 2 ? parts[1] : "";
                        if (obj.Get("cwd") is string { Length: > 0 } cwd) project = cwd;
                        break;
                    }
                    case "request/header":
                    {
                        if (data.GetDict("header").GetDict("config").Get("model") is string { Length: > 0 } m) model = m;
                        break;
                    }
                    case "tool/call":
                    {
                        var rawName = PyJson.OrString(data.Get("name"), data.Get("tool"));
                        var callId = PyJson.OrString(data.Get("callId"), data.Get("id"));
                        var sid = sessionId.Length == 0 ? fallbackId : sessionId;
                        if (rawName.Length == 0) break;
                        var turn = data.Get("turn");
                        var turnId = PyJson.Truthy(turn) ? PyJson.PyStr(turn) : "";
                        var started = PyJson.OrInt(obj.Get("time"), data.Get("time"));
                        var change = store.RecordActivity(Name,
                            $"{sid}|tool|{(callId.Length == 0 ? lineNo.ToString() : callId)}", rawName, sid, turnId,
                            callId, startedAt: started == 0 ? null : started, sourceKind: "dsh_zstd",
                            arguments: PyJson.Or(data.Get("arguments"), data.Get("args"), data.Get("input")));
                        outcome.ActivityAdded += change.Added;
                        outcome.ActivityUpdated += change.Updated;
                        break;
                    }
                    case "tool/result":
                    {
                        var callId = PyJson.OrString(data.Get("callId"), data.Get("id"));
                        var status = ActivityNormalizer.Status(PyJson.Or(data.Get("status"), data.Get("error")));
                        if (status == "unknown") status = data.Get("error") is null ? "success" : "error";
                        var ended = PyJson.OrInt(obj.Get("time"), data.Get("time"));
                        outcome.ActivityUpdated += store.CompleteActivity(Name, callId, status,
                            ended == 0 ? null : ended, PyJson.AsLong(data.Get("durationMs")));
                        break;
                    }
                    case "assistant/chunk":
                    {
                        var chunk = data.GetDict("chunk");
                        if (chunk.Get("type") as string != "usage" || chunk.GetDict("usage") is not { } usage) break;
                        var inp = PyJson.JInt(usage.Get("inputTokens"));
                        var outp = PyJson.JInt(usage.Get("outputTokens"));
                        var cr = PyJson.OrInt(usage.Get("cacheReadTokens"), usage.Get("cacheRead"));
                        var cw = PyJson.OrInt(usage.Get("cacheWriteTokens"), usage.Get("cacheWrite"));
                        if (inp + outp + cr + cw == 0) break;
                        var ts = PyJson.JInt(obj.Get("time"));
                        var sid = sessionId.Length == 0 ? fallbackId : sessionId;
                        var turn = PyJson.PyStr(data.Get("turn"));
                        var step = PyJson.PyStr(data.Get("step"));
                        var cost = prices.Cost(model, inp, outp, cr, cw);
                        outcome.Added += store.PutEvent(Name, $"{sid}|{turn}|{step}", sid, project, ts, model, inp, outp,
                            cr, cw, cost);
                        if (sessionId.Length == 0)
                            outcome.Updated += ReplaceOldFallback(store, $"{oldFallback}|{turn}|{step}", project, ts, model,
                                (inp, outp, cr, cw));
                        break;
                    }
                    case "usage":
                    {
                        // 顶层 usage 事件（兜底）
                        var usage = data.GetDict("usage") ?? data;
                        var inp = PyJson.OrInt(usage.Get("inputTokens"), usage.Get("input"));
                        var outp = PyJson.OrInt(usage.Get("outputTokens"), usage.Get("output"));
                        if (inp + outp == 0) break;
                        var ts = PyJson.JInt(obj.Get("time"));
                        var sid = sessionId.Length == 0 ? fallbackId : sessionId;
                        var seq = PyJson.PyStr(obj.Get("seq"));
                        var cost = prices.Cost(model, inp, outp);
                        outcome.Added += store.PutEvent(Name, $"{sid}|top|{seq}", sid, project, ts, model, inp, outp,
                            cost: cost);
                        if (sessionId.Length == 0)
                            outcome.Updated += ReplaceOldFallback(store, $"{oldFallback}|top|{seq}", project, ts, model,
                                (inp, outp, 0, 0));
                        break;
                    }
                }
            }
            cursor[path] = statKey.AsDict();
        }
        ActivityNormalizer.MarkCurrent(cursor);
        store.SetScanCursor(Name, cursor);
        return outcome;
    }
}
