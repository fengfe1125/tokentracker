using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using TokenTracker.Core.Json;

namespace TokenTracker.Core.Store;

/// <summary>
/// 复刻 Python json.dumps（ensure_ascii=True，分隔符 ", " / ": "）。aggregate 快照的 src_key
/// 摘要与 hermes identity 必须与 Python / Swift 逐字节一致，否则共用 usage.db 时键不同。
/// </summary>
public static class PythonJson
{
    public static string DumpsString(string s)
    {
        var sb = new StringBuilder(s.Length + 2);
        sb.Append('"');
        foreach (var unit in s)
        {
            switch (unit)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\t': sb.Append("\\t"); break;
                case '\n': sb.Append("\\n"); break;
                case '\f': sb.Append("\\f"); break;
                case '\r': sb.Append("\\r"); break;
                default:
                    if (unit < 0x20 || unit > 0x7E)
                        sb.Append("\\u").Append(((int)unit).ToString("x4", CultureInfo.InvariantCulture));
                    else
                        sb.Append(unit);
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }

    /// <summary>json.dumps(value)：仅支持快照用到的类型（字符串 / null / 整数 / 小数 / 数组）。</summary>
    public static string Dumps(object? value) => value switch
    {
        null => "null",
        string s => DumpsString(s),
        bool b => b ? "true" : "false",
        long l => l.ToString(CultureInfo.InvariantCulture),
        int i => i.ToString(CultureInfo.InvariantCulture),
        double d => PyJson.PyFloatRepr(d),
        System.Collections.IEnumerable list => "[" + string.Join(", ", list.Cast<object?>().Select(Dumps)) + "]",
        _ => "null",
    };

    /// <summary>hashlib.sha256(text.encode()).hexdigest()。</summary>
    public static string Sha256Hex(string text) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();

    /// <summary>Python round(x, ndigits)：half-even。</summary>
    public static double RoundHalfEven(double value, int digits)
    {
        var factor = Math.Pow(10, digits);
        return Math.Round(value * factor, MidpointRounding.ToEven) / factor;
    }
}
