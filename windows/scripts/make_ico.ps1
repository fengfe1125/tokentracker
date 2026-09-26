# 从 assets/icon_1024.png 生成 Windows 多尺寸图标（PNG 压缩的 ICO，16–256px）。
# 用法：pwsh windows/scripts/make_ico.ps1   产物提交到 windows/src/TokenTracker.Windows/Assets/TokenTracker.ico
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$source = Join-Path $repo 'assets\icon_1024.png'
$target = Join-Path $repo 'windows\src\TokenTracker.Windows\Assets\TokenTracker.ico'
New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$original = [System.Drawing.Image]::FromFile($source)
$images = foreach ($size in $sizes) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.DrawImage($original, 0, 0, $size, $size)
    $graphics.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    [pscustomobject]@{ Size = $size; Bytes = $stream.ToArray() }
}
$original.Dispose()

$out = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter $out
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($image in $images) {
    $dim = if ($image.Size -ge 256) { 0 } else { $image.Size }
    $writer.Write([byte]$dim); $writer.Write([byte]$dim); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$image.Bytes.Length); $writer.Write([uint32]$offset)
    $offset += $image.Bytes.Length
}
foreach ($image in $images) { $writer.Write($image.Bytes) }
$writer.Flush()
[System.IO.File]::WriteAllBytes($target, $out.ToArray())
Write-Host "已生成 $target（$($images.Count) 个尺寸）"
