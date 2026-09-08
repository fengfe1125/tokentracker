#!/usr/bin/env bash
# SwiftUI 版打包 → dist/TokenTracker.app
# 保持既有 bundle id（Tahoe 的状态栏授权、登录项都跟 bundle id 走）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PKG="$ROOT/swift"
APP="$ROOT/dist/TokenTracker.app"
ENTITLEMENTS="$PKG/TokenTracker.entitlements"

# 版本号单一来源：TokenTrackerCore.version（设置页「关于」和更新检查读的也是它）
VERSION="$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' \
  "$PKG/Sources/TokenTrackerCore/TokenTrackerCore.swift")"
[ -n "$VERSION" ] || { echo "!! 解析不到 TokenTrackerCore.version" >&2; exit 1; }
echo "==> 版本 $VERSION"

echo "==> swift build -c release"
swift build -c release --package-path "$PKG"
BIN="$PKG/.build/release/TokenTrackerApp"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TokenTracker"
if [ -f "$ROOT/assets/icon.icns" ]; then
  cp "$ROOT/assets/icon.icns" "$APP/Contents/Resources/icon.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TokenTracker</string>
  <key>CFBundleDisplayName</key><string>TokenTracker</string>
  <key>CFBundleIdentifier</key><string>com.tokentracker.desktop</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>TokenTracker</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- 「在终端继续」要向 Terminal / iTerm 发 AppleEvent。没有这条 usage string，
       macOS 不弹授权框、直接拒绝（errAEEventNotPermitted / -1743），
       osascript 非 0 退出，UI 上表现为「终端打开失败，命令已复制到剪贴板」。
       走 open -na 的 WezTerm / Ghostty 不需要授权，所以旧版是「有时」失败。 -->
  <key>NSAppleEventsUsageDescription</key>
  <string>用于在你选择的终端里打开并恢复会话。</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 本地 ad-hoc 签名（带 automation entitlement）"
# 签名失败必须报错：entitlement 丢了「在终端继续」会静默退化成剪贴板降级
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"

echo ""
echo "✅ 完成：$APP (v$VERSION)"
echo "   运行：open dist/TokenTracker.app"
