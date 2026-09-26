using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using TokenTracker.Core.Json;
using TokenTracker.Core.Platform;
using TokenTracker.Core.Store;
using ZstdSharp;

namespace TokenTracker.Core.Scanners;

/// <summary>一次扫描在单个工作线程上运行；只有计数离开此范围，绝不含内容。</summary>
public sealed class ScanDiagnostics
{
    public int ParseErrors;
    public int ReadErrors;

    [ThreadStatic] static ScanDiagnostics? _current;

    public static ScanDiagnostics? Current => _current;

    public static void Begin() => _current = new ScanDiagnostics();
}

/// <summary>移植 Scanners/ScannerSupport.swift（_util.py）：JSONL 迭代、字节游标增量读、zstd、ISO 时间、会话标题。</summary>
public static class ScannerSupport
{
    // ------------------------------------------------------------ JSONL ----

    /// <summary>json.loads 一行 → 对象（非对象返回 null 并计入解析错误）。</summary>
    public static Dictionary<string, object?>? ParseJsonLine(ReadOnlySpan<byte> line)
    {
        var obj = PyJson.TryParse(line, out var value) ? value as Dictionary<string, object?> : null;
        if (obj is null && ScanDiagnostics.Current is { } d) d.ParseErrors++;
        return obj;
    }

    static List<(int Line, Dictionary<string, object?> Obj)> ParseLines(byte[] data)
    {
        var output = new List<(int, Dictionary<string, object?>)>();
        var text = Encoding.UTF8.GetString(data); // errors="replace"
        var lineNo = 0;
        foreach (var raw in text.Split('\n'))
        {
            lineNo++;
            var trimmed = raw.Trim();
            if (trimmed.Length == 0) continue;
            if (ParseJsonLine(Encoding.UTF8.GetBytes(trimmed)) is { } obj) output.Add((lineNo, obj));
        }
        return output;
    }

    /// <summary>iter_jsonl：(行号从 1 起, 对象)。解析失败的行跳过，行号仍计入。</summary>
    public static List<(int Line, Dictionary<string, object?> Obj)> IterJsonl(string path)
    {
        var data = SharedFile.ReadAllBytes(path);
        if (data is null)
        {
            if (ScanDiagnostics.Current is { } d) d.ReadErrors++;
            return [];
        }
        return ParseLines(data);
    }

    /// <summary>iter_zstd_jsonl：zstd 压缩 JSONL（DSH），进程内解压，不依赖 zstd.exe。</summary>
    public static List<(int Line, Dictionary<string, object?> Obj)> IterZstdJsonl(string path)
    {
        try
        {
            using var file = SharedFile.OpenRead(path);
            using var decompressor = new DecompressionStream(file);
            using var buffer = new MemoryStream();
            decompressor.CopyTo(buffer);
            return ParseLines(buffer.ToArray());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ZstdException)
        {
            if (ScanDiagnostics.Current is { } d) d.ReadErrors++;
            return [];
        }
    }

    /// <summary>
    /// read_jsonl_delta：从字节偏移（必须是行边界）增量读，只解析新增完整行。
    /// 返回 (items, newOffset)；items 为 (行起始偏移, 对象)。偏移失效（截断/轮转/不在行边界）返回 ([], -1)。
    /// </summary>
    public static (List<(long Offset, Dictionary<string, object?> Obj)> Items, long NewOffset) ReadJsonlDelta(
        string path, long offset)
    {
        var items = new List<(long, Dictionary<string, object?>)>();
        try
        {
            using var stream = SharedFile.OpenRead(path);
            var size = stream.Length;
            if (offset < 0 || offset > size) return (items, -1);
            if (offset > 0)
            {
                stream.Seek(offset - 1, SeekOrigin.Begin);
                if (stream.ReadByte() != '\n') return (items, -1);
            }
            stream.Seek(offset, SeekOrigin.Begin);
            var remaining = new byte[size - offset];
            var read = 0;
            while (read < remaining.Length)
            {
                var n = stream.Read(remaining, read, remaining.Length - read);
                if (n == 0) break;
                read += n;
            }
            var newOffset = offset;
            var start = 0;
            while (start < read)
            {
                var nl = Array.IndexOf(remaining, (byte)'\n', start, read - start);
                if (nl < 0) break; // 写入中的尾行：留给下次
                var lineOffset = offset + start;
                newOffset = offset + nl + 1;
                if (ParseJsonLine(remaining.AsSpan(start, nl - start)) is { } obj) items.Add((lineOffset, obj));
                start = nl + 1;
            }
            return (items, newOffset);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return ([], -1);
        }
    }

    // ------------------------------------------------------------ 时间解析 ----

    static readonly Regex IsoRegex = new(
        @"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(Z|[+-]\d{2}(?::?\d{2})?)$",
        RegexOptions.CultureInvariant);

    /// <summary>
    /// Python datetime.fromisoformat(ts.replace("Z","+00:00")).timestamp()*1000（截断）。
    /// 与 Swift 一样要求带时区；无时区返回 null。
    /// </summary>
    public static long? ParseIsoDateMs(string ts)
    {
        var m = IsoRegex.Match(ts.Trim());
        if (!m.Success) return null;
        try
        {
            int G(int i) => m.Groups[i].Success ? int.Parse(m.Groups[i].Value, CultureInfo.InvariantCulture) : 0;
            var zone = m.Groups[8].Value;
            var offset = TimeSpan.Zero;
            if (zone != "Z")
            {
                var sign = zone[0] == '-' ? -1 : 1;
                var digits = zone[1..].Replace(":", "");
                var hours = int.Parse(digits[..2], CultureInfo.InvariantCulture);
                var minutes = digits.Length >= 4 ? int.Parse(digits[2..4], CultureInfo.InvariantCulture) : 0;
                offset = TimeSpan.FromMinutes(sign * (hours * 60 + minutes));
            }
            var dto = new DateTimeOffset(G(1), G(2), G(3), G(4), G(5), G(6), offset);
            var fraction = m.Groups[7].Success ? m.Groups[7].Value : "";
            var micros = fraction.Length == 0 ? 0 : long.Parse(fraction.PadRight(6, '0')[..6], CultureInfo.InvariantCulture);
            var totalMicros = dto.ToUnixTimeSeconds() * 1_000_000 + micros;
            return (long)(totalMicros / 1e6 * 1000);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>数字（秒或毫秒）或 ISO 字符串 → 毫秒；无法解析返回 0。</summary>
    public static long ParseTs(object? raw)
    {
        if (PyJson.AsNumber(raw) is { } d) return (long)(d < 1e12 ? d * 1000 : d);
        if (raw is string s) return ParseIsoDateMs(s) ?? 0;
        return 0;
    }

    // ------------------------------------------------------------ 会话标题 ----

    static readonly string[] ContextPrefixes =
    [
        "# AGENTS.md", "<INSTRUCTIONS>", "<environment_context>", "<system-reminder>", "Caveat:", "<command-",
        "<local-command", "<recommended_plugins", "<user_instructions", "## Referenced ChatGPT conversation",
        "<task-notification", "The following is the Codex agent history",
    ];

    static string ContentText(object? content) => content switch
    {
        string s => s,
        List<object?> list => string.Join(" ", list.OfType<Dictionary<string, object?>>()
            .Where(b => b.Get("type") is "text" or "input_text")
            .Select(b => b.TryGetValue("text", out var t) ? PyJson.PyStr(t) : "")),
        _ => "",
    };

    /// <summary>user_text：首个真实用户消息（跳过 AGENTS.md / 环境上下文注入）。</summary>
    public static string UserText(Dictionary<string, object?> obj)
    {
        var text = "";
        var kind = obj.Get("type") as string;
        if (kind is "user" or "message")
        {
            if (obj.Get("message") is Dictionary<string, object?> msg && msg.Get("role") as string == "user")
                text = ContentText(msg.Get("content"));
        }
        else if (kind == "response_item")
        {
            if (obj.Get("payload") is Dictionary<string, object?> payload && payload.Get("role") as string == "user")
                text = ContentText(payload.Get("content"));
        }
        text = TextUtil.CollapseWhitespace(text);
        if (text.Length == 0 || ContextPrefixes.Any(p => text.StartsWith(p, StringComparison.Ordinal))) return "";
        return TextUtil.Truncate120(text);
    }
}
