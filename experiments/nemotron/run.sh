#!/bin/bash
# 同じWAV・同じ区間を各エンジンへ1つずつ直列に流す(並列にすると計算時間が互いに干渉する)。
# 使い方: run.sh <名前> <wav> [start] [duration]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=$1 wav=$2 start=${3:-0} duration=${4:-}
out=$here/work/out/$name
models=$here/work/models
mkdir -p "$out" "$here/work/logs"
old=$here/baseline-0156/.build/release/Bench0156
new=$here/fa-0174/.build/release/Bench0174
range=(--wav "$wav" --start "$start")
[ -n "$duration" ] && range+=(--duration "$duration")

run() {
  local label=$1; shift
  echo "== $label" >&2
  "$@" --out "$out/$label.json" 2>>"$here/work/logs/$name.log"
}

# 基準線はアプリと同じ既定のモデル置き場を読む。0.17.4 は置き場を分け、アプリのキャッシュへ触れない
run sort-0156-high "$old" sortformer "${range[@]}" --variant high-context
run sort-0174-high "$new" sortformer "${range[@]}" --variant high-context --models "$models"
run sort-0156-balanced "$old" sortformer "${range[@]}" --variant balanced
run sort-0156-fast "$old" sortformer "${range[@]}" --variant fast
for v in fast32 fast128 low; do
  run "n3-$v" "$new" nemotron3 "${range[@]}" --variant "$v" --models "$models" --check-complete
done
