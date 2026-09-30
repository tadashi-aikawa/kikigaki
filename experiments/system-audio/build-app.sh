#!/bin/bash
# 人が許可する次回検証用。ここでは録音を開始しない。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
swift build
app="$here/work/SystemAudioProbe.app"
mkdir -p "$app/Contents/MacOS"
cp .build/debug/SystemAudioProbe "$app/Contents/MacOS/SystemAudioProbe"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign kikigaki-dev --identifier com.tadashi-aikawa.kikigaki.system-audio-probe "$app"
codesign --verify --strict --verbose=2 "$app"
codesign -d -r- "$app"
echo "$app"
