namespace TokenTracker.Core.Platform;

/// <summary>跨进程互斥（替代 flock）：以 FileShare.None 独占打开锁文件，锁文件常驻不删。</summary>
public sealed class FileLock : IDisposable
{
    readonly FileStream _stream;

    FileLock(FileStream stream) => _stream = stream;

    /// <summary>在 timeout 内拿不到锁返回 null。</summary>
    public static FileLock? Acquire(string path, TimeSpan timeout)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var deadline = DateTime.UtcNow + timeout;
        while (true)
        {
            try
            {
                return new FileLock(new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite,
                    FileShare.None));
            }
            catch (IOException) when (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(50);
            }
            catch (IOException)
            {
                return null;
            }
            catch (UnauthorizedAccessException)
            {
                return null;
            }
        }
    }

    public void Dispose() => _stream.Dispose();
}
