#!/bin/bash
# 從原始碼建置 Apple Music DJ.app
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/Apple Music DJ.app"

echo "▸ 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 圖示"
if [ ! -f "$ROOT/app/Resources/AppIcon.icns" ]; then
  python3 "$ROOT/scripts/make-icon.py" || echo "  （沒有 Pillow，略過圖示）"
fi
[ -f "$ROOT/app/Resources/AppIcon.icns" ] && cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/"

echo "▸ Info.plist"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"

echo "▸ 編譯 Swift"
swiftc -O -parse-as-library "$ROOT"/app/AppleMusicDJ/*.swift \
  -o "$APP/Contents/MacOS/AppleMusicDJ" \
  -framework AppKit -framework SwiftUI \
  -target arm64-apple-macos13.0

echo "▸ 簽章（ad-hoc）"
codesign --force --deep -s - "$APP"

echo "✓ 完成：$APP"
