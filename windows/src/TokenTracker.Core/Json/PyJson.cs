using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace TokenTracker.Core.Json;

/// <summary>
/// 与 Python json.loads 语义一致的 JSON 树：对象 = Dictionary&lt;string, object?&gt;（重复键后者覆盖），
/// 数组 = List&lt;object?&gt;，整数 = long，小数 = double，bool，null。
/// 取值辅助函数复刻 Swift ScannerSupport 里的 jsonInt / jsonOrAny 等（Python 真值语义）。
/// </summary>
public static class PyJson
{
    static readonly JsonReaderOptions ReaderOptions = new() { MaxDepth = 512 };

    // ------------------------------------------------------------ 解析 ----

    public static bool TryParse(ReadOnlySpan<byte> utf8, out object? value)
    {
        try
        {
            value = Parse(utf8);
            return true;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or ArgumentException)
        {
            // 非法 UTF-8：按 errors="replace" 解码后重试一次
            try
            {
                var repaired = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(utf8));
                if (repaired.AsSpan().SequenceEqual(utf8)) throw;
                value = Parse(repaired);
                return true;
            }
            catch (Exception e2) when (e2 is JsonException or InvalidOperationException or ArgumentException)
            {
                value = null;
                return false;
            }
        }
    }

    public static bool TryParse(string text, out object? value) => TryParse(Encoding.UTF8.GetBytes(text), out value);

    /// <summary>解析为对象；非对象或非法返回 null。</summary>
    public static Dictionary<string, object?>? ParseObject(ReadOnlySpan<byte> utf8) =>
        TryParse(utf8, out var v) ? v as Dictionary<string, object?> : null;

    public static Dictionary<string, object?>? ParseObject(string? text) =>
        text is null ? null : ParseObject(Encoding.UTF8.GetBytes(text));

    public static Dictionary<string, object?>? ReadObjectFile(string path) =>
        Platform.SharedFile.ReadAllBytes(path) is { } bytes ? ParseObject(StripBom(bytes)) : null;

    static ReadOnlySpan<byte> StripBom(byte[] bytes) =>
        bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? bytes.AsSpan(3) : bytes;

    static object? Parse(ReadOnlySpan<byte> utf8)
    {
        var reader = new Utf8JsonReader(utf8, ReaderOptions);
        if (!reader.Read()) throw new JsonException("empty");
        var value = ReadValue(ref reader);
        if (reader.Read()) throw new JsonException("trailing data");
        return value;
    }

    static object? ReadValue(ref Utf8JsonReader reader)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.StartObject:
            {
                var dict = new Dictionary<string, object?>();
                while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
                {
                    var key = reader.GetString()!;
                    reader.Read();
                    dict[key] = ReadValue(ref reader);
                }
                return dict;
            }
            case JsonTokenType.StartArray:
            {
                var list = new List<object?>();
                while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                    list.Add(ReadValue(ref reader));
                return list;
            }
            case JsonTokenType.String:
                return reader.GetString();
            case JsonTokenType.Number:
            {
                var span = reader.HasValueSequence ? reader.ValueSequence.ToArray() : reader.ValueSpan.ToArray();
                var isFloat = Array.IndexOf(span, (byte)'.') >= 0 || Array.IndexOf(span, (byte)'e') >= 0
                              || Array.IndexOf(span, (byte)'E') >= 0;
                if (!isFloat && reader.TryGetInt64(out var l)) return l;
                return reader.GetDouble();
            }
            case JsonTokenType.True:
                return true;
            case JsonTokenType.False:
                return false;
            case JsonTokenType.Null:
                return null;
            default:
                throw new JsonException($"unexpected token {reader.TokenType}");
        }
    }

    // ------------------------------------------------------------ 序列化 ----

    static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>紧凑 JSON（游标 / 快照值 / 缓存等内部存储用）。</summary>
    public static string Serialize(object? value)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            Write(writer, value);
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    static void Write(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNullValue();
                break;
            case string s:
                writer.WriteStringValue(s);
                break;
            case bool b:
                writer.WriteBooleanValue(b);
                break;
            case long l:
                writer.WriteNumberValue(l);
                break;
            case int i:
                writer.WriteNumberValue(i);
                break;
            case double d:
                if (double.IsFinite(d)) writer.WriteNumberValue(d);
                else writer.WriteNullValue();
                break;
            case IDictionary<string, object?> dict:
                writer.WriteStartObject();
                foreach (var (k, v) in dict)
                {
                    writer.WritePropertyName(k);
                    Write(writer, v);
                }
                writer.WriteEndObject();
                break;
            case System.Collections.IEnumerable list:
                writer.WriteStartArray();
                foreach (var item in list) Write(writer, item);
                writer.WriteEndArray();
                break;
            default:
                writer.WriteStringValue(Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
        }
    }

    // ------------------------------------------------------------ 取值 ----

    public static Dictionary<string, object?>? Dict(object? value) => value as Dictionary<string, object?>;

    public static List<object?>? List(object? value) => value as List<object?>;

    public static object? Get(this Dictionary<string, object?>? dict, string key) =>
        dict is not null && dict.TryGetValue(key, out var v) ? v : null;

    public static Dictionary<string, object?>? GetDict(this Dictionary<string, object?>? dict, string key) =>
        dict.Get(key) as Dictionary<string, object?>;

    public static string? GetString(this Dictionary<string, object?>? dict, string key) => dict.Get(key) as string;

    public static bool Has(this Dictionary<string, object?>? dict, string key) =>
        dict is not null && dict.ContainsKey(key);

    /// <summary>NSNumber.int64Value：整数 / 小数（截断）/ bool。</summary>
    public static long? AsLong(object? value) => value switch
    {
        long l => l,
        int i => i,
        double d when double.IsFinite(d) => (long)d,
        bool b => b ? 1 : 0,
        _ => null,
    };

    /// <summary>NSNumber.doubleValue：整数 / 小数 / bool。</summary>
    public static double? AsDouble(object? value) => value switch
    {
        long l => l,
        int i => i,
        double d => d,
        bool b => b ? 1 : 0,
        _ => null,
    };

    /// <summary>非 bool 的数字（CFGetTypeID != CFBoolean）。</summary>
    public static double? AsNumber(object? value) => value switch
    {
        long l => l,
        int i => i,
        double d => d,
        _ => null,
    };

    /// <summary>Python `obj.get(k) or 0`（数字）：None/缺失/非数字 → 0；bool → 1/0；小数截断。</summary>
    public static long JInt(object? value) => AsLong(value) ?? 0;

    /// <summary>Python isinstance(v, int) and not bool and v >= 0。</summary>
    public static long? StrictNonNegativeInt(object? value) => value is long l && l >= 0 ? l : null;

    /// <summary>Python 真值。</summary>
    public static bool Truthy(object? value) => value switch
    {
        null => false,
        string s => s.Length > 0,
        bool b => b,
        long l => l != 0,
        int i => i != 0,
        double d => d != 0,
        Dictionary<string, object?> dict => dict.Count > 0,
        List<object?> list => list.Count > 0,
        _ => true,
    };

    /// <summary>Python `a or b`。</summary>
    public static object? Or(object? a, object? b) => Truthy(a) ? a : b;

    public static object? Or(object? a, object? b, object? c) => Or(Or(a, b), c);

    /// <summary>Python `a or b or 0`（数字）。</summary>
    public static long OrInt(object? first, object? second)
    {
        var a = JInt(first);
        return a != 0 ? a : JInt(second);
    }

    /// <summary>Python `a or b`（字符串）：空串 / 缺失回退。</summary>
    public static string OrString(object? first, object? second) =>
        first is string { Length: > 0 } s ? s : second as string ?? "";

    public static string OrString(object? first, object? second, object? third)
    {
        var value = OrString(first, second);
        return value.Length == 0 ? third as string ?? "" : value;
    }

    /// <summary>字符串或数字（非 bool）形式的标识符：取第一个非空者。</summary>
    public static string Identifier(params object?[] values)
    {
        foreach (var value in values)
        {
            switch (value)
            {
                case string { Length: > 0 } s:
                    return s;
                case long or int or double:
                    return PyStr(value);
            }
        }
        return "";
    }

    // ------------------------------------------------------------ Python str() ----

    /// <summary>Python str(value)。</summary>
    public static string PyStr(object? value) => value switch
    {
        null => "None",
        string s => s,
        bool b => b ? "True" : "False",
        long l => l.ToString(CultureInfo.InvariantCulture),
        int i => i.ToString(CultureInfo.InvariantCulture),
        double d => PyFloatRepr(d),
        _ => Serialize(value),
    };

    /// <summary>Python repr(float)：最短往返表示，指数 &lt; -4 或 ≥ 16 时用科学计数法。</summary>
    public static string PyFloatRepr(double d)
    {
        if (double.IsNaN(d)) return "nan";
        if (double.IsPositiveInfinity(d)) return "inf";
        if (double.IsNegativeInfinity(d)) return "-inf";
        if (d == 0) return double.IsNegative(d) ? "-0.0" : "0.0";
        // "R" 给出最短往返有效数字，再按 Python 规则重排
        var shortest = d.ToString("R", CultureInfo.InvariantCulture);
        var negative = shortest.StartsWith('-');
        if (negative) shortest = shortest[1..];
        var ePos = shortest.IndexOfAny(['E', 'e']);
        var basePart = ePos >= 0 ? shortest[..ePos] : shortest;
        var expPart = ePos >= 0 ? int.Parse(shortest[(ePos + 1)..], CultureInfo.InvariantCulture) : 0;
        var dot = basePart.IndexOf('.');
        var intDigits = dot >= 0 ? basePart[..dot] : basePart;
        var fracDigits = dot >= 0 ? basePart[(dot + 1)..] : "";
        var digits = (intDigits + fracDigits).TrimStart('0');
        var leadingZeros = (intDigits + fracDigits).Length - digits.Length;
        digits = digits.TrimEnd('0');
        if (digits.Length == 0) digits = "0";
        // 十进制指数：value = d1.d2d3... × 10^exponent
        var exponent = intDigits.Length - leadingZeros + expPart - 1;
        var mantissaDigits = digits;
        string body;
        if (exponent < -4 || exponent >= 16)
        {
            var mant = mantissaDigits.Length == 1 ? mantissaDigits : mantissaDigits[0] + "." + mantissaDigits[1..];
            body = mant + "e" + (exponent < 0 ? "-" : "+") + Math.Abs(exponent).ToString("00", CultureInfo.InvariantCulture);
        }
        else if (exponent < 0)
        {
            body = "0." + new string('0', -exponent - 1) + mantissaDigits;
        }
        else if (mantissaDigits.Length <= exponent + 1)
        {
            body = mantissaDigits + new string('0', exponent + 1 - mantissaDigits.Length) + ".0";
        }
        else
        {
            body = mantissaDigits[..(exponent + 1)] + "." + mantissaDigits[(exponent + 1)..];
        }
        return negative ? "-" + body : body;
    }
}
