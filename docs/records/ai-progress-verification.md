# AI依頼の進行表示の検証記録

2026-09-13までに行った、AI依頼の進行表示の検証と撮影の記録。現行の仕様ではない。現行は [AI依頼の進行表示](../ai-progress.md) を参照する。

記録の中の「過去会議」は、当時あった過去会議ウィンドウを指す。窓は撤去済みで、読み取り専用のsnapshotは撮影用のharnessだけが使う。

## 段1の検証結果

着手前の `swift build` と全694テストが成功。実装後は `swift build` と `swift test --no-parallel` の全704テストが成功。追加したのは `ProgressCommandTests` の6テスト、`AIProgressTests` の編集・acceptなし経路・点灯の3テスト、controllerの自己申告とフック観測の1テスト。状態8種類と接続5種類の組合せはパラメーター化した1テスト内で検証している。

## 段2のレビュー修正後の検証

段2レビュー修正後はbuild・ad-hoc署名.app生成・全650テストが成功。実ウィンドウの検証は `AIProgressWindowVerification` を別プロセスで起動し、AppKitのイベントループ上で遮蔽・最小化・クローズ・復帰を操作する。可視性を注入せず、`scrolled()` から行への伝播、復帰時の経過再計算、返答後の通知解除も確認する。同じ10枚を撮り直し、全枚を目視した。

`AIProgressViewTests` で3宛先の分離、接続欠損・世代不一致、会議切替時の履歴破棄、返答到着での同一行の切替、送達不明の返事行抑止、スクロール外・非表示・動きを減らす設定での時計停止、再表示時の再計算を確認した。過去会議の専用ウィンドウでも静止文言とタイマーなしを検証した。

## 段3: replayと実herdrの結合確認(旧版の文言。現行は「読込」)

2026-09-13に、架空の看板制作会議を `say -v Kyoko` で19.24秒の音声へ合成して検証した。実会議の音声は使っていない。ad-hoc署名の `.app` を `--show-window --replay` で起動し、音声5秒以降に `KIKIGAKI_DEBUG_AI_ASK` で1件送信、`KIKIGAKI_DEBUG_REPLAY_HOLD=240` で返送を待った。宛先は実herdrペイン `w9Z:p1` のClaude Code、表示モデルはFable 5.1 high。作業許可はなし。

| 観測時刻(JST) | 保存状態・接続 | 本番画面 |
| --- | --- | --- |
| 18:17:01 | submitted・idle | 「送信済み · 受領待ち · 0:00経過」。準備と送信が確認済み |
| 18:17:22 | accepted・working | 「受領 → AIが作業中 · 0:21経過」。受領と作業を追加 |
| 18:17:30 | answered・working | 進行表示が消え、同じ返事行に回答本文が表示された |

受領イベントは18:17:22.386、返答イベントは18:17:30.842。同梱CLIからの実受信箱イベントと画面の観測が一致した。返答時にも接続はworkingだったが、結果を優先して本文へ切り替わった。受領は同じsnapshotですでにworkingだったため、受領だけの独立した画面は今回観測していない。

証跡は `/private/tmp/kikigaki-ai-stepper-replay/`。`run2.log`、`screens/evidence.json`、同じディレクトリの `00-submitted-awaitingAcceptance.png`・`01-accepted-working.png`・`02-answered-answered.png` を残し、3枚とも目視した。保存Markdownは `output/2026-09-13_1816.md`。meeting IDは `187BB7DC-D3BF-47CD-981A-4905175B116B`、request IDは `2A71B044-EADE-422A-B1A5-631EF4C00259`。

依頼は音声5.5秒時点に固定され、確定会話0行と暫定末尾を送っている。このため回答は「決定事項はまだない」となった。後続の音声を回答対象へ後付けしていない。受領・返答は本番の保存へ反映され、進行のSetや文言は保存JSON・Markdownへ追加されない。

初回試行は新規検証フォルダのClaude Code信頼確認で `agent_not_ready` となり送信前に失敗した。自分で作った架空会話だけのフォルダを確認し、信頼確認後に別の会議として再実行した。初回ログは `run.log` に残し、結合成功には数えていない。

証跡採取はDEBUG専用の `ReplayAIProgressVerification` が `TranscriptWindowController.apply` の直後に実際の行から読む。状態・接続・受信箱を作ったり書き換えたりしない。通常起動では実行しない。設定例は [開発用のフラグと環境変数](../dev-flags.md) のreplay項目を参照する。

段3の採取処理追加後もbuild・ad-hoc署名.app生成・全650テストが成功した。ログは検証ディレクトリの `build.log` と `test.log`。

## 4段への組み直し後の結合確認

2026-09-13の21時台に、同じ合成音声で3通りを実herdrのClaude Code相手に確認した。宛先は会議ごとに新しいペインで、表示モデルはFable 5.1、作業許可あり。AIに編集させた先は迅雷のメモ1枚で、確認後に削除した。証跡は `/private/tmp/kikigaki-ai-stages-replay/`。

| 確認 | 依頼 | 本番画面の順 |
| --- | --- | --- |
| 自己申告 | `progress --editing --total 2` を1回呼んでから2か所を追記 | 送信済み · AIが読込中 → 読込済み · 作業中 → **編集中(全2か所)** → 返答到着 |
| フックだけ | Editツールで1か所を書き換え、`progress` は呼ばない | 送信済み · AIが読込中 → 読込済み · 作業中 → **編集中** → 返答到着 |
| 到着の点灯 | 会話が読めずneeds_inputで返った回 | 確認質問が到着。4段すべてが朱、現在の印・経過・取消なし |

- 自己申告の回は受信箱に編集の申告(`phase: editing`、`total: 2`)が12:15:17Zに落ち、画面は同じ秒に「編集中(全2か所)」へ進んだ。証跡は `screens-a/`
- フックだけの回は編集の申告が無く、`notify-*.json` の `toolName: Edit` が12:18:46.806Zに落ちて、同じ秒に総数なしの「編集中」へ進んだ。証跡は `screens-c/`
- 点灯は `ReplayAIProgressVerification` が結果到着の直後に撮ったフレームで、`progress_hidden` がfalseのまま4段が確認済みになっている。証跡は `screens-a2/`

replayの音声は約19秒で、依頼は音声15秒の時点に固定している。確定会話が0行の回はAIが決定事項を読み取れず、依頼文の指定だけで編集した。編集の到達を確かめる検証であり、議事録の中身の正しさは対象外である。

観測できた限界も記録する。

- `progress` を呼ばず**シェルコマンドで**書き換えた回は、フックも鳴らないため編集へ進まなかった。PreToolUseのmatcherは編集系ツールに限るので、`sed` などでの書き換えは補助観測の対象外になる
- 自己申告のあった回でもPreToolUseのフックは別に届いた。自己申告を優先し、総数は自己申告の値のままだった
- 新しい検証フォルダの初回起動はClaude Codeの信頼確認で `notReady` となり、送信前に失敗した。フォルダを確認して信頼を与えてから別の会議として実行し直している

実画面は `/private/tmp/kikigaki-ai-stages-ui/`。`arrival.png` が点灯、`arrival-body.png` が入れ替え後で、どちらも本番の `TranscriptWindowController.apply` を通した撮影である。

## 返答の段を足した後の結合確認

2026-09-13の22:24に、別の合成音声(約19秒の看板制作の打ち合わせ)で1回確認した。実会議の音声は使っていない。宛先は実herdrの新しいペイン `wA9` のClaude Codeで、作業許可あり。編集させた先は検証用のメモ1枚で、確認後にそのフォルダから外した。証跡は `/private/tmp/kikigaki-ai-replying-replay/`。

| 観測時刻(JST) | 保存状態・接続 | 本番画面 |
| --- | --- | --- |
| 22:25:03 | submitted・idle | 「送信済み · AIが読込中 · 0:00経過」。確認済みは送信 |
| 22:25:19 | accepted・working | 「読込済み · 作業中 · 0:16経過」。読込を追加 |
| 22:25:30 | accepted・working | 「編集中(全2か所) · 0:27経過」。編集を追加 |
| 22:25:42 | accepted・working | **「返答を作成中 · 0:39経過」**。返答が現在段で、総数の表記は消えた |
| 22:25:56 | answered・working | 「返答到着」。4段すべてが朱で、現在の印・経過・取消は出ない |

- 受信箱には `<request>.progress.editing.json`(`total: 2`)が13:25:30.127Z、`<request>.progress.replying.json`(`total` なし)が13:25:42.700Zに落ちた。段ごとに別ファイルで、返答の申告が編集の申告と総数を消していない
- 画面の反映はどちらも申告と同じ秒だった。証跡は `screens/` の `02-accepted-editing.png`・`03-accepted-replying.png`・`04-answered-answered.png` と `evidence.json`。5枚すべてを目視した
- 依頼文で `progress --editing --total 2` と `progress --replying` の呼び出しを明示した。Skillの参照先 `~/.claude/skills/kikigaki` はmainのリポジトリへのシンボリックリンクで、この枝の `meeting.md` を読ませられないため。CLI・受信箱・段の導出・画面はすべて本番の経路を通っている

## 段2の撮影手順と一覧

撮影はDEBUG専用の `AIProgressCaptureHarness` を使う。`AIQuestion` の送信・受領操作、宛先ごとの接続、`AIReturnStatus.isUnconfirmed` からsnapshotを作り、本番の `TranscriptWindowController.apply` を通して描画する。返事の文言や段はfixtureで指定しない。撮影中の時刻だけ固定し、保存やherdr通信は行わない。

```sh
CODESIGN_IDENTITY=none ./scripts/make-app.sh
KIKIGAKI_DEBUG_AI_PROGRESS_CAPTURE=/private/tmp/kikigaki-ai-stages-ui \
  .build/KIKIGAKI.app/Contents/MacOS/KIKIGAKI --show-window
```

4段への組み直し後の画像の置き場は `/private/tmp/kikigaki-ai-stages-ui/`。返答の段を足した後の撮り直しは `/private/tmp/kikigaki-ai-replying-ui/`。

| PNG | 確認する状態 |
| --- | --- |
| submitted.png | 送信直後。送信までの塗りと「送信済み · AIが読込中」 |
| reading.png | acceptだけを観測した状態。workingでも現在段は読込 |
| editing.png | 自己申告による「編集中(全7か所)」 |
| replying.png | 編集を終えて返答を書いている最中。総数が消え、現在段は返答 |
| three-destinations-replying.png | 同じ混雑画面で#2だけが返答作成中。宛先ごとに段が分かれる |
| arrival.png | 返答到着の全段点灯。現在の印・経過・取消を出さない |
| arrival-body.png | 点灯が終わって本文と所要時間へ入れ替わった同じ行 |
| blocked.png | 編集位置の一時停止と確認待ちの文言 |
| return-unconfirmed.png | idle継続による返送未確認 |
| disconnected.png | 編集までの塗りを保持し、不明の印を表示 |
| three-destinations-crowded.png | 45発話の会議へ編集・確認待ち・返送未確認を積んだ600pt幅 |
| three-destinations-narrow.png | 同じ混雑画面の420pt幅 |
| delivery-unknown.png | 送信注記と取消だけで返事行なし |
| blocked-before-accept.png | 読込前の確認待ちは送信までしか塗らない |
| historical.png | 読み取り専用のsnapshotで時間を省いた静止表示 |

画像はcacheDisplayで取得し、15枚すべてを目視確認した。点灯の2枚だけは「視差効果を減らす」を外した本番と同じ更新経路で撮り、その後に点灯を終わらせて撮り直している。過去会議の画像は返事行の静止表示を確認するfixtureであり、過去会議一覧ウィンドウ全体の撮影ではない。
