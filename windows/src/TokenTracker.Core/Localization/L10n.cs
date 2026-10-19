using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace TokenTracker.Core.Localization;

/// <summary>
/// Apple .strings 解析器：UTF-8（可带 BOM）或带 BOM 的 UTF-16；/* */ 与 // 注释；
/// "k" = "v"; 条目，支持 \" \\ \n \t \r \Uxxxx 转义；CRLF 与 LF 均可。
/// </summary>
public static class StringsFile
{
    public static Dictionary<string, string> Parse(byte[] data)
    {
        string text;
        if (data.Length >= 2 && data[0] == 0xFF && data[1] == 0xFE) text = Encoding.Unicode.GetString(data, 2, data.Length - 2);
        else if (data.Length >= 2 && data[0] == 0xFE && data[1] == 0xFF) text = Encoding.BigEndianUnicode.GetString(data, 2, data.Length - 2);
        else text = Encoding.UTF8.GetString(data).TrimStart('﻿');
        return Parse(text);
    }

    public static Dictionary<string, string> Parse(string text)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var i = 0;
        void SkipTrivia()
        {
            while (i < text.Length)
            {
                if (char.IsWhiteSpace(text[i])) i++;
                else if (text[i] == '/' && i + 1 < text.Length && text[i + 1] == '*')
                {
                    var end = text.IndexOf("*/", i + 2, StringComparison.Ordinal);
                    i = end < 0 ? text.Length : end + 2;
                }
                else if (text[i] == '/' && i + 1 < text.Length && text[i + 1] == '/')
                {
                    var end = text.IndexOf('\n', i);
                    i = end < 0 ? text.Length : end + 1;
                }
                else break;
            }
        }
        string? ReadString()
        {
            if (i >= text.Length || text[i] != '"') return null;
            i++;
            var sb = new StringBuilder();
            while (i < text.Length && text[i] != '"')
            {
                var c = text[i++];
                if (c != '\\' || i >= text.Length)
                {
                    sb.Append(c);
                    continue;
                }
                var e = text[i++];
                switch (e)
                {
                    case 'n': sb.Append('\n'); break;
                    case 't': sb.Append('\t'); break;
                    case 'r': sb.Append('\r'); break;
                    case 'U' or 'u' when i + 4 <= text.Length:
                        sb.Append((char)int.Parse(text.AsSpan(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: sb.Append(e); break;
                }
            }
            i++; // 闭合引号
            return sb.ToString();
        }
        while (true)
        {
            SkipTrivia();
            if (i >= text.Length) break;
            var key = ReadString();
            if (key is null)
            {
                i++;
                continue;
            }
            SkipTrivia();
            if (i < text.Length && text[i] == '=') i++;
            SkipTrivia();
            var value = ReadString() ?? key;
            SkipTrivia();
            if (i < text.Length && text[i] == ';') i++;
            result[key] = value;
        }
        return result;
    }
}

/// <summary>
/// 本地化（移植 Localization.swift）：键为中文原文，查不到返回键本身；{n} 占位符单趟替换
/// （用户文本里的 {1} 保持原样）。共享 macOS 的 Localizable.strings，Windows 专用文案作为覆盖层。
/// </summary>
public static class L10n
{
    static readonly Regex Placeholders = new(@"\{(\d+)\}");
    static readonly Dictionary<string, Dictionary<string, string>> Tables = new()
    {
        ["zh-Hans"] = Load("zh-Hans"),
        ["en"] = Load("en"),
    };
    static volatile string _language = ResolveSystem();

    /// <summary>语言切换（界面据此刷新文案）。</summary>
    public static event Action? LanguageChanged;

    static Dictionary<string, string> Load(string language)
    {
        var table = EmbeddedResources.ReadBytes($"TokenTracker.{language}.strings") is { } shared
            ? StringsFile.Parse(shared)
            : new Dictionary<string, string>(StringComparer.Ordinal);
        if (EmbeddedResources.ReadBytes($"TokenTracker.windows.{language}.strings") is { } overlay)
            foreach (var (k, v) in StringsFile.Parse(overlay))
                table[k] = v;
        return table;
    }

    /// <summary>「跟随系统」：系统首选语言以 zh 开头 → zh-Hans，否则 en（与 macOS 一致）。</summary>
    public static string ResolveSystem() =>
        CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en";

    /// <summary>preference：system / zh-Hans / en。</summary>
    public static string Resolve(string? preference) => preference is "zh-Hans" or "en" ? preference : ResolveSystem();

    public static string Language => _language;
    public static bool IsEnglish => _language == "en";
    public static CultureInfo Culture => CultureInfo.GetCultureInfo(IsEnglish ? "en-US" : "zh-CN");

    public static void SetLanguage(string language)
    {
        var resolved = language is "en" ? "en" : "zh-Hans";
        if (resolved == _language) return;
        _language = resolved;
        LanguageChanged?.Invoke();
    }

    public static IReadOnlyDictionary<string, string> Table(string language) => Tables[language == "en" ? "en" : "zh-Hans"];

    /// <summary>翻译并替换 {n} 占位符。</summary>
    public static string T(string key, params object?[] args)
    {
        var translated = Table(_language).TryGetValue(key, out var v) ? v : key;
        if (args.Length == 0) return translated;
        return Placeholders.Replace(translated, m =>
        {
            var index = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
            return index < args.Length ? Convert.ToString(args[index], CultureInfo.InvariantCulture) ?? "" : m.Value;
        });
    }

    /// <summary>printf 风格键（如 "≈ %.2f 万"）：先翻译，再替换 %.Nf / %d / %@。</summary>
    public static string Format(string key, params object[] args)
    {
        var template = Table(_language).TryGetValue(key, out var v) ? v : key;
        var index = 0;
        return Regex.Replace(template, @"%(?:\.(\d+))?([fd@])", m =>
        {
            if (index >= args.Length) return m.Value;
            var arg = args[index++];
            return m.Groups[2].Value switch
            {
                "f" => Convert.ToDouble(arg, CultureInfo.InvariantCulture)
                    .ToString("F" + (m.Groups[1].Success ? m.Groups[1].Value : "6"), CultureInfo.InvariantCulture),
                "d" => Convert.ToInt64(arg, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture),
                _ => Convert.ToString(arg, CultureInfo.InvariantCulture) ?? "",
            };
        });
    }
}
