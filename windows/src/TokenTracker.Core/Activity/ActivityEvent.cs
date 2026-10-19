using System.Text.RegularExpressions;
using TokenTracker.Core.Json;

namespace TokenTracker.Core.Activity;

public static class ActivityKind
{
    public const string Tool = "tool";
    public const string Skill = "skill";
    public const string Agent = "agent";
}

public static class ActivityLayer
{
    public const string Execution = "execution";
    public const string RequestFallback = "request_fallback";
    public const string Lifecycle = "lifecycle";
}

/// <summary>Agent 活动元数据（只存工具名/会话/时间/状态/证据等级，不存参数与输出正文）。</summary>
public sealed record ActivityEvent
{
    public required string Agent { get; init; }
    public string SessionId { get; init; } = "";
    public string TurnId { get; init; } = "";
    public required string RawName { get; init; }
    public required string CanonicalName { get; init; }
    public string Namespace { get; init; } = "built-in";
    public string CallId { get; init; } = "";
    public string ParentCallId { get; init; } = "";
    public long? StartedAt { get; init; }
    public long? EndedAt { get; init; }
    public long? DurationMs { get; init; }
    public string Status { get; init; } = "unknown";
    public string SourceKind { get; init; } = "";
    public string Confidence { get; init; } = "exact";
    public string SkillName { get; init; } = "";
    public string SkillConfidence { get; init; } = "";
    public required string SrcKey { get; init; }
    public string EventKind { get; init; } = ActivityKind.Tool;
    public string EventLayer { get; init; } = ActivityLayer.Execution;
}

/// <summary>移植 Activity/ActivityEvent.swift 的 ActivityNormalizer。</summary>
public static class ActivityNormalizer
{
    public const int ParserVersion = 2;

    static readonly Dictionary<string, string> CanonicalNames = new()
    {
        ["bash"] = "shell", ["shell"] = "shell", ["execute_command"] = "shell", ["exec_command"] = "shell",
        ["read"] = "file.read", ["read_file"] = "file.read", ["write"] = "file.write",
        ["write_file"] = "file.write", ["edit"] = "file.edit", ["apply_patch"] = "file.edit",
        ["glob"] = "file.search", ["grep"] = "file.search", ["search"] = "web.search",
        ["web_search"] = "web.search", ["skill"] = "skill.activate", ["skill_view"] = "skill.activate",
    };

    static readonly Regex SkillPathRegex = new(@"(?:^|[/\\])([^/\\]+)[/\\]SKILL\.md(?:$|[\s'""])",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    static readonly Regex CodexToolsRegex = new(@"(?:await\s+)?tools\.([A-Za-z_$][\w$]*)\s*\(",
        RegexOptions.CultureInvariant);

    public static string EventKindFor(string rawName) =>
        rawName.Trim().ToLowerInvariant() is "skill" or "skill_view" ? ActivityKind.Skill : ActivityKind.Tool;

    public static string CanonicalToolName(string raw)
    {
        var low = raw.Trim().ToLowerInvariant();
        if (CanonicalNames.TryGetValue(low, out var value)) return value;
        if (low.StartsWith("mcp__", StringComparison.Ordinal)) return "mcp." + low[5..].Replace("__", ".");
        return low.Replace(" ", "_");
    }

    public static string NamespaceOf(string raw)
    {
        var low = raw.ToLowerInvariant();
        if (!low.StartsWith("mcp__", StringComparison.Ordinal)) return "built-in";
        var first = low[5..].Split('_', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return first ?? "mcp";
    }

    public static string Status(object? value)
    {
        var low = (value is null ? "" : PyJson.PyStr(value)).ToLowerInvariant();
        if (new[] { "denied", "rejected", "blocked" }.Any(low.Contains)) return "denied";
        if (new[] { "error", "failed", "failure" }.Any(low.Contains)) return "error";
        if (new[] { "success", "completed", "complete", "done", "ok" }.Any(low.Contains)) return "success";
        return "unknown";
    }

    public static (string Name, string Confidence) Skill(string rawName, object? arguments, bool allowPath = false)
    {
        var obj = arguments;
        if (arguments is string text0 && PyJson.TryParse(text0, out var parsed)) obj = parsed;
        if (rawName.ToLowerInvariant() is "skill" or "skill_view" && obj is Dictionary<string, object?> dict)
        {
            foreach (var key in new[] { "skill", "name", "skill_name" })
                if (dict.Get(key) is string { Length: > 0 } value) return (value, "exact");
        }
        if (!allowPath) return ("", "");
        var text = arguments switch
        {
            string s => s,
            Dictionary<string, object?> or List<object?> => PyJson.Serialize(arguments),
            _ => "",
        };
        var match = SkillPathRegex.Match(text);
        return match.Success ? (match.Groups[1].Value, "derived") : ("", "");
    }

    public static List<string> InferredCodexTools(string script)
    {
        var blocked = new HashSet<string> { "map", "filter", "reduce", "foreach", "find", "some", "every", "sort" };
        return CodexToolsRegex.Matches(script).Select(m => m.Groups[1].Value)
            .Where(n => !blocked.Contains(n.ToLowerInvariant())).ToList();
    }

    public static readonly Dictionary<string, Dictionary<string, string>> Capabilities = new()
    {
        ["claude"] = new() { ["tools"] = "exact", ["skills"] = "exact", ["agents"] = "unknown" },
        ["kimi"] = new() { ["tools"] = "exact", ["skills"] = "exact", ["agents"] = "exact" },
        ["dsh"] = new() { ["tools"] = "exact", ["skills"] = "exact", ["agents"] = "unknown" },
        ["opencode"] = new() { ["tools"] = "exact", ["skills"] = "exact", ["agents"] = "unknown" },
        ["hermes"] = new() { ["tools"] = "exact", ["skills"] = "exact", ["agents"] = "unknown" },
        ["pi"] = new() { ["tools"] = "exact", ["skills"] = "unknown", ["agents"] = "unknown" },
        ["codex"] = new() { ["tools"] = "exact", ["skills"] = "derived", ["agents"] = "exact" },
    };

    public static bool NeedsBackfill(Dictionary<string, object?> cursor) =>
        PyJson.AsLong(cursor.Get("activity_parser_version")) != ParserVersion;

    public static void MarkCurrent(Dictionary<string, object?> cursor) =>
        cursor["activity_parser_version"] = (long)ParserVersion;
}
