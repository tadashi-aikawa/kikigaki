# 議事録プレビューの結合検証

2026-09-11 02:31〜02:42 JST、段3b `4fb9647` を基点に実施。実Codexの作成・同梱CLIの通知・本番の受信回収・実ウィンドウの描画まで通った。実行モデルは全件 `gpt-6-astra low`。音声と手入力は架空会議で、音声認識精度は今回の対象外。

## 実行条件とコマンド

証跡のルートは `/private/tmp/kikigaki-minutes-e2e-0911`。最終の正常系は `main2`、書込拒否は `outside`。設定はそれぞれ同名のTOML。共通設定は次のとおり。

```toml
outputDir = "/private/tmp/kikigaki-minutes-e2e-0911/main2"
saveRecording = false
[ai]
name = "結合検証"
address = "検証担当へ"
cli = "codex"
model = "gpt-6-astra"
effort = "low"
allowWork = true
notifySound = false
extraArgs = ["--ask-for-approval", "never"]
```

`prompt` にはこのworktreeの `skills/kikigaki/references/meeting.md` を読み、実保存後に同梱CLIの `minutes` と `reply` を呼ぶことを指定。outsideは通常権限で1回だけ実書込を試み、失敗なら迂回・権限拡張なしで `reply --kind failed --reason work_failed` を返す指定とした。cwdは既定の `~/Library/Application Support/KIKIGAKI/ai-work`。

```sh
ffmpeg -hide_banner -loglevel error \
  -i /private/tmp/kikigaki-scheduled-replay/fixture-short.wav \
  -af apad -t 1200 /private/tmp/kikigaki-minutes-e2e-0911/fixture.wav

env KIKIGAKI_DEBUG_MINUTES_VERIFY=main \
  KIKIGAKI_DEBUG_REPLAY_HOLD=600 \
  KIKIGAKI_DEBUG_TYPED_ENTRIES='[{"seconds":1,"text":"架空会議。体験会は9月18日。案内担当は佐藤、接続確認は鈴木。期限は9月11日。"}]' \
  KIKIGAKI_DEBUG_AI_ASK='20:架空会議の短いMarkdown議事録を /private/tmp/kikigaki-minutes-e2e-0911/main2/auto.md に作成してください。決定事項と担当表を含め、保存後に同梱CLIのminutesを呼んでください。;20:人が指定したparticipant.minutes_pathへ会議の議事録を作成してください。見出しに人の指定先と入れ、保存後に同梱CLIのminutesを呼んでください。;20:現在のparticipant.minutes_pathへ議事録の補足として担当確認済みと追記してください。保存後に同梱CLIのminutesを呼んでください。' \
  .build/KIKIGAKI.app/Contents/MacOS/KIKIGAKI --show-window \
  --replay /private/tmp/kikigaki-minutes-e2e-0911/fixture.wav \
  --config /private/tmp/kikigaki-minutes-e2e-0911/main2.toml \
  > /private/tmp/kikigaki-minutes-e2e-0911/main2.log 2>&1

env KIKIGAKI_DEBUG_MINUTES_VERIFY=outside \
  KIKIGAKI_DEBUG_REPLAY_HOLD=300 \
  KIKIGAKI_DEBUG_TYPED_ENTRIES='[{"seconds":1,"text":"架空会議。体験会は9月18日。案内担当は佐藤、接続確認は鈴木。期限は9月11日。"}]' \
  KIKIGAKI_DEBUG_AI_AUTO='5:指定されたparticipant.minutes_pathへ架空会議の短い議事録を作成してください。通常権限で書き込みを試み、失敗したら同梱CLIのreply failed --reason work_failedで返してください。' \
  .build/KIKIGAKI.app/Contents/MacOS/KIKIGAKI --show-window \
  --replay /private/tmp/kikigaki-scheduled-replay/fixture-short.wav \
  --config /private/tmp/kikigaki-minutes-e2e-0911/outside.toml \
  > /private/tmp/kikigaki-minutes-e2e-0911/outside.log 2>&1
```

`ReplayMinutesVerification` はreplayかつ明示環境変数がある場合だけ動く。パス欄の確定と表示切替は実UIアクションへ渡す。クリックは人の手動操作ではなくハーネスからの呼出し。request・通知の生成や時刻の書換えはしない。送信の順序と古い通知の回収直前の操作だけを制御し、結果をassertする。回収台帳はoutputDir内へ隔離する。

## 正常系の証跡

会議ID `D505B5FB-4856-4C0F-99A0-0811BD193306`。以下のファイルは `main2/.kikigaki-context/<会議ID>/ai` 内。各requestは `requests/<ID>.json`、受信箱は `inbox/<ID>.accept.json`・`inbox/<ID>.minutes.json`・`inbox/<ID>.result.json` が実際に残った。3件とも `result.kind == answered`。

| 順 | request ID | envelopeのparticipant.minutes_path | 結果 |
| --- | --- | --- | --- |
| 1 | `9D040AD3-50D8-48AF-A229-3F1612F9BA9C` | キー省略 | AIがauto.mdを実作成しminutes通知 |
| 2 | `24335929-5805-41A3-8F32-C6B5DB1AC400` | `/private/tmp/kikigaki-minutes-e2e-0911/main2/human.md` | 人の指定先に実作成しminutes通知 |
| 3 | `80C2CC44-7ABC-48CE-BC5C-1C3F21B176FC` | 同じhuman.md | 担当確認済みを実追記しminutes通知 |

実Codexの端末で次のCLI呼出しと成功を確認した。認証tokenは記録しない。

```sh
.build/KIKIGAKI.app/Contents/Helpers/kikigaki-cli minutes \
  --session '<outputDir>/.kikigaki-context/<会議ID>/ai/sessions/1.json' \
  --request '80C2CC44-7ABC-48CE-BC5C-1C3F21B176FC' \
  --token '<省略>' --path '/private/tmp/kikigaki-minutes-e2e-0911/main2/human.md'
# {"event_id":"80C2CC44-7ABC-48CE-BC5C-1C3F21B176FC/minutes"}
```

3件目の実通知を回収する直前、人の経路でkept.mdを選択した。`minutes.json` の保存値は次のとおり。実通知は人の指定より5ms古く、回収到達点だけ進んで対象は変わらない。

```json
{
  "human_minutes_path": "/private/tmp/kikigaki-minutes-e2e-0911/main2/kept.md",
  "minutes_path": "/private/tmp/kikigaki-minutes-e2e-0911/main2/kept.md",
  "target_source": "human",
  "target_changed_at": "2026-09-10T17:37:58.054Z",
  "last_event": {
    "event_id": "80C2CC44-7ABC-48CE-BC5C-1C3F21B176FC/minutes",
    "recorded_at": "2026-09-10T17:37:58.049Z"
  }
}
```

保存された会議本文は `main2/2026-09-11_0235.md`。生成議事録は `main2/auto.md` と `main2/human.md`。

## AUTO送信と書込拒否

会議ID `B11E995D-3B36-41A1-8A7D-F4DEEDFF63C1`。requestのenvelope抜粋:

```json
{
  "participant": {
    "request_id": "AC9B648A-D539-49DD-9DC3-CDF5A862A065",
    "trigger": "scheduled",
    "minutes_path": "/Users/tadashi-aikawa/Documents/kikigaki-minutes-denied-B11E995D-3B36-41A1-8A7D-F4DEEDFF63C1.md"
  }
}
```

Codexが実際にapply_patchでこのパスへの新規作成を1回試み、ツールから `patch rejected: writing outside of the project; rejected by user approval settings` が返った。OSのopen失敗を測った試験ではなく、Codexの書込権限境界での拒否である。指定ファイルは未作成。既存の許可範囲には `/private/tmp` があるため、単にoutputDirの兄弟を使わずDocuments直下を選んだ。

同梱CLIの返送後、`outside/.kikigaki-context/<会議ID>/ai/inbox/AC9B648A-D539-49DD-9DC3-CDF5A862A065.result.json` に `kind: failed`、`reason: work_failed`、`recorded_at: 2026-09-10T17:40:53.222Z` を確認した。acceptファイルは存在し、minutesファイルは存在しない。アプリは失敗理由を表示し、対象パスを維持した。会議保存は `outside/2026-09-11_0240.md`。

## 実画面と後片付け

以下は実アプリのcontent viewをPNGへ採取し、全て目視した。各ディレクトリの `evidence.json` に同時点の表示状態・印・対象パス・到達点がある。

| 場面 | 画面 |
| --- | --- |
| 非表示、印なし | [00-hidden](/private/tmp/kikigaki-minutes-e2e-0911/main2/minutes-verification/00-hidden.png) |
| 非表示のまま議事録の印 | [01-notice](/private/tmp/kikigaki-minutes-e2e-0911/main2/minutes-verification/01-notice.png) |
| ONでAIの議事録・表を表示、印消去 | [02-ai-body](/private/tmp/kikigaki-minutes-e2e-0911/main2/minutes-verification/02-ai-body.png) |
| 人の指定先を表示 | [04-human-body](/private/tmp/kikigaki-minutes-e2e-0911/main2/minutes-verification/04-human-body.png) |
| 古い実通知の回収後もkept.md | [06-old-notification-ignored](/private/tmp/kikigaki-minutes-e2e-0911/main2/minutes-verification/06-old-notification-ignored.png) |
| AUTO失敗理由と未作成の案内 | [02-work-failed](/private/tmp/kikigaki-minutes-e2e-0911/outside/minutes-verification/02-work-failed.png) |

初回mainではハーネスが通知未到着をunsafeFileと誤分類した。実通知の回収自体は成功したが、待機判定を修正してmain2で全段階を再実行した。上表は修正後の証跡のみ。

検証が作ったCodex workspace `w8D`・`w8E`・`w8F` は、それぞれ `herdr workspace close <ID>` で閉鎖済み。アプリPID `97807`・`7532`・`16405` も保存完了後に個別に終了した。他のAIセッションは閉じていない。

最終変更後の `swift build` 成功、`swift test` 全560件成功。ログは `/private/tmp/preview-stage4-build-final.log` と `/private/tmp/preview-stage4-tests-final.log`。通常起動では検証環境変数を解釈しないこともテストで固定した。

## 段3cを畳んだ後の影響確認

2026-09-11 03:02 JST。段2 `3914b9b`、段3c `d3da08e` へ裁定を畳み、指定base `2e1eef1` 上へrebaseした。rebase前後の最終ファイルの差分は空。実AIの再送はせず、影響範囲だけを再確認した。

```sh
swift test --filter 'MinutesMonitorRevisionTests|MinutesWindowRevisionTests|MinutesSubmissionRevisionTests|MinutesRevisionTests|MinutesStoreTests'
./scripts/make-app.sh
git diff preview-before-stage3c-squash HEAD --stat
```

29テスト成功。ログは `/private/tmp/preview-stage3c-rebased-tests.log`。FIFOの監視開始が100ms未満で戻ること、実監視通知と補完タイマー、StatusItemから閉じた画面を開く切替、表示メニューのvalidate、ON/OFFのAX、希望幅の復元と制約中の保存抑止を確認した。待機指定の開始適用・本番abandonでの取消と再開始・二回目準備中の指定・適用失敗の1回制限も通った。自動・確認返答・再送では本番入口から人の指定だけをenvelopeに採取した。

直前の全体検証は全570件成功。ログは `/private/tmp/preview-stage3c-commit-tests.log`。アプリ組立とkikigaki-dev署名も成功し、ログは `/private/tmp/preview-stage3c-app-build.log`。検証AI workspaceの一覧を再確認し、w8D・w8E・w8Fが残っていないことを確認した。

描画変更の5場面は `/private/tmp/kikigaki-preview-ui-stage3c/` へ再撮影して全て目視した。ファイル名は01-empty、02-body、03-missing、04-busy、05-wide-1800の各PNG。特に [1800pt全体](/private/tmp/kikigaki-preview-ui-stage3c/05-wide-1800.png) で新録音ボタンと議事録トグルの並びを再確認した。4MiB更新はメインスレッド841.51msから178.82msへ短縮したが、100msを超える停止は残る。測定条件とログは [UI検証記録](minutes-preview-ui.md) に記載した。
