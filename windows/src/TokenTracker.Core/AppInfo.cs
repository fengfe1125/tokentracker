using System.Reflection;

namespace TokenTracker.Core;

/// <summary>应用版本与常量（对齐 swift TokenTrackerCore.swift）。</summary>
public static class AppInfo
{
    /// <summary>差分导出格式版本（tests/differential/export_python.py）。</summary>
    public const int DifferentialFormatVersion = 3;

    /// <summary>应用版本：构建时从 Swift 核心的 version 常量解析。</summary>
    public static string Version { get; } =
        typeof(AppInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "0.0.0";
}
