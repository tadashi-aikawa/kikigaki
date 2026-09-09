# AIを会話の行として並べる表示の結合検証

2026-09-09、`feature/ai-timeline` の段4で実施。設計は [AIを会話の参加者として並べる](ai-timeline.md) を参照する。接続先はClaude Codeにし、宛先は複数プロファイル統合後の `[[ai]]` を2つ使った。

音声は既存の `say -v Kyoko` で作った架空の会議262秒だけを再利用した。実データを含み得るWAVは使っていない。音声認識の精度を測る検証ではない。

## 実行

| run | 目的 | 宛先 | 環境変数 |
|---|---|---|---|
| 1 | 起動経路の確認 | 議事録(自動)・相談(手動) | `AI_AUTO_SECONDS=25`、`AI_ASK_PROFILE=相談`、`AI_ASK="60:…"`、`HOLD=240` |
| 2 | 2宛先の往復と既読 | 同上 | `AI_AUTO_SECONDS=30`、`AI_ASK_PROFILE=相談`、`AI_ASK="60:…"`、`HOLD=300` |
| 3 | 検索中の到着 | 相談のみ | `AI_ASK="40:…;200:…"`、`HOLD=420` |

証跡は `/private/tmp/kikigaki-timeline-replay/` の `run{1,2,3}.log` と `run{1,2,3}/`。実画面は `/private/tmp/kikigaki-ai-timeline-ui/` の `live-{waiting,answered,read,search-before,search-after}.png`。

## `swift run` では送信できない

run 1は3件とも `失敗` に終わり、朱の帯へ「入力前に停止しました。接続先と設定を確認してください」が出た。原因は**`swift run` で起動すると同梱CLIが無いこと**。アプリは `Bundle.main.bundleURL` から `Contents/Helpers/kikigaki-cli` を組み立てるので、`.build/arm64-apple-macosx/debug/Contents/Helpers/kikigaki-cli` を指してherdrのworkspace作成まで届かない。

`CODESIGN_IDENTITY=none ./scripts/make-app.sh` で組んだ `.build/KIKIGAKI.app/Contents/MacOS/Kikigaki` から起動すると通った。**AI参加の検証は必ず.appから起動する。** 意図しない失敗ではあるが、失敗の帯と「再送」が実際の失敗経路で出ることの確認にはなった。

## 2つの宛先が同じ列に並ぶ

run 2、meeting ID `9EE5045F-BA11-4138-8B39-C454BCB533DC`。workspaceは `w6M KIKIGAKI ネオ 15:27` と `w6N KIKIGAKI 迅雷 15:27` に分かれた。

| 送信 | 宛先 | slot | 起動原因 | 送信の形 | 結果 | isUnread |
|---|---|---|---|---|---|---|
| #1 | ネオ | 2 | 手動 | 人側の行「AIへ送信 … ネオへ」 | answered | true |
| #2 | 迅雷 | 1 | scheduled | 細い1行「└ 迅雷へ自動送信 · 1発言 · 作業許可なし · 15:28」 | answered | false |

- 返事の行は `ネオ` と `迅雷` に分かれ、**宛名はrequestごとに出た**。選択中の宛先には依存していない
- 手動の返事にだけ引用が付き、自動の返事には付かなかった
- 「AI」と「自動」の枠の印で、人の依頼への返事と自動の返事を見分けられた
- 会議Markdownの `## AIとのやりとり` は従来どおりで、`- 宛先:` がネオと迅雷に分かれた。**表示だけの変更という前提は保たれている**

## 到着で画面が動かない

- **末尾追従していない状態**: run 2で返事待ちの行が返事の行へ変わる前後を撮った(`live-waiting.png` と `live-answered.png`)。先頭の「話者A 15:27」の位置は1ピクセルも動かず、フッターのピルだけが「返事待ち 2」から「未読 1」へ変わった
- **検索中・上を読んでいる状態**: run 3で検索欄を開き先頭まで戻した状態で#2の返事を受けた(`live-search-before.png` と `live-search-after.png`)。表示位置は変わらず、フッターだけが「返事待ち 1」から「未読 1」へ変わった

## 既読

- run 2でウィンドウを前面にし、返事の行が可視域と重なったまま数秒置くと、朱の帯と未読の印が消えた(`live-read.png`)。会話の保存も更新された
- run 3では検索中に上を読んでいたため、返事が届いても**既読にならなかった**。行が可視域に入っていないためで、設計どおり
- 自動送信のansweredは取り込み時点で既読になり、未読の帯も件数も出なかった

## 導入先Skillは変更不要

`skills/kikigaki/SKILL.md` と `references/meeting.md` は、envelope・会話ファイル・返送CLIの契約だけを扱う。今回の変更は表示だけで、印・畳む・未読といった語に依存する記述は無かった。実際にrun 2・3では既存Skillのまま受領と返送が通った。

## この検証で扱えなかったもの

- **確認質問への返答と再送の実herdr経路**。確認質問はモデルの判断で出るため誘発できず、再送も失敗を意図的に作る必要がある。どちらも `AIViewTests` と `AITimelineTests` で経路を通してある
- **上へドラッグしている最中の到着**。スクロールのドラッグを保ったまま返送を待つ操作を自動化できなかった。タイマーをcommon modesへ入れた対処は入れてある

## 後片付け

検証用のherdr workspace `w6M`・`w6N`・`w6P` はレビュー用に残した。KIKIGAKIのプロセスは3つとも停止済み。
