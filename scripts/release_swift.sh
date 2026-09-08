#!/usr/bin/env bash
# SwiftUI 版发布打包：dist/TokenTracker.app + dist/TokenTracker-<version>.dmg
#
# 本地构建（ad-hoc 签名，免安装依赖）。正式发行需要：
#   1. 开发者签名：CODESIGN_IDENTITY="Developer ID Application: …" \
#        scripts/release_swift.sh
#   2. 公证：准备好 AC_PASSWORD/APPLE_ID（或 notarytool keychain profile）后
#        xcrun notarytool submit dist/TokenTracker-<version>.dmg --wait
# 本脚本不自动公证（需要凭据），产物结构与公证就绪。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# 版本号单一来源：TokenTrackerCore.version（build_swift_app.sh 写进 Info.plist 的也是它）
VERSION="$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' \
  "$ROOT/swift/Sources/TokenTrackerCore/TokenTrackerCore.swift")"
[ -n "$VERSION" ] || { echo "!! 解析不到 TokenTrackerCore.version" >&2; exit 1; }

"$ROOT/scripts/build_swift_app.sh"

APP="$ROOT/dist/TokenTracker.app"
ENTITLEMENTS="$ROOT/swift/TokenTracker.entitlements"
IDENTITY="${CODESIGN_IDENTITY:--}"   # 默认 ad-hoc
echo "==> 签名（$([ "$IDENTITY" = "-" ] && echo "ad-hoc" || echo "$IDENTITY")）"
# --options runtime 开了 hardened runtime，向 Terminal / iTerm 发 AppleEvent
# 必须带 com.apple.security.automation.apple-events，否则「在终端继续」会被拒
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$ENTITLEMENTS" "$APP"

DMG="$ROOT/dist/TokenTracker-$VERSION.dmg"
echo "==> 制作 $DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "TokenTracker" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo ""
echo "✅ 完成："
echo "   App:  $APP"
echo "   DMG:  ${DMG}（$(du -sh "$DMG" | cut -f1)）"
echo "   公证：xcrun notarytool submit \"$DMG\" --keychain-profile <profile> --wait"
