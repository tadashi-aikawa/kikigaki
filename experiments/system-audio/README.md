# システム音声取り込みの独立試作

macOS 26以降のSwiftPM CLI。外部依存はない。

実現性の検証は完了した。内蔵・USB・BluetoothイヤホンのマイクとOWS 2出力で、同一aggregateによる同時取り込みを確認した。

- 記録: [システム音声取り込みの実現性試作の検証記録](../../docs/records/system-audio-spike.md)。
- 本実装の決定: 音量を揃えて混ぜた1本を既存パイプラインへ渡す。
  - 制約: この試作は固定0.5倍の混合のみ。音量を揃える処理は未実装。
- 録音・ログ・replay結果は`work/`に置く。
  - 保存範囲: gitで無視されるため、検証した手元だけの証拠。

## ビルドと基本操作

```bash
# リポジトリルートから実行する
cd experiments/system-audio
swift build
.build/debug/SystemAudioProbe self-check
.build/debug/SystemAudioProbe devices
.build/debug/SystemAudioProbe processes
.build/debug/SystemAudioProbe inspect ~/work/fluidaudio-sandbox/samples/dialog2.wav
```

- 保存する音声は16kHz mono Float32。
  - システムのみ: `system.wav`
  - マイク併用: `system.wav`、`mic.wav`、`mixed.wav`
- `capture.log`にAPI結果・出力デバイス変化・レベル・タイムスタンプの欠落数を記録する。
  - 形式診断: aggregate公称レート、各streamの形式、初回IOProcのchannel数・byte数・フレーム数、全callbackのフレーム数範囲、時刻からの実測レート。
- `devices`は既定出力の分類と、既定入力の名前・公称レートを表示する。
- 録音は1〜120秒。
  - 理由: 試作はnative rateで事前確保したメモリへ貯め、停止後に変換・保存する。
- 既存のWAVや`capture.log`は上書きしない。
  - 再実行: 毎回新しい出力ディレクトリを指定する。
- 終了コードは成功0、処理失敗1、システム全ゼロ3。
  - マイク拒否・制限・60秒の時間切れ: 理由を`capture.log`へ出し、終了コード1で止まる。
  - 注意: 全ゼロだけでは許可拒否と通常の無音を区別できない。
- 取り込み開始後に`afplay`を子プロセスとして起動する。
  - 限界: 同じ端末をTCCの帰属先に持つ音源の再生だけで、別アプリの取得権限を検証したことにはならない。

## 独立.appと許可

端末起動のCLIは、実測でGhosttyへ許可が帰属した。CLIへ埋め込んだ説明文だけでは端末の説明文不足を解消しなかった。

以下で独立.appを作る。既存KIKIGAKI.appとは別のbundle IDを使う。

- 実測済み: 進行役が`open`から起動し、タダシがシステム音声録音を許可した。
- 実測済み: 今回、同じ証明書とbundle IDで更新した.appからも録音できた。

```bash
bash build-app.sh
open -W -n "$PWD/work/SystemAudioProbe.app" --args record \
  --seconds 5 --out "$PWD/work/app-permission-01" \
  --play ~/work/fluidaudio-sandbox/samples/dialog2.wav
cat work/app-permission-01/capture.log
```

- 許可ダイアログは人が操作する。
  - 設定先: システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音。
  - 対象: ダイアログまたは一覧に現れる`SystemAudioProbe`。
  - 許可内容: システムオーディオのみ。画面の録画は使わない。
- `.app`は`open`経由で起動する。
  - 理由: `.app/Contents/MacOS/...`を端末から直接実行すると、端末へ帰属する可能性がある。
- 許可待ちまたは既知音声の再生中にも全ゼロなら、そこで止める。
  - 確認: 人が許可状態と実際の再生音を確認する。全ゼロを許可不足と決めつけない。
  - 再試験: 同じ`.app`を新しい出力先で再実行する。
- `build-app.sh`は署名証明書`kikigaki-dev`を使う。
  - 実測: 許可のsubjectは`com.tadashi-aikawa.kikigaki.system-audio-probe`だった。

許可と帰属を確認してから、原音全体を録音する。

```bash
open -W -n "$PWD/work/SystemAudioProbe.app" --args record \
  --seconds 37 --out "$PWD/work/app-system-01" \
  --play ~/work/fluidaudio-sandbox/samples/dialog2.wav
cat work/app-system-01/capture.log
```

マイク併用では上記の`open`へ`--mic`を追加する。

- マイクが未決定なら許可を要求し、最大60秒待つ。
  - 許可: そのまま録音を開始する。
  - 拒否・制限・時間切れ: 理由を出して録音せず終了する。
- マイク許可は進行役が取得済み。
  - 実測: USB・内蔵・OWS 2マイクとOWS 2出力の60秒同時取得は成功。

## マイクとシステム音声の同時取り込み

既定入力・出力を確認し、人がChromeなどの別アプリで既知音声を再生する。進行役の実測と同じ条件では、出力をOWS 2にする。

```bash
.build/debug/SystemAudioProbe devices
open -W -n "$PWD/work/SystemAudioProbe.app" --args record \
  --mic --seconds 60 --out "$PWD/work/both-01"
cat work/both-01/capture.log
.build/debug/SystemAudioProbe inspect work/both-01/system.wav
.build/debug/SystemAudioProbe inspect work/both-01/mic.wav
.build/debug/SystemAudioProbe inspect work/both-01/mixed.wav
```

- 自分の声をマイクへ入れ、相手側の音声が実際に聞こえることも確認する。
- このCLIはシステムの入力・出力設定と音量を変更しない。
- aggregate公称レートを時間軸として扱う。
  - 実測: micのstream表示16kHz、tapの表示48kHzでも、実バッファは両方320フレームで共通時計16kHzだった。
  - 結果: OWS 2マイクでも10秒・60秒の両系統非ゼロ取得に成功した。
- stream表示を揃えるための公称レート・virtual formatの書き込みは行わない。
  - 理由: 利用者の物理デバイス設定への影響を避ける。
- 委譲先のafplay試験ではシステム側が全ゼロだった。
  - 推定: 実際には再生音が鳴っていなかった見込み。原因は確かめていない。
  - 実測: 進行役とタダシのChrome再生では再現しなかった。
- `mixed.wav`は`0.5 * system + 0.5 * mic`を±1へ収めた音声。
  - 限界: マイク単独で読める文でも、音量差が大きい混合では自分の声がほぼ落ちた。
  - 本実装: 混合前に音量を揃え、ゲインと混合後の振幅の上限を守る処理が必要。

## 再生プロセスだけを取り込む

本文比較には`--play-only`を使う。通常のglobal tapは、他アプリで鳴っている音も拾う。

```bash
open -W -n "$PWD/work/SystemAudioProbe.app" --args record \
  --seconds 42 --out "$PWD/work/play-only-01" --play-only \
  --play ~/work/fluidaudio-sandbox/samples/dialog2.wav
cat work/play-only-01/capture.log
```

- `--play`で起動した`afplay`のHAL processだけをタップする。
  - 必須: `--play-only`と`--play`を併用する。
- `playback.wav`へ原音の前に5秒の無音を足す。
  - 手順: 再生開始 → HAL IDを最大3秒待つ → タップ作成 → aggregate開始。
  - 録音時間: 原音長+6秒以上を指定する。`dialog2.wav`は42秒で足りる。
- `capture.log`に`sourcePrefixMissingUpperBoundMs`を記録する。
  - 定義: プロセス起動時刻から初回入力host timeまでの差が、5秒を超えた部分。
  - 限界: `afplay`が実際に出音を始めた時刻は取得していないため、実際の欠けの上限として扱う。
  - 例外: 上限が0より大きければ比較を止める。
- 単一プロセス指定は、子プロセスの音声まで自動で包括する指定ではない。
  - ブラウザ: `processes`でhelperを含む実際のHAL processとbundle IDを確認する。

## 2本のWAVのずれを測る

```bash
.build/debug/SystemAudioProbe lag work/both-01/system.wav work/both-01/mic.wav
```

- 先頭30秒と共通の終端側30秒を、1msのRMS包絡で相互相関する。
  - 対象: 同じ時刻から録音し、スピーカー音をマイクも拾った2本。
  - 長さが違う場合: 短い方の終端に揃え、長い方の余りは評価しない。
- 正の遅延はマイクがシステム音声より遅い向き。
  - 探索: 最大±2000ms、1ms単位。
  - 出力: 遅延、相関係数、離れた山との差、末尾−先頭の遅延変化。
- 無音、弱い山、周期的な複数の山、探索範囲の端は「測れない」と出す。
  - 判断基準: 相関0.35以上、100ms以上離れた山との差0.05以上。
  - 条件: 共通音声が3秒以上必要。
- 共通音声が60秒未満なら先頭と末尾の窓が重なる。
  - 注意: この場合は長時間ドリフトの判断には使えない。
- ドリフト確認では先頭と末尾の両方に共通の音を入れる。
  - 制約: 音響遅延や経路変化も差に含むため、時計だけのずれを分離できる測定ではない。

## 本文比較の手順

同じビルドのKIKIGAKIで、元の会議音声とタップ経由の音声を別々にreplayする。

```toml
# work/direct.toml
outputDir = "~/kikigaki-system-audio-spike/replay-direct"
saveRecording = false
```

```toml
# work/tap.toml
outputDir = "~/kikigaki-system-audio-spike/replay-tap"
saveRecording = false
```

```bash
KIKIGAKI_DEBUG_REPLAY_REALTIME=1 KIKIGAKI_DEBUG_DIARIZATION=on ../../.build/KIKIGAKI.app/Contents/MacOS/KIKIGAKI \
  --config "$PWD/work/direct.toml" \
  --replay ~/work/fluidaudio-sandbox/samples/dialog2.wav \
  > work/replay-direct.log 2>&1
KIKIGAKI_DEBUG_REPLAY_REALTIME=1 KIKIGAKI_DEBUG_DIARIZATION=on ../../.build/KIKIGAKI.app/Contents/MacOS/KIKIGAKI \
  --config "$PWD/work/tap.toml" --replay "$PWD/work/play-only-01/system.wav" \
  > work/replay-tap.log 2>&1
```

- `.build/KIKIGAKI.app`の存在とビルド成功を確認してから実行する。
  - 本体のソース・設定ファイルを編集する必要はない。
- 本文だけの比較では、時刻・話者ラベルを外し、改行を詰める。
  - 注意: 認識は毎回揺らぎ得る。文字差を音声劣化と即断せず、原音も確認する。
- タップWAVの先頭・末尾の無音は、開始処理と指定録音時間による。
  - 条件: 原音全体の35.1604375秒を含む再生限定42秒WAVを使う。
  - 注意: 初回の5秒試験WAVと原音全体は比較しない。

混合とマイク単独を比較する場合は、`--config`の保存先と`--replay`のWAVをそれぞれ分ける。

- 比較用: `mixed.wav`と`mic.wav`を同じバイナリの等倍replayへ流す。
- 製品の決定: 混ぜた1本を使う。マイク単独replayは音量差の影響を検証するための操作。

## 追加の実測

- 音量0とミュートは、人が出力音量を操作して別々の録音を作る。
  - 注意: `afplay -v 0`は再生元自体の消音であり、出力デバイス音量0の検証にはならない。
- 出力切替は、録音中に人がイヤホンの接続または出力先の選択を行う。
  - 観測: `capture.log`の`output changed`と`timestampGaps`、前後の音声を確認する。
- 他アプリの音声を確認する際は、ブラウザや会議アプリから既知音声を再生し、`--play`を省略する。
  - 理由: 同じ端末に帰属する子プロセスだけを録音できた可能性を除く。

最終結果と未実測項目は[検証記録](../../docs/records/system-audio-spike.md)に記載する。
