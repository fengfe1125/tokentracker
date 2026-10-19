# 发布 Windows 版：自包含（无需安装 .NET）单文件 exe，原生 DLL 放在 exe 旁边（不在启动时解压到 %TEMP%），
# 打包成 dist/TokenTracker-<版本>-win-x64.zip。版本号来自 swift/Sources/TokenTrackerCore/TokenTrackerCore.swift。
# 用法：pwsh windows/scripts/publish.ps1
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$project = Join-Path $repo 'windows\src\TokenTracker.Windows\TokenTracker.Windows.csproj'
$swift = Get-Content (Join-Path $repo 'swift\Sources\TokenTrackerCore\TokenTrackerCore.swift') -Raw
$version = [regex]::Match($swift, 'public static let version = "([^"]+)"').Groups[1].Value
if (-not $version) { throw '无法解析版本号' }

$staging = Join-Path $repo 'windows\artifacts\publish\TokenTracker'
$dist = Join-Path $repo 'dist'
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force $dist | Out-Null

dotnet publish $project -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=false -p:EnableCompressionInSingleFile=true `
    -p:DebugType=embedded -p:GenerateDocumentationFile=false -o $staging
if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败（$LASTEXITCODE）" }

$exe = Join-Path $staging 'TokenTracker.exe'
$product = (Get-Item $exe).VersionInfo.ProductVersion
if ($product -ne $version) { throw "exe 版本 $product 与 Swift 版本 $version 不一致" }

@"
TokenTracker $version for Windows

1. 解压到任意目录（例如 %LOCALAPPDATA%\Programs\TokenTracker），双击 TokenTracker.exe。
2. 首次运行若出现 SmartScreen「已保护你的电脑」：点「更多信息」→「仍要运行」。
   （当前版本未做代码签名；也可以在 zip 的「属性」里勾选「解除锁定」后再解压。）
3. 应用常驻在任务栏右下角托盘；关闭窗口不会退出，右键托盘图标选「退出 TokenTracker」。
   Windows 11 默认把新图标放进溢出区，可把它拖到任务栏上常显。

数据只在本机读取和保存：%USERPROFILE%\.tokentracker\usage.db
"@ | Set-Content -Path (Join-Path $staging 'README.txt') -Encoding UTF8

$zip = Join-Path $dist "TokenTracker-$version-win-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $staging -DestinationPath $zip
Write-Host "已生成 $zip"
