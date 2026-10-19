using System.Diagnostics;
using System.Text;

namespace TokenTracker.Core.Platform;

public sealed record ProcessResult(int ExitCode, string Stdout, string Stderr, bool TimedOut);

/// <summary>
/// 子进程统一入口：不弹控制台窗口（WinExe 调 git/codex 时会闪黑框）、参数走 ArgumentList、
/// UTF-8 输出、超时结束整个进程树；.cmd/.bat 经 cmd.exe /d /s /c 启动。
/// </summary>
public static class ProcessRunner
{
    public static ProcessStartInfo StartInfo(string executable, IEnumerable<string> arguments,
        IDictionary<string, string?>? environment = null, string? workingDirectory = null)
    {
        var info = new ProcessStartInfo
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        var ext = Path.GetExtension(executable);
        if (ext.Equals(".cmd", StringComparison.OrdinalIgnoreCase) || ext.Equals(".bat", StringComparison.OrdinalIgnoreCase))
        {
            info.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            info.ArgumentList.Add("/d");
            info.ArgumentList.Add("/s");
            info.ArgumentList.Add("/c");
            info.ArgumentList.Add(executable);
        }
        else
        {
            info.FileName = executable;
        }
        foreach (var arg in arguments) info.ArgumentList.Add(arg);
        if (environment is not null)
            foreach (var (k, v) in environment)
                info.Environment[k] = v;
        if (workingDirectory is not null) info.WorkingDirectory = workingDirectory;
        return info;
    }

    public static ProcessResult Run(string executable, IEnumerable<string> arguments, TimeSpan timeout,
        IDictionary<string, string?>? environment = null, string? workingDirectory = null)
    {
        using var process = new Process { StartInfo = StartInfo(executable, arguments, environment, workingDirectory) };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) lock (stdout) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (stderr) stderr.AppendLine(e.Data); };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        if (!process.WaitForExit(timeout))
        {
            Kill(process);
            return new ProcessResult(-1, stdout.ToString(), stderr.ToString(), true);
        }
        process.WaitForExit();
        return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString(), false);
    }

    /// <summary>尽力结束进程树（cmd → node → codex.exe）。</summary>
    public static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception
                                       or NotSupportedException)
        {
        }
    }
}
