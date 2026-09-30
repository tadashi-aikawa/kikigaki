# 開発用のフラグと環境変数

動作確認と検証のための起動フラグと環境変数の一覧。通常起動では無視するものが多く、DEBUGビルドだけで読むものもある。ビルドとテストの基本は `CLAUDE.md` の「テスト実行」を参照する。

動作確認は `./scripts/make-app.sh` で組んだ `.build/KIKIGAKI.app` で行う。マイクの TCC 許可は Info.plist の説明文が要るためバンドル実行が前提で、日常利用も `.app` 起動を標準とする。

## 起動フラグ

マイク無しでパイプラインの端から端までを確認するには、音声ファイルをマイクの代わりに流す開発用フラグを使う。流し終えると保存して終了する。replayは録音開始シートを出さず、前回の値と下記の環境変数の指定で同じ開始経路を通す。

```bash
swift run Kikigaki --config /path/to/config.toml --replay /path/to/audio.wav
```

- `--config <path>`: 設定ファイルを差し替える (保存先を作業用ディレクトリにするため)
- `--replay <wav>`: マイクの代わりに音声ファイルを実時間より速く流す
- `--show-window`: 起動直後に書き起こしウィンドウを表示する (見た目の確認用)
- DEBUGの `--open-url <url>` は、起動直後に `kikigaki://` のリンクを実物と同じ経路へ流します。LaunchServicesが別の場所の `.app` へURLを配るため、組んだばかりの `.app` を確かめるのはこちらです。replayとは併用しません。
- `--smoke`: UI を起動せず設定の読み込みだけ確認して終了する (CI 用)

## replayの速度と終了

- DEBUGビルドの `KIKIGAKI_DEBUG_REPLAY_REALTIME=1` はreplayを等倍で入力する。省略時は従来の約10倍速。
- 環境変数 `KIKIGAKI_DEBUG_REPLAY_HOLD=180`: replayの停止・保存後に指定秒だけ終了を遅らせる。0〜86400秒、既定0。到達済みの送信待ちと回答回収を継続する。停止後にペインを閉じるところまで見るときも、返事が届くまでの時間をここで確保する
- 環境変数 `KIKIGAKI_DEBUG_DIARIZATION=off` または `on`: replayで話者判別を指定する。通常起動では無視し、replayではUserDefaultsを読み書きしない。LIVE_TRACE併用時は、無効会議のASR確定受信と表示反映の単調時計を同じトークン数で照合できる。

## replayでのAI送信

- 環境変数 `KIKIGAKI_DEBUG_AI_ASK="40:;100:問い"`: replayの音声経過秒に達したら本番のsubmitAIで送信する。空の問いは声の末尾を使い、返事待ちは順番を保つ。前問がfailed/cancelledで接続が送信不可なら次問のために新世代へ作り直す。期限に達していない問いや失敗した問いの再送は行わない
- 環境変数 `KIKIGAKI_DEBUG_AI_ASK_PROFILE="相談"`: `KIKIGAKI_DEBUG_AI_ASK` の送信先プロファイルを名前で固定する。`autoStart` と別のプロファイルを指定すると、手動と自動が同時に別のAIへ飛ぶことを確かめられる。設定に無い名前なら起動時に止まる
- 環境変数 `KIKIGAKI_DEBUG_AI_AUTO="3:議事録を更新してください"`: replay開始時に本番の自動送信を開始し、直後に1回判定する。変更があれば即送信、空会話を含む変更なしなら開始から1間隔待つ。間隔は有限の正の秒数、プロンプトは必須。最初のコロンだけで分割し、以後のコロン・改行を保持する。作業許可は設定値、停止時の最後の1回はON。返事待ちをスキップし、自動で世代を再作成しない。判定時の効果・接続可否・変更の有無・request数をstderrへ出す。ASKと併用でき、停止後の最終待機と返送回収にはHOLDを設定する。通常起動では無視し、`--smoke --replay <wav>` は形式だけを検証する
- 環境変数 `KIKIGAKI_DEBUG_AI_AUTO_SECONDS=20`: 設定の `autoStart` の送信間隔を秒へ上書きする。0より大きく3600秒以下。分単位の設定値ではreplayの実行時間に収まらないため。開始そのものは本番の経路を通る
- 環境変数 `KIKIGAKI_DEBUG_AI_AUTO_PROFILE="ボード"`: replayの自動送信先を固定し、宛先の内蔵ボードプロンプトまたは設定のプロンプトを本番の開始経路から送る。間隔は `KIKIGAKI_DEBUG_AI_AUTO_SECONDS` で上書きできる。AI登録先もoutputDir内へ隔離する。
- 環境変数 `KIKIGAKI_DEBUG_MINUTES_PATH="/absolute/minutes.md"`: replay開始前に議事録パスを渡す。ボードのプロファイルではこれかboardLocationが必要。通常起動では無視する。
- 環境変数 `KIKIGAKI_DEBUG_AI_RENAME="0=田中"`: HOLD中に結果が届いた時点で0始まりの枡を一度改名する。結果がなければHOLD終了直前に行う。この3変数は通常起動では無視し、`--smoke --replay <wav>` で入力形式だけ検証できる

## 手入力の検証

- 環境変数 `KIKIGAKI_DEBUG_TYPED_ENTRIES='[{"seconds":20,"text":"https://example.com:8080/a;b"}]'`: replayの処理済み音声秒が指定位置に達したら本番のsubmitTypedで投稿する。startは実際の受付時点の収録位置で、処理が遅れていれば指定秒より後になる。JSON配列なのでURL中のコロン・セミコロンを保持し、同じ指定秒では配列順を保つ
    - 投稿に `"pauseSeconds":2` を足すと、その位置で一時停止し、実時間2秒後に投稿して再開する。0秒超・60秒以下だけを受け付ける。一時停止中の音声は通常の録音と同じく取り込まない。検証フラグ併用時は一時停止中・再開直後の会話、timelineと実ウィンドウも保存する
- 環境変数 `KIKIGAKI_DEBUG_TYPED_VERIFY=1`: replay中の投稿直後と停止後に本番の全体コピーを通し、保存先の `typed-verification/` に行JSON・コピープロンプト・Markdownを残す。停止後は改名、先頭2話者の統合、統合解除も通す。名前はAI_RENAMEの指定、なければ「改名確認」。クリップボードは変えず、AI登録簿も保存先の `.typed-test-support/` に隔離する。この2変数も通常起動では無視し、`--smoke --replay <wav>` で形式だけ検証できる
    - AI_ASKを併用する場合も、問いは録音中の指定秒で送る。停止後は手動の依頼を受け付けずペインも閉じるため、HOLD中には送らない。停止後の送信と返送回収を見るときは `KIKIGAKI_DEBUG_AI_AUTO` の最後の1回を使う

## 議事録とボードの検証

- DEBUGの `--preview-minutes <path>` に `KIKIGAKI_DEBUG_BOARD_HEADING="## ボード"` と `KIKIGAKI_DEBUG_BOARD_CAPTURE=<出力先>` を添えると、両タブをPNGへ撮影して終了する。
    - `--preview-warning` を添えると、AIセッションを復元できなかった旨の検証用の警告をヘッダーに出す
    - 環境変数 `KIKIGAKI_DEBUG_BOARD_ANCHOR=<見出し>`: BOARD_CAPTUREと併用する。ボードタブ内の `#` リンクのうち、リンク先が指定した見出しと一致するものをクリックし、ボード内のその見出しへ移動して見えることを確かめる。撮影に `board-link.png` が加わる。リンク行が無い、または移動できなければ失敗する。見出しは詳細図の見出しの文字列を渡す
- DEBUGの `--minutes-history-ui <出力先>` は専用UserDefaultsで議事録履歴の実操作と600pt・1800ptの撮影を行います。同じ引数に `--history-restart` を足して別プロセスで復元と再表示を検証し、専用設定を消します。通常の `--preview-minutes` も既存の隔離設定を使います。
- 環境変数 `KIKIGAKI_DEBUG_MINUTES_VERIFY=main` または `outside`: replayで議事録の実UIと、AIの `minutes` 通知の回収を検証する。`--replay` があるときだけ読み、通常起動では無視する。`main` と `outside` 以外を指定すると起動時にエラーで止まる。実AI(Codex)とherdrを使うため、同梱CLIのある `.app` から起動する
    - 証跡: `<outputDir>/minutes-verification/` へ場面ごとのPNGと `evidence.json` を書く。AI登録簿は保存先の `.typed-test-support/` へ隔離する
    - `main`: `KIKIGAKI_DEBUG_AI_ASK` に3件の問いを並べて使う。人の指定・AIの通知・古い通知の回収の順序を検証する。2件目は前の場面が済むまで、3件目はその次の場面が済むまで、ハーネスが送信を止める。指定秒は下限で、実際の送信はハーネスの進行に従う
    - `outside`: `KIKIGAKI_DEBUG_AI_AUTO` の1回目で送る。ハーネスが `~/Documents/kikigaki-minutes-denied-<会議ID>.md` をパス欄へ確定し、書き込みが拒否されて `work_failed` で返り、envelopeの `minutes_path` が人の指定と一致し、ファイルが作られていないことを確かめる。パスは `outputDir` の外にあり、Codexの既定の許可にも含まれないため、拒否はCodex側の権限境界で起こる
    - 実行例: `KIKIGAKI_DEBUG_MINUTES_VERIFY=outside KIKIGAKI_DEBUG_REPLAY_HOLD=300 KIKIGAKI_DEBUG_AI_AUTO='5:指定されたparticipant.minutes_pathへ議事録を作成してください' .build/KIKIGAKI.app/Contents/MacOS/KIKIGAKI --show-window --replay <wav> --config <設定ファイル>`。`KIKIGAKI_DEBUG_TYPED_ENTRIES` で会話の中身を足せる

## AI依頼の進行表示の検証

- DEBUGビルドで `KIKIGAKI_DEBUG_AI_PROGRESS_REPLAY=/path/to/evidence` を指定すると、replayの本番画面更新直後にAI進行の変化をPNGと `evidence.json` へ記録する。AI登録簿は保存先の `.typed-test-support/` へ隔離し、request・受信箱・保存形式は変更しない。実herdrを使うため同梱CLIのある `.app` から起動する
- DEBUGの `--show-window` と `KIKIGAKI_DEBUG_AI_PROGRESS_CAPTURE=<出力先>` の併用は、マイク・モデル・herdrを起動せず、進行表示のfixtureを本番のウィンドウへ流してPNGを撮って終了する。実際のrequest操作から状態を流し、保存はしない。段ごと(送信・読込・編集・返答)、返答の到着、接続の切断、過去会議の静止表示、3宛先の混雑、420ptの狭い幅を撮る
    - 環境変数 `KIKIGAKI_DEBUG_AI_FEEDBACK=<値>`: 撮る場面を切り替える。`model` は本文の下のモデル表記を、`labels` は状態ごとのラベルを撮る。`before` は `before-working.png` の1枚だけを撮る。それ以外の値は、状態の推移と返事の種類(回答・確認質問)を撮る。`model` 以外では、先頭の宛先のアバター画像の読み込みを待ち、読み込めなければ失敗する
    - 環境変数 `KIKIGAKI_DEBUG_AI_AVATAR=<ローカルパスまたは画像URL>`: fixtureの先頭の宛先のアバター画像を差し替える
- DEBUGの `--show-window` と `KIKIGAKI_DEBUG_AI_PROGRESS_VERIFY=1` の併用は、実際のAppKitイベントループで返事待ち行の更新タイマーを検証する。表示・スクロールで外れる・他のウィンドウで隠れる・最小化・閉じる・開き直し・返事の到着で、タイマーの動作と停止が期待どおりかを確かめ、成功なら終了コード0、失敗なら1で終了する
- DEBUGの `--utterance-confirmation <出力先>` は、発話の確定前後の表示をPNGへ撮る。詳細は [発話の確定表示](utterance-progress.md) を参照する

## 診断ログ

- 環境変数 `KIKIGAKI_DEBUG_LIVE=1`: 停止直前の録音中表示を stderr に出す (録音中と最終結果の差を調べる用)
- 環境変数 `KIKIGAKI_DEBUG_LIVE_TRACE=1`: 録音中の表示更新時に、音声経過秒と全文を stderr に出す。診断ログに会話本文を含む
- 環境変数 `KIKIGAKI_DEBUG_PHRASES=1`: 停止時のフレーズごとに、トークンの時刻と窓判定から補正後への話者の変化を stderr に出す
    - `[segment]` は窓集計前の音声側の話者区間。発話が重なる場合は複数話者の区間も重なる

## 話者補正の再比較

- DEBUGの `KIKIGAKI_TRIAL_DUMP` でreplayやマイクの入力を書き出し、`--align-compare` で本番の判定とフレーズ固定を当て直す。別のビルドとの差は出力の全文を `diff` で比べる。試験用 `.app` は `KIKIGAKI_TRIAL=1 ./scripts/make-app.sh` で別の場所・別の識別子に組む。手順は [話者判定の再比較手順](speaker-compare.md)
- 補正を外した条件の比較は、廃止した試験変数を持つコミット `11d8733` のビルドで行う。結果は [話者補正の除外比較とフレーズ固定の試験](records/speaker-correction-trial.md)
- 被りの島の補正の段階 `off|cut|phrase|cross` の比較は、試験変数 `KIKIGAKI_TRIAL_ISLAND` を持つコミット `66be821` のビルドで行う。採用は `cross` で、試験変数は廃止した。条件・凍結との整合・比較結果は [被りの島の補正を段階的に強める試験](records/speaker-overlap-islands.md)
- 廃止した `KIKIGAKI_TRIAL_ALIGNER` ・ `KIKIGAKI_TRIAL_FREEZE` ・ `KIKIGAKI_TRIAL_ISLAND` は、指定すると録音を始めずに止まる

## テスト

- `KIKIGAKI_TEST_SPEECH=1 swift test --filter DiarizationTests`: 通常はスキップする実Apple Speechの結合テストも実行できます。マイクを使わず無音を入力し、話者モデルの呼出ゼロ・相槌省略なし・会議ごとの切替を確認します。
- 環境変数 `KIKIGAKI_TEST_DIARIZATION=1 swift test --filter SpeakerDiarizerTests`: 実モデルで短い入力とchunk境界の末尾処理を確かめる。初回はモデルを取得する
- 開始シートの見た目は `KIKIGAKI_START_SHEET_CAPTURE=<出力先> swift test --filter StartSheetTests` でPNGへ撮り、モックと突き合わせます。
- 撮影用の環境変数: 次の変数は、値に出力先を渡したときだけ、該当のテストがPNGを書き出す。指定しなければ何も書かない
    - `KIKIGAKI_UI_CAPTURE`: `HoverButtonTests` ・ `NarrowWindowTests`
    - `KIKIGAKI_TYPED_CAPTURE`: `TypedImageTests` ・ `TypedEntryTests`
    - `KIKIGAKI_MINUTES_CAPTURE`: `MinutesUpdateTests` ・ `MinutesPreviewTests` ・ `MinutesWebTests`。`KIKIGAKI_MINUTES_SAMPLE` を添えると `MinutesWebTests` が指定の議事録を撮る
    - `KIKIGAKI_EXCLUSION_CAPTURE`: `AudioExclusionAppTests`
    - `KIKIGAKI_LEVEL_CAPTURE`: `AudioLevelAppTests`
    - `KIKIGAKI_PATH_CAPTURE`: `MinutesWindowRevisionTests`
    - `KIKIGAKI_STATE_CAPTURE`: `AIRobotTests`
    - `KIKIGAKI_DIARIZATION_CAPTURE`: `DiarizationTests`
    - `KIKIGAKI_UI_MENU_CAPTURE=1`: `AIViewTests` が宛先のメニューを撮る。`KIKIGAKI_UI_MENU_WIDTH` でウィンドウ幅を指定する。既定は600
    - `KIKIGAKI_UI_AVATAR=<画像>`: `AIProfileReviewTests` が宛先のメニューを画像付きで撮る
    - `KIKIGAKI_SCHEDULE_REVIEW_AI=<入力>`: `AIScheduleReviewTests` が、実herdrの保存済み会議を土台に自動送信のUIを撮る
- `KIKIGAKI_MINUTES_PERF=1`: `MinutesPerformanceTests` が4MiBの議事録の描画更新と検索を測る
- `KIKIGAKI_CLI_TEST_BINARY=<パス>`: `ReturnCommandTests` が別プロセスで起動する同梱CLIを差し替える。既定は `.build/debug/kikigaki-cli`
