#!/bin/bash
# run.sh の出力を組にして比べ、要点をTSVで出す。詳細は work/cmp/<名前>/ のJSON
# 使い方: compare.sh <名前> [参照RTTM]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=$1 rttm=${2:-}
out=$here/work/out/$name
cmp=$here/work/cmp/$name
bench=$here/fa-0174/.build/release/Bench0174
mkdir -p "$cmp"

echo -e "label\tslots\tdetected\tload_s\tcompute_s\trtfx\tbuffer_s\twait_median_s\twait_max_s\tcached"
for f in "$out"/sort-*.json "$out"/n3-*.json; do
  [ -e "$f" ] || continue
  jq -r --arg f "$(basename "$f" .json)" '[$f, .slots, .speakersDetected, (.timing.loadSeconds*100|round/100),
    (.timing.computeSeconds*1000|round/1000), (.timing.rtfx|round), .configuredBufferSeconds,
    (.frameWait.median*100|round/100), (.frameWait.max*100|round/100), .timing.modelCachedBeforeRun] | @tsv' "$f"
done

echo
echo -e "A\tB\tref_spk\tref_turns\tB_spk\tB_turns\tmiss\tfa\tconf\tsingle_agree"
pairs=(
  "sort-0156-high sort-0174-high"
  "sort-0156-high n3-fast32"
  "sort-0156-fast n3-fast32"
  "sort-0156-balanced n3-fast32"
  "n3-fast32 n3-fast128"
  "n3-fast32 n3-low"
)
for p in "${pairs[@]}"; do
  read -r a b <<<"$p"
  [ -e "$out/$a.json" ] && [ -e "$out/$b.json" ] || continue
  "$bench" compare diar "$out/$a.json" "$out/$b.json" > "$cmp/$a--$b.json"
  jq -r --arg a "$a" --arg b "$b" '[$a, $b, ."referenceSpeakers(>=1s)", .referenceTurns, .B."speakers(>=1s)", .B.turns,
    .B.missRate, .B.falseAlarmRate, .B.confusionRate, .B.singleSpeakerAgreement] | @tsv' "$cmp/$a--$b.json"
done

if [ -n "$rttm" ]; then
  echo
  echo -e "hyp\tref_spk\thyp_spk\tmiss\tfa\tconf\tDER(自前集計)"
  for f in "$out"/sort-*.json "$out"/n3-*.json; do
    l=$(basename "$f" .json)
    "$bench" compare diar "$f" "$f" --ref-rttm "$rttm" > "$cmp/ref--$l.json"
    jq -r --arg l "$l" '[$l, ."referenceSpeakers(>=1s)", .A."speakers(>=1s)", .A.missRate, .A.falseAlarmRate,
      .A.confusionRate, .A."errorRate(miss+fa+conf)"] | @tsv' "$cmp/ref--$l.json"
  done
fi
