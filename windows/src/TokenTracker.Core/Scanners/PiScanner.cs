using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

/// <summary>
/// 移植 PiScanner.swift（scanners/pi.py）：~/.pi/agent/sessions/**/*.jsonl（Oh My Pi: ~/.omp）。
/// 幂等键：文件内事件 id；官方 cost 优先，缺失时价格表估算。
/// </summary>
public sealed class PiScanner : IScanner
{
    public string Name => "pi";
    public string Detail => "~/.pi/agent/sessions/**/*.jsonl";
    public IReadOnlyList<string> Roots { get; }

    public PiScanner(IEnumerable<string> roots) =>
        Roots = roots.Select(WinPaths.Expand).Where(Directory.Exists).ToList();

    public bool Detect() => Roots.Count > 0;

    public ScanOutcome Scan(UsageStore store, PriceTable prices, bool full)
    {
        var cursor = store.GetScanCursor(Name);
        var effectiveFull = full || ActivityNormalizer.NeedsBackfill(cursor);
        var outcome = new ScanOutcome();
        foreach (var root in Roots)
        {
            var files = WinPaths.EnumerateFilesRelative(root, rel => rel.EndsWith(".jsonl", StringComparison.Ordinal))
                .Select(rel => WinPaths.JoinRelative(root, rel));
            foreach (var path in files)
            {
                if (!effectiveFull && !FileIdentity.Changed(cursor, path)) continue;
                if (FileIdentity.Of(path) is not { } statKey) continue;
                outcome.Files++;
                var sessionId = "";
                var project = WinPaths.LastComponent(WinPaths.Parent(path));
                string? title = null;
                string? realPath = null;
                foreach (var (_, obj) in ScannerSupport.IterJsonl(path))
                {
                    if (title is null)
                    {
                        var text = ScannerSupport.UserText(obj);
                        if (text.Length > 0) title = text;
                    }
                    var type = obj.Get("type") as string;
                    if (type == "session")
                    {
                        sessionId = obj.Get("id") as string ?? "";
                        if (obj.Get("cwd") is string { Length: > 0 } cwd) project = cwd;
                        continue;
                    }
                    if (type != "message" || obj.Get("message") is not Dictionary<string, object?> msg) continue;
                    var ts = ScannerSupport.ParseTs(PyJson.Or(msg.Get("timestamp"), obj.Get("timestamp")));
                    if (msg.Get("content") is List<object?> content)
                    {
                        for (var index = 0; index < content.Count; index++)
                        {
                            if (content[index] is not Dictionary<string, object?> part
                                || part.Get("type") is not string partType) continue;
                            if (partType == "toolCall" && part.Get("name") is string rawName)
                            {
                                var callId = PyJson.OrString(part.Get("id"), part.Get("toolCallId"));
                                // Python: call_id or str(obj.get('id')) + '|' + str(index)
                                var fallback = $"{PyJson.PyStr(obj.Get("id"))}|{index}";
                                realPath ??= WinPaths.Real(path);
                                var change = store.RecordActivity(Name,
                                    $"{realPath}|tool|{(callId.Length == 0 ? fallback : callId)}", rawName, sessionId,
                                    callId: callId, startedAt: ts == 0 ? null : ts, sourceKind: "pi_jsonl",
                                    arguments: PyJson.Or(part.Get("arguments"), part.Get("input")));
                                outcome.ActivityAdded += change.Added;
                                outcome.ActivityUpdated += change.Updated;
                            }
                            else if (partType == "toolResult")
                            {
                                var status = part.Get("isError") is true ? "error" : ActivityNormalizer.Status(part.Get("status"));
                                if (status == "unknown") status = "success";
                                outcome.ActivityUpdated += store.CompleteActivity(Name,
                                    PyJson.OrString(part.Get("toolCallId"), part.Get("id")), status, ts == 0 ? null : ts);
                            }
                        }
                    }
                    if (msg.GetDict("usage") is not { } usage) continue;
                    var inp = PyJson.JInt(usage.Get("input"));
                    var outp = PyJson.JInt(usage.Get("output"));
                    var cr = PyJson.JInt(usage.Get("cacheRead"));
                    var cw = PyJson.JInt(usage.Get("cacheWrite"));
                    if (inp + outp + cr + cw == 0) continue;
                    var model = PyJson.OrString(msg.Get("model"), obj.Get("modelId"));
                    var eventId = obj.Get("id") switch
                    {
                        string s => s,
                        long or double => PyJson.PyStr(obj["id"]),
                        _ => "None",
                    };
                    var key = $"{WinPaths.LastComponent(path)}|{eventId}";
                    // 官方 cost 优先；<=0 时价格表估算（未匹配保持 null，不计费）
                    double? cost = PyJson.AsDouble(usage.GetDict("cost").Get("total")) ?? 0;
                    if (cost <= 0) cost = prices.Cost(model, inp, outp, cr, cw);
                    outcome.Added += store.PutEvent(Name, key, sessionId, project, ts, model, inp, outp, cr, cw, cost);
                }
                cursor[path] = statKey.AsDict();
                if (title is not null) store.SetSessionTitle(Name, sessionId, title);
            }
        }
        ActivityNormalizer.MarkCurrent(cursor);
        store.SetScanCursor(Name, cursor);
        return outcome;
    }
}
