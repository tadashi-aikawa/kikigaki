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
