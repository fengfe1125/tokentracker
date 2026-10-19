using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

/// <summary>
/// 移植 ClaudeScanner.swift（scanners/claude.py）：~/.claude/projects/&lt;slug&gt;/*.jsonl。
/// 以 message.id 为幂等键；增量按字节游标，截断/轮转回退全量（行号兜底键）。
/// </summary>
public sealed class ClaudeScanner(string root) : IScanner
{
    const int ParserVersion = 2;

    public string Name => "claude";
    public string Detail => "~/.claude/projects/**/*.jsonl";
    public string Root { get; } = WinPaths.Expand(root);

    public bool Detect() => Directory.Exists(Root);

    (int Added, int Updated, int ActivityAdded, int ActivityUpdated, string? Title) ScanLine(
        Dictionary<string, object?> obj, string fallbackKey, string sessionId, string slug, long mtimeMs,
        PriceTable prices, UsageStore store)
    {
        var title = ScannerSupport.UserText(obj);
        var titleOut = title.Length == 0 ? null : title;
        var msg = obj.GetDict("message") ?? new Dictionary<string, object?>();
        var ts = obj.Get("timestamp") is string tsText && ScannerSupport.ParseIsoDateMs(tsText) is { } parsed
            ? parsed
            : mtimeMs;
        int activityAdded = 0, activityUpdated = 0;
        if (msg.Get("content") is List<object?> content)
        {
            for (var index = 0; index < content.Count; index++)
            {
                if (content[index] is not Dictionary<string, object?> part) continue;
                var type = part.Get("type") as string;
                if (type == "tool_use" && part.Get("name") is string rawName)
                {
                    var callId = part.Get("id") as string ?? "";
                    var key = $"{sessionId}|tool|{(callId.Length == 0 ? $"{fallbackKey}|{index}" : callId)}";
                    var change = store.RecordActivity(Name, key, rawName, sessionId, callId: callId, startedAt: ts,
                        sourceKind: "claude_jsonl", arguments: part.Get("input"));
                    activityAdded += change.Added;
                    activityUpdated += change.Updated;
                }
                else if (type == "tool_result")
                {
                    var status = part.Get("is_error") is true ? "error" : ActivityNormalizer.Status(part.Get("status"));
                    if (status == "unknown") status = "success";
                    activityUpdated += store.CompleteActivity(Name,
                        PyJson.OrString(part.Get("tool_use_id"), part.Get("toolUseId")), status, ts);
                }
            }
        }
        var usage = msg.GetDict("usage") ?? obj.GetDict("usage");
        if (usage is null) return (0, 0, activityAdded, activityUpdated, titleOut);
        var inp = PyJson.JInt(usage.Get("input_tokens"));
        var outp = PyJson.JInt(usage.Get("output_tokens"));
        var cr = PyJson.JInt(usage.Get("cache_read_input_tokens"));
        var cw = PyJson.JInt(usage.Get("cache_creation_input_tokens"));
        if (inp + outp + cr + cw == 0) return (0, 0, activityAdded, activityUpdated, titleOut);
        var model = PyJson.OrString(msg.Get("model"), obj.Get("model"));
        var messageId = msg.Get("id") as string;
        var eventKey = string.IsNullOrEmpty(messageId) ? $"{sessionId}|{fallbackKey}" : messageId;
        var sourceKey = $"{sessionId}|{eventKey}";
        if (obj.Get("cwd") is string cwd) store.RecordProjectPath(Name, sourceKey, cwd);
        var old = store.Conn.QueryOne(
            "SELECT input,output,cache_read,cache_write FROM usage_events WHERE tool=? AND src_key=?", Name, sourceKey);
        if (old is not null)
        {
            // 同一 message.id 会随流式输出出现多条 usage 快照：保留每个计数器的完整值。
            inp = Math.Max(inp, old.Int("input"));
            outp = Math.Max(outp, old.Int("output"));
            cr = Math.Max(cr, old.Int("cache_read"));
            cw = Math.Max(cw, old.Int("cache_write"));
            if (inp == old.Int("input") && outp == old.Int("output") && cr == old.Int("cache_read")
                && cw == old.Int("cache_write"))
                return (0, 0, activityAdded, activityUpdated, titleOut);
        }
        var cost = prices.Cost(model, inp, outp, cr, cw);
        var added = store.PutEvent(Name, sourceKey, sessionId, slug, ts, model, inp, outp, cr, cw, cost,
            replace: old is not null);
        return old is null
            ? (added, 0, activityAdded, activityUpdated, titleOut)
            : (0, 1, activityAdded, activityUpdated, titleOut);
    }

    public ScanOutcome Scan(UsageStore store, PriceTable prices, bool full)
    {
        var cursor = store.GetScanCursor(Name);
        var effectiveFull = full || PyJson.AsLong(cursor.Get("parser_version")) != ParserVersion
                                 || ActivityNormalizer.NeedsBackfill(cursor);
        var outcome = new ScanOutcome();
        if (!Directory.Exists(Root)) return outcome;
        // (相对目录, 文件名)；目录内按文件名排序，对齐 sorted(names)。
        var files = WinPaths.EnumerateFilesRelative(Root, _ => true)
            .Select(rel =>
            {
                var slash = rel.LastIndexOf('/');
                return (Dir: slash < 0 ? "" : rel[..slash], FileName: slash < 0 ? rel : rel[(slash + 1)..]);
            })
            .OrderBy(f => f.Dir, StringComparer.Ordinal).ThenBy(f => f.FileName, StringComparer.Ordinal)
            .ToList();

        foreach (var (relDir, fileName) in files)
        {
            if (relDir.Length == 0) continue; // slug 目录在下一层
            if (!fileName.EndsWith(".jsonl", StringComparison.Ordinal)) continue;
            var dirpath = WinPaths.JoinRelative(Root, relDir);
            var dirBase = WinPaths.LastComponent(dirpath);
            var slug = dirBase == "projects" ? WinPaths.LastComponent(WinPaths.Parent(dirpath)) : dirBase;
            var path = dirpath + "\\" + fileName;
            if (!effectiveFull && !FileIdentity.Changed(cursor, path)) continue;
            if (FileIdentity.Of(path) is not { } statKey) continue;
            outcome.Files++;

            var sessionId = fileName[..^".jsonl".Length];
            string? title = null;
            var mtimeMs = statKey.M / 1_000_000;
            var prevOffset = effectiveFull ? 0 : PyJson.AsLong(cursor.GetDict(path).Get("o")) ?? 0;
            long newOffset = 0;
            List<(long Offset, Dictionary<string, object?> Obj)>? delta = null;
            if (prevOffset > 0)
            {
                var (items, offset) = ScannerSupport.ReadJsonlDelta(path, prevOffset);
                if (offset >= 0)
                {
                    delta = items;
                    newOffset = offset;
                }
            }
            void Accumulate((int A, int U, int AA, int AU, string? T) r)
            {
                outcome.Added += r.A;
                outcome.Updated += r.U;
                outcome.ActivityAdded += r.AA;
                outcome.ActivityUpdated += r.AU;
                if (r.T is not null && title is null) title = r.T;
            }
            if (delta is null)
            {
                // 全量解析：行号兜底键，与历史数据幂等
                foreach (var (lineNo, obj) in ScannerSupport.IterJsonl(path))
                    Accumulate(ScanLine(obj, lineNo.ToString(), sessionId, slug, mtimeMs, prices, store));
                newOffset = statKey.S;
            }
            else
            {
                // 增量解析：字节偏移兜底键（仅追加文件中稳定）
                foreach (var (lineOffset, obj) in delta)
                    Accumulate(ScanLine(obj, $"b{lineOffset}", sessionId, slug, mtimeMs, prices, store));
            }
            var snapshot = statKey.AsDict();
            snapshot["o"] = newOffset;
            cursor[path] = snapshot;
            if (title is not null) store.SetSessionTitle(Name, sessionId, title);
        }
        cursor["parser_version"] = (long)ParserVersion;
        ActivityNormalizer.MarkCurrent(cursor);
        store.SetScanCursor(Name, cursor);
        return outcome;
    }
}
