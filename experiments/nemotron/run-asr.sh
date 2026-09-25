#!/bin/bash
# 文字起こしを同じWAV・同じ区間で直列に流す。
# 使い方: run-asr.sh <名前> <wav> [start] [duration] [realtime_duration]
#   realtime_duration を付けると、先頭からその秒数だけ Apple の速報+高精度を等倍で流す(遅れの計測用)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=$1 wav=$2 start=${3:-0} duration=${4:-} realtime=${5:-}
out=$here/work/out/$name
models=$here/work/models
mkdir -p "$out" "$here/work/logs"
new=$here/fa-0174/.build/release/Bench0174
range=(--wav "$wav" --start "$start")
[ -n "$duration" ] && range+=(--duration "$duration")

run() {
  local label=$1; shift
  echo "== $label" >&2
  "$@" --out "$out/$label.json" 2>>"$here/work/logs/$name.log"
}

run asr-nemotron-2240 "$new" asr-nemotron "${range[@]}" --chunk-ms 2240 --language ja-JP --models "$models"
run asr-apple "$new" asr-apple "${range[@]}"
run asr-apple-dual "$new" asr-apple "${range[@]}" --with-fast
if [ -n "$realtime" ]; then
  run asr-apple-dual-rt "$new" asr-apple --wav "$wav" --start "$start" --duration "$realtime" --with-fast --realtime
  run asr-nemotron-2240-rt-range "$new" asr-nemotron --wav "$wav" --start "$start" --duration "$realtime" --chunk-ms 2240 --language ja-JP --models "$models"
fi
