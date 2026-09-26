using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace TokenTracker.Windows.Tray;

/// <summary>
/// 托盘配额环图标（移植 StatusItemController.swift 的 ringImage）：从 12 点方向顺时针的扇形，
/// 22% 透明度底色，颜色按紧急度；无数据画灰色空心圆；扫描中画一段品牌色弧。
/// 按系统小图标尺寸渲染，参数不变时复用，旧 HICON 及时销毁。
/// </summary>
public sealed class RingIconRenderer : IDisposable
{
    Icon? _current;
    IntPtr _handle;
    string _key = "";

    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool DestroyIcon(IntPtr handle);

    const int SmCxSmIcon = 49;

    /// <summary>任务栏是否为浅色（决定无数据空心圆的灰度）。</summary>
    static bool LightTaskbar()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int v && v != 0;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    static Color RoleColor(string role) => role switch
    {
        "quota_crit" => Color.FromArgb(0xE0, 0x3E, 0x3E),
        "quota_warn" => Color.FromArgb(0xF0, 0x8C, 0x00),
        _ => Color.FromArgb(0x34, 0xA8, 0x53),
    };

    /// <summary>返回当前参数对应的图标；参数没变时返回同一实例。</summary>
    public Icon Render(double? pct, string role, bool scanning)
    {
        var size = Math.Max(16, GetSystemMetrics(SmCxSmIcon));
        var light = LightTaskbar();
        var pctKey = pct is { } p ? ((int)Math.Round(p)).ToString() : "none";
        var key = $"{size}|{pctKey}|{role}|{scanning}|{light}";
        if (key == _key && _current is not null) return _current;

        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var inset = size * 0.08f;
            var rect = new RectangleF(inset, inset, size - 2 * inset, size - 2 * inset);
            if (scanning)
            {
                var accent = Color.FromArgb(0xD9, 0x77, 0x57);
                using var track = new Pen(Color.FromArgb(70, accent), size * 0.14f);
                using var arc = new Pen(accent, size * 0.14f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                var ring = RectangleF.Inflate(rect, -size * 0.07f, -size * 0.07f);
                g.DrawEllipse(track, ring);
                g.DrawArc(arc, ring, -90, 120);
            }
            else if (pct is { } value)
            {
                var color = RoleColor(role);
                using var trackBrush = new SolidBrush(Color.FromArgb(56, color));
                g.FillEllipse(trackBrush, rect);
                var sweep = (float)(Math.Clamp(value, 0, 100) / 100 * 360);
                using var fill = new SolidBrush(color);
                if (sweep >= 359.5f) g.FillEllipse(fill, rect);
                else if (sweep > 0) g.FillPie(fill, rect.X, rect.Y, rect.Width, rect.Height, -90, sweep);
            }
            else
            {
                var gray = light ? Color.FromArgb(0x70, 0x70, 0x70) : Color.FromArgb(0xB0, 0xB0, 0xB0);
                using var pen = new Pen(gray, Math.Max(1.2f, size / 12f));
                g.DrawEllipse(pen, RectangleF.Inflate(rect, -size * 0.04f, -size * 0.04f));
            }
        }
        var handle = bitmap.GetHicon();
        var icon = Icon.FromHandle(handle);
        Release();
        _current = icon;
        _handle = handle;
        _key = key;
        return icon;
    }

    void Release()
    {
        _current?.Dispose();
        if (_handle != IntPtr.Zero) DestroyIcon(_handle);
        _current = null;
        _handle = IntPtr.Zero;
    }

    public void Dispose() => Release();
}
