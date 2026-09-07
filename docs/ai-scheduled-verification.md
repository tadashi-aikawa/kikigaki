# 定期自動送信の結合検証

2026-09-08、main `f905030` の手入力統合を含むworktreeで実施。実herdrのCodexは `gpt-6-astra medium`、cwdは信頼確認済みの既定ディレクトリを使用した。導入先Skillは本人がmainへ展開し、worktreeの `skills/kikigaki/references/meeting.md` と `cmp` で一致を確認した。

音声は `say -v Kyoko` で作った架空の会議と無音だけ。実データを含み得る既存WAVの送信が自動承認レビューで拒否されたため、既存音声を使用しなかった。訂正の内容はreplayの手入力から投入した。音声認識精度を測る検証ではない。

## 自動・手動・最後の訂正

証跡は `/private/tmp/kikigaki-scheduled-replay/run1.log`、会議Markdownと `.kikigaki-context` は同ディレクトリの `run1/`。

- 音声: 冒頭の合成音声に無音を補った1200秒。実際のreplay実行時間は約127秒
- 自動: `KIKIGAKI_DEBUG_AI_AUTO="5:今回受領した架空の会話の要点を1文で返してください"`
- 手動: `KIKIGAKI_DEBUG_AI_ASK="500:架空会議の担当と期限を1文で返してください"`
- 手入力: 音声20秒で資料担当、1195秒で期限を金曜から木曜へ訂正
- 終了待ち: `KIKIGAKI_DEBUG_REPLAY_HOLD=120`

meeting IDは `E0D8988F-6051-4326-B5EE-30A1CD50C15C`。全requestがpane `w65:p1`、generation `1`、stream `B939D3E2-954E-4CF2-84B9-EC3D563A0DA2` を共用した。

| 送信 | 起動原因 | sequence | 読む範囲 | 結果 | isUnread |
|---|---|---|---|---|---|
| #1 | scheduled | 1 | 1〜2行 | answered | false |
| #2 | 手動 | 1 | 同じsnapshotの1〜2行 | answered | true |
| #3 | scheduled、停止時の最後 | 2 | 追加された3行目だけ | answered | false |

返事待ちの通常回は `availability=awaitingResult` でスキップし、request数1または2を維持した。手動返事の後は `availability=ready changed=false requests=2` のnoChangeが複数周期続き、新requestを作らなかった。

最後の手入力は停止直前に受理され、最終保存後に `send(final: true)` が1回だけ発火した。#3の返事には資料の期限が木曜へ変わったことが入り、会議Markdownへ自動の送信印・受領・返事とともに保存された。

3件の返送保存と追加送信がないことを確認後、この検証アプリのPIDを指定してHOLD途中で終了した。Codexの検証paneはレビュー用に残した。

## 返事待ちに録音停止が重なる場合

証跡は `/private/tmp/kikigaki-scheduled-replay/run2.log` と `run2/`。音声を180秒、自動間隔を3秒にし、音声5秒で会場担当を投稿、175秒で田中から佐藤へ訂正した。HOLDは90秒。

meeting IDは `9F465E0A-6763-44E1-BF38-B4A2E745EDD3`。2件ともpane `w66:p1`、generation `1`、stream `4AA80AEF-E40B-44DC-AC61-F04E27B49274` を使用した。

| 実時刻 | 観測 |
|---|---|
| 03:04:51 | 自動#1を送信 |
| 03:05:02 | 停止直前の担当訂正を手入力で受理 |
| 03:05:03 | 録音停止・最終保存。#1が返事待ちなので最終送信を保留 |
| 03:05:23 | #1のansweredを回収 |
| 03:05:29 | 入力可能となり最終#2を送信。sequence 2、訂正の3行目だけ |
| 03:05:55 | #2のansweredを回収しMarkdownへ保存 |

両方の `isUnread` はfalse。#2の返事は担当が佐藤へ変更された内容だった。`send(final: true)` は1回だけで、3件目は作られていない。needs_input・failed到着後の最終送信はアプリテスト、最終保存失敗・差分なしの最終非送信はCoreテストで検証している。

## 自動テストと形式検証

`swift build` と全308テストが成功。replay入力では最初のコロン以後と改行を保持し、通常起動では不正な値も解釈しない。smokeのreplay指定時は空欄・0・負数・非有限秒・空プロンプト・NUL・32 KiB超過を拒否する。

`CODESIGN_IDENTITY=none ./scripts/make-app.sh` で作った.appと同梱CLIを使用した。CLIの返送を模倣するfixtureは使わず、実際のCodexが改訂Skillを読み、accept・replyを呼び出した。
