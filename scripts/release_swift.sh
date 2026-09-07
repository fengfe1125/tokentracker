#!/usr/bin/env bash
# SwiftUI 版发布打包：dist/TokenTrackerSwift.app + dist/TokenTrackerSwift.dmg
#
# 本地构建（ad-hoc 签名，免安装依赖）。正式发行需要：
#   1. 开发者签名：CODESIGN_IDENTITY="Developer ID Application: …" \
#        scripts/release_swift.sh
#   2. 公证：准备好 AC_PASSWORD/APPLE_ID（或 notarytool keychain profile）后
#        xcrun notarytool submit dist/TokenTrackerSwift.dmg --wait
# 本脚本不自动公证（需要凭据），产物结构与公证就绪。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="0.2.2"

"$ROOT/scripts/build_swift_app.sh"

APP="$ROOT/dist/TokenTracker.app"
IDENTITY="${CODESIGN_IDENTITY:--}"   # 默认 ad-hoc
echo "==> 签名（$([ "$IDENTITY" = "-" ] && echo "ad-hoc" || echo "$IDENTITY")）"
codesign --force --sign "$IDENTITY" --options runtime "$APP"

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
