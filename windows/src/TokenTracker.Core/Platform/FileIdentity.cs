using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TokenTracker.Core.Platform;

/// <summary>
/// 文件指纹（移植 StatKey：{"m": mtime_ns, "s": size, "i": ino, "d": dev}）。
/// 通过打开的句柄取 GetFileInformationByHandle：目录枚举得到的大小/时间对正被
/// 写入方持有的文件会滞后，增量扫描会漏掉追加的行。
/// </summary>
public readonly record struct FileIdentity(long M, long S, long I, long D)
{
    const long EpochDifference100ns = 116444736000000000;

    public static FileIdentity? Of(string path)
    {
        try
        {
            using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            return Of(handle);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException
                                       or NotSupportedException)
        {
            return null;
        }
    }

    public static FileIdentity? Of(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) return null;
        var write = ((long)info.LastWriteTimeHigh << 32) | info.LastWriteTimeLow;
        var size = ((long)info.FileSizeHigh << 32) | info.FileSizeLow;
        var index = unchecked((long)(((ulong)info.FileIndexHigh << 32) | info.FileIndexLow));
        return new FileIdentity((write - EpochDifference100ns) * 100, size, index, info.VolumeSerialNumber);
    }

    public Dictionary<string, object?> AsDict() => new()
    {
        ["m"] = M, ["s"] = S, ["i"] = I, ["d"] = D,
    };

    /// <summary>从游标条目解析；缺任一键返回 null。</summary>
    public static FileIdentity? FromDict(object? value)
    {
        if (value is not Dictionary<string, object?> dict) return null;
        static long? Val(Dictionary<string, object?> d, string k) => d.TryGetValue(k, out var v) ? Json.PyJson.AsLong(v) : null;
        var m = Val(dict, "m");
        var s = Val(dict, "s");
        var i = Val(dict, "i");
        var dv = Val(dict, "d");
        if (m is null || s is null || i is null || dv is null) return null;
        return new FileIdentity(m.Value, s.Value, i.Value, dv.Value);
    }

    /// <summary>Python changed()：只比对指纹键（游标可能带 "o" 等附加字段）。</summary>
    public static bool Changed(Dictionary<string, object?> cursor, string path)
    {
        if (!cursor.TryGetValue(path, out var stored)) return true;
        var storedKey = FromDict(stored);
        var current = Of(path);
        return storedKey is null || current is null || storedKey.Value != current.Value;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow, CreationTimeHigh;
        public uint LastAccessTimeLow, LastAccessTimeHigh;
        public uint LastWriteTimeLow, LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh, FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out ByHandleFileInformation info);
}
