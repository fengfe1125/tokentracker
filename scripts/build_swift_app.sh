#!/usr/bin/env bash
# SwiftUI 版打包（当前为 Phase 0 空壳）→ dist/TokenTrackerSwift.app
# 与 scripts/build_app.sh（Python 版）并存；Phase 5 再取代它。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PKG="$ROOT/swift"
APP="$ROOT/dist/TokenTracker.app"

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
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TokenTracker</string>
  <key>CFBundleDisplayName</key><string>TokenTracker</string>
  <key>CFBundleIdentifier</key><string>com.tokentracker.desktop</string>
  <key>CFBundleVersion</key><string>0.2.2</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>TokenTracker</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 本地 ad-hoc 签名"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "✅ 完成：$APP"
echo "   运行：open dist/TokenTracker.app"
