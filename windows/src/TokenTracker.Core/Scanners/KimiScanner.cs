using TokenTracker.Core.Activity;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Pricing;
using TokenTracker.Core.Store;

namespace TokenTracker.Core.Scanners;

/// <summary>
/// 移植 KimiScanner.swift（scanners/kimi.py）：~/.kimi-code/server/events/session_*.jsonl（事件日志）
/// + kimi-cli ~/.kimi/sessions/（通用 JSONL 兜底）。turn.step.completed 的 usage 是每步增量，直接累加。
/// </summary>
public sealed class KimiScanner(string journalDir, string cliDir) : IScanner
{
    public string Name => "kimi";
    public string Detail => "~/.kimi-code/server/events/session_*.jsonl";
    public string JournalDir { get; } = WinPaths.Expand(journalDir);
    public string CliDir { get; } = WinPaths.Expand(cliDir);

    public bool Detect() => Directory.Exists(JournalDir) || Directory.Exists(CliDir);

    /// <summary>只取公开的 Skill 标识；事件参数/内容绝不入库。</summary>
    static string SkillName(Dictionary<string, object?> payload)
    {
        var value = payload.Get("skill");
        if (value is Dictionary<string, object?> skill)
            value = skill.Get("name") ?? skill.Get("skillName") ?? skill.Get("id");
        return PyJson.Identifier(payload.Get("skillName"), payload.Get("name"), value, payload.Get("skill_name"));
    }

    static List<string> JsonlFiles(string root, Func<string, bool> predicate) =>
        WinPaths.EnumerateFilesRelative(root, predicate).Select(rel => WinPaths.JoinRelative(root, rel)).ToList();

    ScanOutcome ScanJournal(UsageStore store, PriceTable prices, Dictionary<string, object?> cursor, bool full)
    {
        var outcome = new ScanOutcome();
        if (!Directory.Exists(JournalDir)) return outcome;
        var files = JsonlFiles(JournalDir, rel =>
        {
            var name = WinPaths.LastComponent(rel);
            return name.StartsWith("session_", StringComparison.Ordinal) && rel.EndsWith(".jsonl", StringComparison.Ordinal);
        });
        foreach (var path in files)
        {
            if (!full && !FileIdentity.Changed(cursor, path)) continue;
            if (FileIdentity.Of(path) is not { } statKey) continue;
            outcome.Files++;
            var filename = WinPaths.LastComponent(path);
            var sessionId = filename["session_".Length..^".jsonl".Length];
            var project = "";
            var modelHint = "";
            string? title = null;
            foreach (var (_, obj) in ScannerSupport.IterJsonl(path))
            {
                var kind = obj.Get("kind") as string;
                var envelope = obj.GetDict("envelope") ?? new Dictionary<string, object?>();
                var payload = envelope.GetDict("payload") ?? new Dictionary<string, object?>();
                var eventType = envelope.Get("type") as string ?? "";
                var activityTs = ScannerSupport.ParseTs(PyJson.Or(envelope.Get("timestamp"), obj.Get("time")));
                long? startedAt = activityTs == 0 ? null : activityTs;
                var turnId = payload.Get("turnId") as string ?? "";
                if (kind == "event" && eventType == "skill.activated")
                {
                    var name = SkillName(payload);
                    if (name.Trim().Length > 0)
                    {
                        var callId = PyJson.Identifier(payload.Get("id"), payload.Get("skillCallId"), obj.Get("seq"));
                        var change = store.RecordActivity(Name, $"{sessionId}|skill|{callId}", "Skill", sessionId,
                            turnId, callId, startedAt: startedAt, sourceKind: "kimi_skill_activated",
                            confidence: "exact", arguments: new Dictionary<string, object?> { ["skill"] = name },
                            eventKind: ActivityKind.Skill);
                        outcome.ActivityAdded += change.Added;
                        outcome.ActivityUpdated += change.Updated;
                    }
                }
                else if (kind == "event" && eventType.StartsWith("subagent.", StringComparison.Ordinal))
                {
                    var callId = PyJson.Identifier(payload.Get("id"), payload.Get("agentId"), obj.Get("seq"));
                    var parent = PyJson.OrString(payload.Get("parentId"), payload.Get("parentAgentId"));
                    var change = store.RecordActivity(Name, $"{sessionId}|agent|{callId}",
                        PyJson.OrString(payload.Get("name"), eventType), sessionId, turnId, callId, parent,
                        startedAt: startedAt, sourceKind: "kimi_subagent", eventKind: ActivityKind.Agent,
                        eventLayer: ActivityLayer.Lifecycle);
                    outcome.ActivityAdded += change.Added;
                    outcome.ActivityUpdated += change.Updated;
                }
                else if (kind == "event" && eventType == "tool.call.started")
                {
                    var call = payload.GetDict("toolCall") ?? payload;
                    var rawName = PyJson.OrString(call.Get("name"), call.Get("toolName"), call.Get("tool"));
                    var callId = PyJson.OrString(call.Get("id"), call.Get("toolCallId"), payload.Get("toolCallId"));
                    if (rawName.Length > 0)
                    {
                        var change = store.RecordActivity(Name,
                            $"{sessionId}|tool|{(callId.Length == 0 ? PyJson.PyStr(obj.Get("seq")) : callId)}",
                            rawName, sessionId, turnId, callId, startedAt: startedAt, sourceKind: "kimi_journal",
                            arguments: PyJson.Or(call.Get("args"), call.Get("arguments"), call.Get("input")));
                        outcome.ActivityAdded += change.Added;
                        outcome.ActivityUpdated += change.Updated;
                    }
                }
                else if (kind == "event" && eventType == "tool.result")
                {
                    var callId = PyJson.OrString(payload.Get("toolCallId"), payload.Get("callId"), payload.Get("id"));
                    var status = ActivityNormalizer.Status(PyJson.Or(payload.Get("status"), payload.Get("error")));
                    if (status == "unknown") status = payload.Get("error") is null ? "success" : "error";
                    outcome.ActivityUpdated += store.CompleteActivity(Name, callId, status, startedAt,
                        PyJson.AsLong(payload.Get("durationMs")));
                }
                if (title is null && kind == "event" && eventType == "turn.started"
                    && payload.Get("prompt") is string prompt && prompt.Trim().Length > 0)
                    title = TextUtil.CleanSessionTitle(prompt);
                if (kind == "event" && eventType == "event.session.created")
                {
                    var meta = payload.GetDict("session").GetDict("metadata");
                    if (meta.Get("cwd") is string { Length: > 0 } cwd) project = cwd;
                    continue;
                }
                if (kind != "event" || eventType != "turn.step.completed" || payload.GetDict("usage") is not { } usage)
                    continue;
                var inp = PyJson.JInt(usage.Get("inputOther")); // 非缓存输入增量
                var outp = PyJson.JInt(usage.Get("output"));
                var cr = PyJson.JInt(usage.Get("inputCacheRead"));
                var cw = PyJson.JInt(usage.Get("inputCacheCreation"));
                if (inp + outp + cr + cw == 0) continue;
                var m = payload.Get("model");
                if (m is Dictionary<string, object?> md) m = md.Get("id");
                if (m is string { Length: > 0 } mStr) modelHint = mStr;
                // 事件日志不携带模型字段，默认 kimi-code（k3 家族）
                var model = modelHint.Length == 0 ? "kimi-code" : modelHint;
                var key = $"{sessionId}|step|{PyJson.PyStr(obj.Get("seq"))}";
                var cost = prices.Cost(model, inp, outp, cr, cw);
                outcome.Added += store.PutEvent(Name, key, sessionId, project, activityTs, model, inp, outp, cr, cw, cost);
            }
            cursor[path] = statKey.AsDict();
            if (title is not null) store.SetSessionTitle(Name, sessionId, title);
        }
        return outcome;
    }

    ScanOutcome ScanCli(UsageStore store, PriceTable prices, Dictionary<string, object?> cursor, bool full)
    {
        var outcome = new ScanOutcome();
        if (!Directory.Exists(CliDir)) return outcome;
        foreach (var path in JsonlFiles(CliDir, rel => rel.EndsWith(".jsonl", StringComparison.Ordinal)))
        {
            if (!full && !FileIdentity.Changed(cursor, path)) continue;
            if (FileIdentity.Of(path) is not { } statKey) continue;
            outcome.Files++;
            var filename = WinPaths.LastComponent(path);
            foreach (var (lineNo, obj) in ScannerSupport.IterJsonl(path))
            {
                if (obj.GetDict("usage") is not { } usage) continue;
                var inp = PyJson.OrInt(usage.Get("input"), usage.Get("input_tokens"));
                var outp = PyJson.OrInt(usage.Get("output"), usage.Get("output_tokens"));
                if (inp + outp == 0) continue;
                var model = obj.Get("model") as string ?? "";
                var cost = prices.Cost(model, inp, outp);
                outcome.Added += store.PutEvent(Name, $"cli|{path}|{lineNo}", filename[..^".jsonl".Length],
                    WinPaths.Parent(path), ScannerSupport.ParseTs(obj.Get("timestamp")), model, inp, outp, cost: cost);
            }
            cursor[path] = statKey.AsDict();
        }
        return outcome;
    }

    public ScanOutcome Scan(UsageStore store, PriceTable prices, bool full)
    {
        var cursor = store.GetScanCursor(Name);
        var effectiveFull = full || ActivityNormalizer.NeedsBackfill(cursor);
        var journal = ScanJournal(store, prices, cursor, effectiveFull);
        var cli = ScanCli(store, prices, cursor, effectiveFull);
        ActivityNormalizer.MarkCurrent(cursor);
        store.SetScanCursor(Name, cursor);
        return new ScanOutcome
        {
            Added = journal.Added + cli.Added,
            Updated = journal.Updated + cli.Updated,
            Files = journal.Files + cli.Files,
            ActivityAdded = journal.ActivityAdded + cli.ActivityAdded,
            ActivityUpdated = journal.ActivityUpdated + cli.ActivityUpdated,
        };
    }
}
