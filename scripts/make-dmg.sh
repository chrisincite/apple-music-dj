#!/bin/bash
# 打包成可分享的 DMG
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/app/Info.plist")"
DMG="$BUILD/AppleMusicDJ-$VERSION.dmg"

"$ROOT/scripts/build.sh" "$BUILD"

echo "▸ 準備 DMG 內容"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$BUILD/Apple Music DJ.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/DMG-README.txt" "$STAGE/先讀我.txt"

echo "▸ 建立映像檔"
hdiutil create -volname "Apple Music DJ" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGE"
echo "✓ 完成：$DMG"
ls -lh "$DMG"
