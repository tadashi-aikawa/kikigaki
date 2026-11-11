# 画面の記録の独立試作

macOS 26以降のSwiftPM CLI。依存はlibwebpの静的同梱だけ。本体へ入れる前に、撮る契機のしきい値・負荷・WebPの読みやすさ・題の取り方・許可の挙動を測る。

- 設計: owlery Vaultの「KIKIGAKI 会議中の画面の記録の設計方針案 2026-11-09」
- 記録: [画面の記録の試作の検証記録](../../docs/records/screen-capture-spike.md)
- 録画・ログ・合成の結果は `work/` に置く
  - 保存範囲: gitで無視される。検証した手元だけの証拠

## ビルドと基本操作

```bash
# リポジトリルートから実行する
cd experiments/screen-capture
swift build -c release
.build/release/ScreenCaptureProbe self-check
.build/release/ScreenCaptureProbe displays
```

- 判定の速さを測るので、`-c release` で組む
- `displays` は番号・名前・寸法・倍率・メニューバーの高さと、この実行の帰属先に画面収録の許可があるかを出す
  - 端末から実行すると、許可は端末アプリに帰属する

## 判定のしくみ

`ChangeDetector` が設計案の2つの判定を、比べる相手を分けて行う。

- 落ち着き: 直前の観測フレームと比べて変わったマスの割合が `motion` を超えたら「動いている」。超えない状態が `settle` 秒続いたら「落ち着いた」
- 保存する価値: 落ち着いている間の最新フレームが、最後に保存した画像と `save` を超えて違えば保存する
- マス: 画面を横 `width` マスの輝度画像へ単純平均で縮め、1マスの差が `cell` を超えたら変わったとみなす
- メニューバー: 時計の分が変わるたびに保存しないよう、メニューバーの高さを比較から外す
- 保存する画像は観測時刻のもの。保存を決めた時刻ではない
- 最初のフレームと、撮れない期間から戻った最初のフレームは待たずに保存する
- 既定値は検証記録の初期値。`watch` をオプションなしで実行すると記録と同じ判定になる
- 試して初期値に入れなかった判定: 外すマス
  - 中身: 直近 `volatile` 秒に `vcount` 回以上変わったマスを両方の比較から外し、`release` 秒変わらなくなるまで外し続ける。直前との差が `vlimit` を超えたフレームは回数に数えない
  - 既定: `volatile` 0で外さない。理由は検証記録

## しきい値を当て直す

```bash
# 正解の分かる会議画面を合成する(1秒ごとの観測を、位相をずらして3本)
.build/release/ScreenCaptureProbe synth --out work/meet-1080
.build/release/ScreenCaptureProbe synth --out work/meet-uw --size 3840x1600 --phases 0,0.5
# 小さく動き続けるだけの画面を10分。1時間あたりの余分を見積もる
.build/release/ScreenCaptureProbe synth --out work/noise-1080 --scenario noise --phases 0,0.5

# 総当たり。取りこぼしが少ない順、同じなら余分が少ない順に出す
.build/release/ScreenCaptureProbe sweep work/meet-1080/phase{0,1,2} work/noise-1080/phase{0,1} \
  --width 128,256 --cell 8,16 --motion 0.0002,0.0005 --save 0.0005,0.001,0.002 \
  --settle 1.5 --top 0.0223 --volatile 0,6 --vcount 3 --release 10 --vlimit 0.02,0.05
# 1つの組の内訳。初期値の組
.build/release/ScreenCaptureProbe sweep work/meet-1080/phase0 --width 128 --cell 8 --motion 0.0002 --save 0.001 --settle 1.5 --top 0.0223 --detail --show 1
```

- 筋書きと正解は `Synth.swift` の冒頭
- `--snapshots 10,45` で、その秒の合成画面をWebPで残す。絵を目で確かめるときに使う
- `watch` の記録も同じ形なので、実画面の観測にもしきい値を当て直せる。実画面には正解が無いので、保存の時刻だけを出す

## 動き続ける画面と交互に変わる画面

2026-11-11に足した規則の案と筋書き。結果は [動き続ける画面と交互に変わる画面の規則の試作の検証記録](../../docs/records/screen-motion-alternation.md)。

- 案P 直近に保存した画面と比べる: `--recent-count`(1で使わない、0で枚数を絞らない) `--recent-seconds` `--recent-extend 0,1` `--recent-same` `--recent-mask <割合>`
  - `--recent-mask` は、案Qの今の外すマスを掛けて比べる上限。外すマスが、比較に使うマスのこの割合以下のときだけ掛ける。0なら掛けない
    - 推すのは0.5。実画面の記録で足した。経緯は検証記録の「実画面の記録」
  - `--recent-same` は変わったマスの割合。マスの判定は `--cell` を使うので、`0.000001` は「全マスの輝度の差が8以下」で、厳密な一致ではない
  - `--recent-exact 1` は縮小画像の輝度が全マスで一致するときだけ同じとみなす。比べる値の確認用
- 案Q 動き続けたら1枚撮り、動くマスを外す: `--moving <秒>` `--mask-window <秒>`(-1で `--moving` と同じ。推すのは10) `--mask-count` `--mask-release` `--mask-grow` `--mask-box 0,1`
  - `--mask-regional 0,1`: 外したマスをつながりごとに戻す
  - `--mask-broad <割合>`: 広い差のフレームでの1度だけの変化を候補から除く。測って入れなかった
  - `--mask-novel 0,1`: 外したマスでも、動く間に見なかった明るさで落ち着いたマスは比べる。測って入れなかった
  - `--mask-after-broad <割合>`: 外す候補を、直前との差がこの割合を超えた最後のフレームより後の観測だけで数える。測って入れなかった
  - `--moving-same 0,1,2`: 強制で保存する時点で、動いている所を除けば最後に保存した画像と同じなら、保存せずに外すマスだけを確定する。同じ画面の直近の画面は最後に見た時刻を延ばす
    - 試して入れなかった。推す組は0で、本体も入れていない。どの形も、足した注記を取りこぼす反例が出た。経緯は検証記録の「保存を省く経路をやめた」
    - 0: 当てない。1: いつも当てる。2: 外しているマスが無いときだけ当てる
    - 動いている所の上限は `--recent-mask` と同じ値を使う
  - `--moving-same-repeat <回>` `--moving-same-grow <マス>` `--moving-same-box 0,1`: 保存を省く判定で除く、動いている所の決め方。`--moving-same` を付けたときだけ効く
    - repeat 0: 外す候補をそのまま除き、差が `--save` 以下なら省く
    - repeat 1以上: 直近 `--mask-window` 秒にこの回数以上変わったマスを grow マス広げ、box なら長方形で囲む。その外が全く同じときだけ省く
  - 外すマスは、撮った1枚の保存に成功してから確定する。`sweep` は決定のたびに成功を返し、`--fail-every k` で k 回に1回を失敗として返す
    - 例外: `--moving-same` を付けると、保存せずにその場で確定することがある。推す組には付けない
- 案R 動き続ける間は一定の間隔で撮る: `--moving <秒> --mask-window 0`
- 筋書き: `--scenario anim|pages|switch|video|alternate|return|mixed|send|wake|note`。中身と正解と数え方は `SynthMotion.swift` の冒頭
  - `wake` は、動く画像のスライドを映したまま録音を始める場面と、止まっていた動く画像が動き出す場面。実機確認で出た1件を写した
    - 推す組では、開始から映す区間で3枚、動き出した区間で1枚を撮り、正解の枠に対して余分になる。受け入れた限界
  - `note` は、動く画像の隣に静止した注記が足される場面。注記の入った1枚を撮らなければ取りこぼし
  - `mixed` は、動く画像と入れ替わる図が同じスライドにある場面。実画面の記録 `real-obs-01` の13ページを写した
  - `send` は、静止したスライドから1回送って `mixed` と同じスライドへ着く場面。送る何秒前から画面が動き始めるかを、区間ごとに0〜7秒で変える
    - 送った後の区間は、図の2つの絵の両方を要る枚数にした。1枚なら取りこぼし1
- `--interval min1`: 観測の間隔を1.0〜1.4秒にする。既定の揺らし方は0.6〜1.4秒
- 出力
  - 1行に、取りこぼし・余分(うち交互の再保存)・途中の保存・戻りの拾い・最初の保存までの遅れ・保存を出す
  - `--groups` は筋書きごと、`--summary` は記録ごと、`--label 文字` はその文字を含む区間の結果を合否によらず出す
  - `--detail` の保存は `観測の時刻[印]#フレームの番号@保存を決めた時刻`。印の `m` は動き続けて撮った1枚、`f` は最初の1枚
    - フレームの番号は、`watch --keep-all` の `all/` の画像名の先頭の番号と同じ
  - 遅れの平均と最大は保存できた区間だけで数え、`測れた区間 n/m` を添える
- `PROBE_DEBUG=1` を付けると、次を出す
  - 案Pが保存を止めた時刻
  - 落ち着いて撮った1枚の、基準との差の場所
  - 案Qの外すマスを確定した時刻と、つながりごとのマスの数と場所。戻した時刻
  - マスの場所は縮小画像の座標。幅128なら x は0〜127

```bash
W=work/r10
P=.build/release/ScreenCaptureProbe
# 筋書きごとに、1920×1080を3本、横長に等倍の文字を2本、観測の間隔を1秒以上にしたものを2本
for s in meeting noise anim pages switch video alternate return mixed send wake note; do
  g=$s; [ $s = meeting ] && g=meet; [ $s = alternate ] && g=alt; [ $s = return ] && g=ret; [ $s = mixed ] && g=mix
  ph=0,0.37,0.71; [ $s = noise ] && ph=0,0.5
  $P synth --out $W/$g-1080 --scenario $s --phases $ph
  $P synth --out $W/$g-uw1 --scenario $s --size 3840x1600 --unit 1 --phases 0,0.5
  $P synth --out $W/$g-1080m1 --scenario $s --phases 0,0.5 --interval min1
done
# 第0フェーズと同じ、大きな画面に同じ見た目を拡大したもの
$P synth --out $W/meet-uw --scenario meeting --size 3840x1600 --phases 0,0.5
$P synth --out $W/noise-uw --scenario noise --size 3840x1600 --phases 0,0.5

S=($(ls -d $W/*/phase*))
C=(--width 128 --cell 8 --motion 0.0002 --save 0.001 --settle 1.5 --top 0.0223)
PP=(--recent-count 0 --recent-seconds 12 --recent-same 0.000001 --recent-mask 0.5)
P0=(--recent-count 0 --recent-seconds 12 --recent-same 0.000001)
# 案Qの土台。外す候補を集める秒数を除いたもの。振るときは後ろに足す
QB=(--moving 12 --mask-count 1 --mask-release 3 --mask-box 1 --mask-grow 1 --mask-regional 1)
# 推す組。本体と同じ決定を出す
Q=($QB --mask-window 10)
# 試して入れなかった、保存を省いて外すマスだけを確定する形の比べ方
# --moving-same は0が入れない形、1がいつも当てる、2が外していないときだけ。--moving-same-repeat 0 は外す候補で同じかを決める形
$P sweep $S $C $PP $QB --mask-window 10 --moving-same 0,1,2 --moving-same-repeat 0,2 --moving-same-grow 1 --moving-same-box 1 --groups
# 外す候補を集める秒数。-1 は --moving と同じ12秒
$P sweep $S $C $PP $QB --mask-window -1,10,8,6 --groups
# send の区間ごとの枚数。1行が1本で、並びは送る0・0.25・0.5・0.75・1・1.5・2・3・4・5・6・7秒前から動く区間
for w in -1 10 8 6; do echo "== $w"; for f in $(ls -d $W/send-*/phase*); do
  $P sweep $f $C $PP $QB --mask-window $w --label 動いた後 | grep '^  \[' | tr '/' '\n' | grep -o '保存[0-9]* 期待' | grep -o '[0-9]*' | tr '\n' ' '; echo
done; done
# 初期値と各案の表。P0 は外すマスを掛けない案P
# 記録の前の表は、そのときの組で測った。案Qは --mask-window -1
$P sweep $S $C --groups
$P sweep $S $C $P0 --groups
$P sweep $S $C $Q --groups
$P sweep $S $C --moving 20 --mask-window 0 --groups
$P sweep $S $C $P0 $Q --groups
$P sweep $S $C $PP $Q --groups
$P sweep $S $C $P0 --moving 15,20,25 --mask-window 0 --groups
# 保存の多さ: 通知の出る動く画像・会議の動画の再生中・全画面の動画の枚数
$P sweep $S $C $PP $Q --label "A13,S7 動画の再生中,V2 全画面"
# 外すマスを掛ける上限。全画面の動画の後の戻りで、上限が要ることを見る
$P sweep $(ls -d $W/video-*/phase*) $C $Q --recent-count 0 --recent-seconds 12,20,30 --recent-same 0.000001 --recent-mask 0,0.5,1 --show 20
# 案Pの秒数と「同じ」の差
$P sweep $S $C $Q --recent-count 0 --recent-seconds 10,11,12,15,20 --recent-same 0,0.000001 --show 20
# 案Qの形
$P sweep $S $C --moving 8,10,12,15 --mask-window -1 --mask-count 1 --mask-release 3,5 --mask-box 1 --mask-grow 0,1 \
  --mask-broad 0,0.05 --mask-regional 0,1 --mask-novel 0,1 --show 40
# 外す候補を広い差のフレームより後に絞る形
$P sweep $S $C $PP $Q --mask-after-broad 0,0.02,0.05,0.2 --groups
# 保存の失敗を混ぜる
$P sweep $S $C $P0 --recent-mask 0,0.5 $Q --fail-every 5
```

- 最初の総当たりは `work/r9` に出した。`mixed` を足した後は `work/r10` に全部を作り直し、数字が同じことを確かめた

- シェルはzshを前提にしている。`$S` などを配列で渡す

保存済みの画面の記録(`<会議名>.captures/`)にも当て直せる。読み取りだけで、元のフォルダには書かない。

```bash
.build/release/ScreenCaptureProbe import-captures ~/Documents/KIKIGAKI/2026-11-11_0756.captures --out work/r9/real-0756
.build/release/ScreenCaptureProbe sweep work/r9/real-0756 --width 128 --cell 8 --motion 0.0002 --save 0.001 --settle 1.5 --top 0.0334 \
  --recent-count 1,0 --recent-seconds 12 --recent-same 0.000001 --detail
# 保存した画像どうしの差。圧縮の差で同じ画面を外さないかを見る
.build/release/ScreenCaptureProbe pair-diff ~/Documents/KIKIGAKI/2026-11-11_0756.captures --top 0.0334
```

- `import-captures`: 保存した画像を保存の順に1枚ずつ観測として並べる。時刻はファイル名の HHmmss
  - 同じ秒の連番 `_2` `_10` は数で並べ、その秒の中に等間隔で置く。翌秒の画像より後にしない
  - 日付をまたぐ記録は扱わない。名前の順と書き込みの時刻の順が食い違ったら止める
  - 限界: 保存しなかった観測は残っていないので、落ち着きと案Qは当て直せない。実機で確かめるときは、次の `watch --keep-all` の `frames.jsonl` を `sweep` に渡す
- `--top 0.0334`: 内蔵Retina(1800×1169pt)のメニューバー39pt。`displays` で確かめた

## 実画面の観測のログで決める

案Pと案Qの採否を、保存しなかった観測も含むログで決める。採るのはタダシで、画面収録の許可が要る。端末から実行すると、許可は端末アプリに帰属する。

### 採る(タダシ)

1. 組む

   ```bash
   swift build -c release --package-path /private/tmp/kikigaki-screen-lane/experiments/screen-capture
   ```

2. 映すディスプレイの番号を確かめる。KIKIGAKIの会議で選ぶのと同じディスプレイにする

   ```bash
   /private/tmp/kikigaki-screen-lane/experiments/screen-capture/.build/release/ScreenCaptureProbe displays
   ```

3. 10分監視する。`--display` に2で確かめた番号を渡す。例は内蔵ディスプレイの1。出力先は毎回新しくする

   ```bash
   /private/tmp/kikigaki-screen-lane/experiments/screen-capture/.build/release/ScreenCaptureProbe watch --display 1 --seconds 600 --keep-all --out /private/tmp/kikigaki-screen-lane/experiments/screen-capture/work/real-obs-01
   ```

4. 監視の間に、話しながら次の順で映す。秒数はおおよそでよい。無い場面は飛ばす

   | ステップ | 映すもの | おおよその長さ | 期待の枚数 |
   | --- | --- | --- | --- |
   | 1 | 静止したスライド | 30秒 | 1 |
   | 2 | 自動で入れ替わるスライド(KIKIGAKI紹介の14ページなど) | 60秒 | 入れ替わる画面の数 |
   | 3 | 別のスライドへ送り、約5秒後に2へ戻ってすぐ送る | 15秒 | 戻った画面は案Pで0、初期値で1 |
   | 4 | 別のスライドへ送り、約30秒話してから2へ戻る | 45秒 | 戻った画面も1 |
   | 5 | GIFや動画の入ったスライド | 40秒 | 1 |
   | 6 | 動く枠の中にだけ注記が出る場面 | 30秒 | 注記の前後で各1 |
   | 7 | 全画面の動画 | 60秒 | 1以上。何枚までよいかはタダシが決める |
   | 8 | 静止したスライド | 30秒 | 1 |

5. 終わったら、次だけを控えて伝える。時刻は控えなくてよい。`all/` の画像から読む
   - 飛ばしたステップ
   - 3と4で戻った回数
   - 2で入れ替わっていた画面の数
   - 6で注記を出した回数

- 監視はKIKIGAKIのウィンドウを撮らない。KIKIGAKIで録音しながらでも、しなくてもよい

### 当て直す(進行役)

```bash
D=/private/tmp/kikigaki-screen-lane/experiments/screen-capture/work/real-obs-01
P=/private/tmp/kikigaki-screen-lane/experiments/screen-capture/.build/release/ScreenCaptureProbe
# 監視したディスプレイのメニューバーを外す割合。開始の行の top
T=$(grep '"start"' $D/events.jsonl | sed 's/.*"top":"\([0-9.]*\)".*/\1/')
C=(--width 128 --cell 8 --motion 0.0002 --save 0.001 --settle 1.5 --top $T)
Q=(--moving 12 --mask-window 10 --mask-count 1 --mask-release 3 --mask-box 1 --mask-grow 1 --mask-regional 1)
PP=(--recent-count 0 --recent-seconds 12 --recent-same 0.000001 --recent-mask 0.5)
P0=(--recent-count 0 --recent-seconds 12 --recent-same 0.000001)
$P sweep $D $C --detail                                  # 初期値
$P sweep $D $C $PP $Q --detail                           # 推す組
$P sweep $D $C $P0 $Q --detail                           # 外すマスを掛けない案Pとの組
$P sweep $D $C $P0 --moving 15,20 --mask-window 0 --detail  # 案R
$P sweep $D $C $Q --recent-count 0 --recent-seconds 8,12,20,30 --recent-same 0.000001 --recent-mask 0.5 --detail  # 案Pの秒数
# 外すマスの確定と戻し、保存の理由と差の場所
PROBE_DEBUG=1 $P sweep $D $C $P0 $Q | grep -E '\[Q\]|\[保存\]'
# real-obs-01 の場面ごとの枚数。区切りの秒と名前は検証記録の「実画面の記録」の場面の表
scenes() {
  $P sweep $D $C "$@" --detail | grep '保存:' | sed 's/.*保存: //' | tr ' ' '\n' | sed 's/[mf]*#.*//' | awk '
  BEGIN { n = split("0 40 46.07 122.32 128.12 131.97 168.14 224.17 241.52 249.2 313.2 316.4 9999", b, " ")
          split("1静止 送り 2の13頁 3の14頁 3の戻り 4の14頁 4の13頁 5の12頁 途中 7動画 途中 8静止", l, " ") }
  { for (i = 1; i < n; i++) if ($1 >= b[i] && $1 < b[i + 1]) c[i]++ }
  END { for (i = 1; i < n; i++) printf "%s=%d ", l[i], c[i]; print "" }'
}
scenes                     # 初期値
scenes $P0 $Q              # 外すマスを掛けない案Pとの組
scenes $PP $Q              # 推す組
```

- `--detail` のフレームの番号で `$D/all/` の画像を開き、ステップごとの枚数をタダシの控えと突き合わせる
- 合成と違って正解が無いので、取りこぼしと余分は人が数える
- 2026-11-11の `real-obs-01` は、元のリポジトリの `experiments/screen-capture/work/real-obs-01` にある。`D` をそこへ向ける
  - 場面の区間と、場面ごとの数え方は検証記録の「実画面の記録」

## 本体の判定器と突き合わせる

本体の `ScreenChangeDetector` は、試作の判定器の推す組と同じ入力で同じ決定を出す。`Tests/KikigakiCoreTests/ScreenChangeReplayTests.swift` が、観測の列を両方へ流して固定する。

リポジトリに置くのは合成の筋書きの3本だけ。

```bash
P=/private/tmp/kikigaki-screen-lane/experiments/screen-capture/.build/release/ScreenCaptureProbe
F=/private/tmp/kikigaki-screen-lane/Tests/KikigakiCoreTests/Fixtures
# 合成の筋書き。外すマスの漏れの出る mixed、保存の結果を遅らせると起点の違いが出る mixed-phase1、ポインタや止まる動く画像の出る anim
$P export-replay work/r10/mix-1080m1/phase0 --top 0.0223 --out $F/screen-replay-mixed.json
$P export-replay work/r10/mix-1080/phase1 --top 0.0223 --out $F/screen-replay-mixed-phase1.json
$P export-replay work/r10/anim-1080/phase0 --top 0.0223 --out $F/screen-replay-anim.json
# 本体で当てる
swift test --package-path /private/tmp/kikigaki-screen-lane --filter ScreenChangeReplayTests
```

実画面の記録は、手元で書き出して環境変数で渡す。リポジトリには置かない。

- 理由: 公開リポジトリで、書き出したファイルは利用者の画面に映ったものの縮小画像を含む
- 書き出し先は `work/` の下にする。gitで無視される

```bash
P=/private/tmp/kikigaki-screen-lane/experiments/screen-capture/.build/release/ScreenCaptureProbe
L=/private/tmp/kikigaki-screen-lane/experiments/screen-capture/work/r10/screen-replay-real-obs-01.json
# --top は記録の events.jsonl の開始の行の値を読む
$P export-replay ~/git/github.com/tadashi-aikawa/kikigaki/experiments/screen-capture/work/real-obs-01 --out $L
KIKIGAKI_SCREEN_REPLAY_FIXTURE=$L swift test --package-path /private/tmp/kikigaki-screen-lane --filter ScreenChangeReplayTests
```

- 環境変数を渡すと、試作と同じ時刻に同じ理由で保存を決めるかを確かめる。real-obs-01 なら、保存が12枚で、13ページの2回の区間がどちらも1〜2枚かも確かめる
- 渡さなければ、手元の記録のテスト2件は飛ばす

- `export-replay`: 縮小画像を幅128へ縮めた輝度と、観測・idle・撮れない期間・終わりの時刻だけを書き出す。画像そのものは書かない
  - 輝度は全フレームをつないでlzmaで縮める。実画面の記録で約470KB、合成の3本で約190KB
  - 期待の決定は、推す組の値で試作の判定器に当てた結果。値は `ReplayExport.swift` の `recommended`
  - 決定の3回に1回を保存の失敗として返したときの決定も書く。本体の失敗の扱いが試作と一致するかを見る

保存の結果を遅らせて返したときに、試作の決定と食い違う数を、起点の形ごとに測る。手元で多くの筋書きを書き出し、ディレクトリを渡す。

```bash
mkdir -p work/r10/replay
for s in send-1080/phase0 send-1080/phase1 send-1080/phase2 video-1080/phase0 video-1080m1/phase0 alt-1080/phase0 ret-1080/phase0 \
  pages-1080/phase0 switch-1080/phase0 meet-1080/phase0 mix-1080/phase0 mix-1080/phase1 mix-uw1/phase0 anim-1080/phase1 anim-uw1/phase0 noise-1080/phase0; do
  $P export-replay work/r10/$s --top 0.0223 --out work/r10/replay/$(echo $s | tr / -).json
done
KIKIGAKI_SCREEN_REPLAY_DIR=$PWD/work/r10/replay swift test --package-path /private/tmp/kikigaki-screen-lane --filter 手元の観測の列で保存の完了の遅れ
```

- 出力は `[遅れ]` の行。デバッグビルドで約10分かかる
- 結果は [画面の記録](../../docs/screen-capture.md) の「動き続ける画面」
- 試作の判定器を変えて本体と食い違ったら、どちらに合わせるかを決めてから書き出し直す

## 実画面を監視する

```bash
.build/release/ScreenCaptureProbe watch --display EV3895 --seconds 300 --out work/real-01 --keep-all
.build/release/ScreenCaptureProbe windows --display EV3895 --seconds 60
```

- `watch` は選んだディスプレイのSCStreamを1x寸法・1秒間隔・カーソル無しで開く
  - 除外: KIKIGAKI(`com.tadashi-aikawa.kikigaki`)と自分。`--exclude-bundle` で変える
  - 出力: `frames.jsonl` に観測の縮小画像、`events.jsonl` に保存・負荷の標本・異常、`captures/` に保存した画像
  - `--keep-all`: 観測した全フレームを `all/` に残す。取りこぼしを人が数えるときに使う
  - `--no-write`: 符号化まで行い、画像も縮小画像も書かない。負荷だけを測るときに使う
  - 終わりに、監視開始からのCPU時間と使用率、約5秒ごとの標本で最大のメモリ、縮小と符号化の時間、1枚の容量を出す
  - 判定の値は `--width` `--cell` `--motion` `--save` `--settle` `--volatile` で変えられる。既定は初期値
- `windows` は設計案の題の取り方で、対象ディスプレイの最前面のウィンドウを1秒ごとに出す。実際の前後関係と人が見比べる
- `encode <画像> --scale 0.5 --out x.webp` は、Retinaの2x画像を1xへ縮めたWebPを作る。文字の読みやすさを見る

## 独立.appと許可

端末から実行すると、許可は端末アプリに帰属する。本体と同じ自己署名証明書 `kikigaki-dev` での挙動は、独立.appで見る。

```bash
bash build-app.sh
open -W -n "$PWD/work/ScreenCaptureProbe.app" --args permission --wait 120 --out "$PWD/work/perm-01"
cat work/perm-01/permission.log
```

- 許可ダイアログは人が操作する
  - 設定先: システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音
- `permission` は、起動時の確認・要求の結果と、許可されるまで1秒ごとに取得を試した結果を `permission.log` に書く
  - 同じプロセスのまま撮れるようになるかで、許可の後に再起動が要るかを見る
  - 撮れたら対象ディスプレイを1枚 `check.webp` に残す
- `bash build-app.sh --without-usage` は `NSScreenCaptureUsageDescription` を外した別のbundle IDの.appを組む
  - 限界: 実行ファイルに埋めた `__info_plist` には説明文が残る。.appとして起動したときに読まれるのはバンドルの `Info.plist`
- bundle ID: `com.tadashi-aikawa.kikigaki.screen-capture-probe`。本体の許可とは分かれる
