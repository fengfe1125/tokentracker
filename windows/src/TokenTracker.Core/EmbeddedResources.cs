using System.Text;

namespace TokenTracker.Core;

/// <summary>构建时嵌入的共享资源（仓库根 prices.json、Localizable.strings）。</summary>
public static class EmbeddedResources
{
    public static byte[]? ReadBytes(string logicalName)
    {
        using var stream = typeof(EmbeddedResources).Assembly.GetManifestResourceStream(logicalName);
        if (stream is null) return null;
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }

    public static string? ReadText(string logicalName) =>
        ReadBytes(logicalName) is { } bytes ? Encoding.UTF8.GetString(bytes).TrimStart('﻿') : null;
}
