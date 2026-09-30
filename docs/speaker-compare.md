# 話者判定の再比較手順

録音の入力を保存し、本番の話者判定とフレーズ固定を同じ入力へ当て直す手順。判定を変えたときに、前後の結果を同じ入力で比べるために使う。

- 判定と固定の条件: [話者の割当と固定](speaker-assignment.md)
- 比較の対象はトークンへの話者の割当と補正だけ。ASR自体と話者判別モデルの出力は同じ入力を使う
    - 繰り返し相槌の省略は、比較でも replay でも無効にする。保存の `.md` とは違う場合がある
    - 手動の話者統合・速報と高精度の合流・小音量の除外は対象外
    - 行の区切り(同じ話者で1秒以上の無音)は補正ではない

## 入力を保存する

ASRを条件ごとに走らせ直すと、認識の試行差が補正の差に混ざる。1回の replay で入力を保存し、その保存物へ判定を当てる。

- `KIKIGAKI_TRIAL_DUMP=<dir>` で `<dir>/<会議名>/` へ書き出す。中身のある保存先は使わず、録音を始めない。DEBUGビルドだけで読む
    - `meta.json`: 流した速さ(`mic` / `replay-realtime` / `replay-accelerated`)と記録時の条件。島の補正の段階 `islands` を持つ
    - `final.json`: 停止時の全トークンと区間。時刻は丸めない
    - `live.jsonl`: 録音中の描画ごとの snapshot
        - 中身: 消費音声秒・壁時計・トークン・`finalCount`・`accurateFinalCount`・区間・`judgedUntil`・その描画でアプリが新しく凍結した話者
    - 会話本文を含むので、出力先はリポジトリ外の作業用ディレクトリに限る
- `KIKIGAKI_TRIAL_ALIGNER`・`KIKIGAKI_TRIAL_FREEZE`・`KIKIGAKI_TRIAL_ISLAND` は廃止した。指定すると録音を始めずに止める

### 試験用 .app を組む

起動中の通常の `.build/KIKIGAKI.app` には触れない。

```sh
KIKIGAKI_TRIAL=1 ./scripts/make-app.sh
```

- 出力は固定の `.build/trial/KIKIGAKI-Trial.app`。識別子 `com.tadashi-aikawa.kikigaki.trial`
    - UserDefaults・マイク許可が本体と別になる。初回にマイク許可を求められる
    - `kikigaki://` のリンクは受け付けない
- 試験用 `.app` は本体と並べて起動できる。終了はメニューバーの試験版から行う

### replay で記録する

設定は作業用ディレクトリに置き、AIを設定しない。

```toml
outputDir = "<作業用ディレクトリ>/meeting"
saveRecording = false
dropRepeatedBackchannels = false
```

```sh
APP=.build/trial/KIKIGAKI-Trial.app/Contents/MacOS/KIKIGAKI
KIKIGAKI_DEBUG_DIARIZATION=on KIKIGAKI_DEBUG_TYPED_VERIFY=1 KIKIGAKI_DEBUG_REPLAY_REALTIME=1 \
KIKIGAKI_TRIAL_DUMP=<作業用ディレクトリ>/dump \
  "$APP" --config <設定ファイル> --replay <音声ファイル>.wav
```

- `KIKIGAKI_DEBUG_TYPED_VERIFY=1` はAI登録先を保存先の中へ隔離するために付ける
- `KIKIGAKI_DEBUG_REPLAY_REALTIME=1` を外すと約10倍速。待ちの値は代表値にしない

### マイクで試す

`KIKIGAKI_TRIAL_DUMP` を付けて試験用 `.app` を起動する。会議ごとに別のディレクトリへ書く。

```sh
open -n .build/trial/KIKIGAKI-Trial.app --env KIKIGAKI_TRIAL_DUMP=<作業用ディレクトリ>/dump \
  --args --config <設定ファイル>
```

- `saveRecording = true` にすると、録音WAVを replay で流し直せる

## 比較する

DEBUG の `Kikigaki --align-compare` で行う。UIもモデルも起動しない。

```sh
.build/debug/Kikigaki --align-compare <作業用ディレクトリ>/dump/<会議名> --out <作業用ディレクトリ>/compare \
  --expect <開始秒>-<終了秒>=<枠> --names 0=司会,1=堀田,2=イチロー
```

- 引数: `[--out <dir>] [--source <名前>] [--expect <開始秒>-<終了秒>=<枠>]... [--names 0=司会,1=堀田] [--no-live]`
- 最終判定: 本番の判定を `final.json` へ当てる
- 録音中: 本番のフレーズ固定を、録音中の突き合わせループとして `live.jsonl` の上で再生する。`--no-live` で省く
    - 疑似試験との違い: 最終トークンを時刻順に流し直すのではなく、実際の録音中の速報・未確定を含む列を使う
- 出力: `comparison.md`・`comparison.json`・全文の `transcript.md`
- 検証
    - 高精度側の確定済み接頭辞が後の snapshot や停止時と食い違う記録は、比較をエラーにする
    - 記録時と同じ条件の再生が、アプリの実際の凍結列と全描画で一致するかを照合する。照合は `islands` が `cross` の記録だけで行う。これより前の記録は島の補正の採用前の判定で録っている
- 別のビルドとの差は、出力の全文 `transcript.md` を `diff` で比べる

## 測るもの

正解の無い差を精度と呼ばない。

| 区分 | 指標 |
|---|---|
| 最終判定 | 行数、話者切替数、断片行数、句読点だけの行数、不明の文字数、処理時間 |
| 正解あり | `--expect` で指定した区間で、指定の枠に付いた文字数 |
| 録音中 | 固定待ち: トークン終端から凍結までの音声秒。中央値・p90・最大 |
| | 確定待ち: トークン終端から高精度確定までの音声秒。凍結はこれより早くならない |
| | 未凍結のまま停止した件数と割合、そのうち確定済みで保留した件数 |
| | 停止時と不一致、凍結後の snapshot で判定し直すと変わった件数 |

- 待ちは音声秒で、文字起こしの確定待ちを含む。話者判別モデルの推論速度そのものではない
- 断片行: 有意文字1〜2字の行。相槌も含むので、多いこと自体を悪いとは断定しない
- 差分の本文には時刻を付け、原音で聞き分けられる形にする
- 加速の記録は描画が音声でほぼ5秒ごとになる。待ちの代表値は等倍の記録で測る
