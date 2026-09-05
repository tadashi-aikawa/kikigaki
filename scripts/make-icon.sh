#!/usr/bin/env bash
# Resources/kikigaki.png から配布用の全サイズを含む .icns を生成する。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/kikigaki.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "${ICONSET%/*}"' EXIT

for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/Resources/kikigaki.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/Resources/kikigaki.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/kikigaki.icns"
echo "Generated: $ROOT/Resources/kikigaki.icns"
