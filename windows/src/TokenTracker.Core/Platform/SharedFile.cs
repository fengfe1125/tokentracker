using System.Text;

namespace TokenTracker.Core.Platform;

/// <summary>与正在写文件的 CLI 共存的读写（Windows 默认共享模式会报共享冲突）。</summary>
public static class SharedFile
{
    const int ErrorSharingViolation = 32;
    const int ErrorLockViolation = 33;
    const int ErrorAccessDenied = 5;

    public static FileStream OpenRead(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024);

    /// <summary>读全部字节；文件不存在或不可读返回 null。</summary>
    public static byte[]? ReadAllBytes(string path)
    {
        try
        {
            using var stream = OpenRead(path);
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            return buffer.ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException
                                       or NotSupportedException)
        {
            return null;
        }
    }

    public static string? ReadAllText(string path) =>
        ReadAllBytes(path) is { } bytes ? Encoding.UTF8.GetString(StripBom(bytes)) : null;

    static byte[] StripBom(byte[] bytes) =>
        bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? bytes[3..] : bytes;

    /// <summary>
    /// 原子写：同目录临时文件 + Flush(true) + MoveFileEx(REPLACE_EXISTING)。
    /// POSIX rename 在 Windows 上不能覆盖已有文件，这里是它的替代；共享冲突时短暂重试。
    /// </summary>
    public static bool AtomicWrite(string path, byte[] data)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = Path.Combine(dir ?? ".", $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(data);
                stream.Flush(true);
            }
            var deadline = Environment.TickCount64 + 2000;
            while (true)
            {
                try
                {
                    File.Move(tmp, path, overwrite: true);
                    return true;
                }
                catch (IOException e) when (IsTransient(e) && Environment.TickCount64 < deadline)
                {
                    Thread.Sleep(50);
                }
                catch (UnauthorizedAccessException) when (Environment.TickCount64 < deadline)
                {
                    Thread.Sleep(50);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
        finally
        {
            try
            {
                if (File.Exists(tmp)) File.Delete(tmp);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    public static bool AtomicWriteText(string path, string text) =>
        AtomicWrite(path, new UTF8Encoding(false).GetBytes(text));

    static bool IsTransient(IOException e)
    {
        var code = e.HResult & 0xFFFF;
        return code is ErrorSharingViolation or ErrorLockViolation or ErrorAccessDenied;
    }
}
