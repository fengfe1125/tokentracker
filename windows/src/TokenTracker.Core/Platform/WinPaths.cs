using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace TokenTracker.Core.Platform;

/// <summary>
/// Windows 路径规范（写入 usage.db 的键依赖它，改动需迁移；见 docs/windows-port.md）：
/// 根目录 = GetFullPath（反斜杠、无尾分隔符、不改大小写）；需要真实路径处用 Real()。
/// </summary>
public static class WinPaths
{
    public static string Home =>
        Environment.GetEnvironmentVariable("USERPROFILE") is { Length: > 0 } profile
            ? profile
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public static string LocalAppData =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public static string AppData =>
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

    /// <summary>~/.tokentracker（与 Swift / Python 版共用的数据目录）。</summary>
    public static string DataDir => Path.Combine(Home, ".tokentracker");

    /// <summary>展开 ~ 与 %VAR%，规范为绝对路径（对齐 expanduser + normpath）。</summary>
    public static string Expand(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;
        var p = Environment.ExpandEnvironmentVariables(path);
        if (p == "~") p = Home;
        else if (p.StartsWith("~/", StringComparison.Ordinal) || p.StartsWith("~\\", StringComparison.Ordinal))
            p = Path.Combine(Home, p[2..]);
        try
        {
            p = Path.GetFullPath(p);
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return p;
        }
        return TrimTrailingSeparator(p);
    }

    static string TrimTrailingSeparator(string p)
    {
        var root = Path.GetPathRoot(p) ?? "";
        while (p.Length > root.Length && (p.EndsWith('\\') || p.EndsWith('/'))) p = p[..^1];
        return p;
    }

    /// <summary>
    /// 真实路径（对齐 CPython ntpath.realpath：解析联接点/符号链接、8.3 短名与磁盘上的大小写）。
    /// 文件不存在时退回 Expand。
    /// </summary>
    public static string Real(string path)
    {
        var full = Expand(path);
        try
        {
            using var handle = CreateFileW(full, FILE_READ_ATTRIBUTES,
                FileShare.ReadWrite | FileShare.Delete, IntPtr.Zero, FileMode.Open,
                FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle.IsInvalid) return full;
            var buffer = new StringBuilder(1024);
            var n = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (n > buffer.Capacity)
            {
                buffer = new StringBuilder((int)n + 1);
                n = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            }
            if (n == 0) return full;
            var result = buffer.ToString(0, (int)n);
            if (result.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) result = @"\\" + result[8..];
            else if (result.StartsWith(@"\\?\", StringComparison.Ordinal)) result = result[4..];
            return TrimTrailingSeparator(result);
        }
        catch
        {
            return full;
        }
    }

    /// <summary>
    /// 可登记为项目目录的绝对路径：Windows 全限定路径，或 POSIX 形式的外来路径（原样保留）。
    /// 替代 Swift/Python 里的 hasPrefix("/") 检查。
    /// </summary>
    public static bool IsAbsoluteProjectPath(string? path) =>
        !string.IsNullOrEmpty(path) && !path.Contains('\0')
        && (path.StartsWith('/') || Path.IsPathFullyQualified(path));

    /// <summary>目录是否存在（非文件）。</summary>
    public static bool IsDirectory(string path) => Directory.Exists(path);

    /// <summary>
    /// 递归列出 root 下满足 predicate 的文件，返回以 '/' 分隔的相对路径，按序号排序
    /// （与 POSIX 上 os.walk + sorted 的顺序一致）。包含隐藏文件，不进入联接点/符号链接目录。
    /// </summary>
    public static List<string> EnumerateFilesRelative(string root, Func<string, bool> predicate)
    {
        var output = new List<string>();
        if (!Directory.Exists(root)) return output;
        var options = new EnumerationOptions
        {
            AttributesToSkip = 0,
            IgnoreInaccessible = true,
            RecurseSubdirectories = false,
            ReturnSpecialDirectories = false,
        };
        var stack = new Stack<(string Dir, string Rel)>();
        stack.Push((root, ""));
        while (stack.Count > 0)
        {
            var (dir, rel) = stack.Pop();
            IEnumerable<FileSystemInfo> entries;
            try
            {
                entries = new DirectoryInfo(dir).EnumerateFileSystemInfos("*", options).ToList();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (var entry in entries)
            {
                var childRel = rel.Length == 0 ? entry.Name : rel + "/" + entry.Name;
                if (entry is DirectoryInfo)
                {
                    if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                    stack.Push((entry.FullName, childRel));
                }
                else if (predicate(childRel))
                {
                    output.Add(childRel);
                }
            }
        }
        output.Sort(StringComparer.Ordinal);
        return output;
    }

    /// <summary>根目录 + '/' 分隔的相对路径 → Windows 路径。</summary>
    public static string JoinRelative(string root, string rel) =>
        rel.Length == 0 ? root : root + "\\" + rel.Replace('/', '\\');

    /// <summary>取最后一个路径组件（同时认 '\' 与 '/'）。</summary>
    public static string LastComponent(string path)
    {
        var trimmed = path.TrimEnd('\\', '/');
        var i = trimmed.LastIndexOfAny(['\\', '/']);
        return i < 0 ? trimmed : trimmed[(i + 1)..];
    }

    /// <summary>去掉最后一个路径组件（同时认 '\' 与 '/'）。</summary>
    public static string Parent(string path)
    {
        var trimmed = path.TrimEnd('\\', '/');
        var i = trimmed.LastIndexOfAny(['\\', '/']);
        if (i < 0) return "";
        var parent = trimmed[..i];
        // "C:\" 的父级保留根
        if (parent.Length == 2 && parent[1] == ':') return parent + "\\";
        return parent.Length == 0 ? trimmed[..1] : parent;
    }

    const uint FILE_READ_ATTRIBUTES = 0x80;
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, FileShare dwShareMode,
        IntPtr lpSecurityAttributes, FileMode dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle hFile, StringBuilder lpszFilePath, uint cchFilePath,
        uint dwFlags);
}
