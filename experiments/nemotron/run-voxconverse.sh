#!/bin/bash
# VoxConverse test の8話者ファイルで、現行 High Context と Nemotron 3 の2プリセットだけを比べる。
# 音声: Hugging Face の ggfox00000/dia-voxconverse-test (audio/test/<id>.wav、cc-by-4.0) のミラー
# 正解: 公式 joonson/voxconverse の master/test/<id>.rttm (v0.3)
# 注意: NVIDIA Nemotron 3 の公式モデルカードは VoxConverse v0.3 dev/test を学習データに挙げている。
#       8人の動作・出力確認と参考DERであり、未知データへの汎化や日本語会議の非劣化の証明ではない。
# 使い方: run-voxconverse.sh <id>...
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
vox=$here/work/voxconverse
models=$here/work/models
old=$here/baseline-0156/.build/release/Bench0156
new=$here/fa-0174/.build/release/Bench0174
mkdir -p "$vox" "$here/work/logs"
[ -d "$vox/repo" ] || git clone -q --depth 1 https://github.com/joonson/voxconverse.git "$vox/repo"
for id in "$@"; do
  wav=$vox/$id.wav
  [ -e "$wav" ] || curl -sfL -o "$wav" "https://huggingface.co/datasets/ggfox00000/dia-voxconverse-test/resolve/main/audio/test/$id.wav"
  out=$here/work/out/vox-$id
  mkdir -p "$out"
  log=$here/work/logs/vox-$id.log
  "$old" sortformer --wav "$wav" --variant high-context --out "$out/sort-0156-high.json" 2>>"$log"
  for v in fast128 fast32; do
    "$new" nemotron3 --wav "$wav" --variant "$v" --models "$models" --check-complete --out "$out/n3-$v.json" 2>>"$log"
  done
  "$here/compare.sh" "vox-$id" "$vox/repo/test/$id.rttm"
done
