#!/bin/bash
# 人が許可する検証用の独立.appを組む。ここでは撮影を開始しない。
# 使い方: bash build-app.sh [--without-usage]
#   --without-usage: NSScreenCaptureUsageDescription を外した別のbundle IDの.appを組む。説明文の要否を見る
# 端末から直接実行するとTCCの帰属先が端末になるため、.appは open で起動する。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
swift build -c release
name=ScreenCaptureProbe
id=com.tadashi-aikawa.kikigaki.screen-capture-probe
if [ "${1:-}" = "--without-usage" ]; then
  name=ScreenCaptureProbeNoUsage
  id=com.tadashi-aikawa.kikigaki.screen-capture-probe-no-usage
fi
app="$here/work/$name.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/ScreenCaptureProbe "$app/Contents/MacOS/ScreenCaptureProbe"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" -c "Set :CFBundleName $name" "$app/Contents/Info.plist"
if [ "${1:-}" = "--without-usage" ]; then
  /usr/libexec/PlistBuddy -c "Delete :NSScreenCaptureUsageDescription" "$app/Contents/Info.plist"
fi
codesign --force --timestamp=none --sign kikigaki-dev --identifier "$id" "$app"
codesign --verify --strict --verbose=2 "$app"
echo "$app"
