# CLAUDE

## プロダクト

KIKIGAKI(聞き書き)は、会議の発話をマイクから聴いて話者付きでリアルタイムに文字起こしし、Markdown で残す macOS ネイティブアプリ (Swift) です。

- 文字起こし: Apple の Speech フレームワーク `SpeechTranscriber` (macOS 26 以降、端末内処理)
- 話者判別: FluidAudio の Sortformer (ストリーミング、最大4話者)。FluidAudio への依存はこのためだけ
- 音源は MVP ではマイクのみ。`AudioSource` プロトコルで差し替えられるようにしてあり、システム音声は次の段で足す

## リポジトリ構成

- `Sources/KikigakiCore/`: ロジック層 (Foundation + NaturalLanguage + TOMLKit。ユニットテストの主戦場)
  - `Aligner.swift`: トークン時刻と話者区間の突き合わせ。フレーズ単位の多数決・島の扱い・決定的な同点処理
  - `SpeechTail.swift`: 長い1文字の末尾の声と後続文字を使う語頭補正。長い文字の多数決の重みを検出された発話時間へ絞る
  - `WordBoundaries.swift`: 日本語の語境界を確認し、短くても語として完結した返答を多数派へ吸収しない
  - `SpeakerFreeze.swift`: 文字起こしの確定結果に属する、30秒より古いトークンの話者判定を凍結。暫定結果は凍結しない
  - `RepeatedBackchannels.swift` / `MeetingArchive.swift`: 停止時の繰り返し相槌の省略と、省略前後の保存。原文が保存できないときは省略しない
  - `SpeakerNames.swift` / `TranscriptRenderer.swift` / `MeetingMarkdown.swift` / `MeetingFiles.swift`: 話者名の枡・行の整形・Markdown 生成・ファイル命名
  - `Config.swift`: 設定ファイルのパースと既定値
  - `RecordingState.swift`: 録音状態とメニュー表題
- `Sources/Kikigaki/`: 実行ターゲット (AppKit + Speech + FluidAudio)。Swift 5 言語モード (非 Sendable な型を音声スレッドと MainActor で受け渡すため)
  - `MeetingSession.swift`: 音源→WAV(任意)+話者判別+文字起こし→突き合わせ→表示、停止で保存、の流れ
  - `AudioSource.swift`: `MicSource` / `FileSource` (`--replay` 用) / `WavWriter`
  - `AppleTranscriber.swift` / `SpeakerDiarizer.swift`: エンジンのラッパー
  - `TranscriptWindow.swift` / `StatusItem.swift` / `Hotkey.swift` / `KeyCodes.swift` / `AppDelegate.swift`
- `Tests/KikigakiCoreTests/`: ユニットテスト (swift-testing)
- `Resources/`: アプリバンドル用の Info.plist (マイク使用の説明文 `NSMicrophoneUsageDescription` を含む)
- `scripts/`: アプリバンドル組み立て (`make-app.sh`)・リリース成果物 (`build_release.sh`)・Homebrew tap 更新 (`update_tap.sh`)

設計上の前提と判断の理由は各ファイルのコメントに書いてあります (プロトで反証された仮定を含む)。変える前に読んでください。

## 設定

`~/.config/kikigaki/config.toml` (TOML)。すべて省略可で、省略時は既定値です。話者の統合先は画面から操作できます。

```toml
# Markdown (と録音WAV) の保存先。既定: ~/Documents/KIKIGAKI
outputDir = "~/Documents/KIKIGAKI"
# 録音WAVを Markdown と並べて残すか。既定: false (通常利用では不要でディスクを食うだけ)
saveRecording = false
# 実験機能: 停止時に短い繰り返し相槌の候補を省く。原文を .raw.md にも保存する。既定: false
dropRepeatedBackchannels = false

# グローバルショートカット。既定は ctrl+alt+cmd+K (開始/停止) と ctrl+alt+cmd+P (一時停止/再開)
[hotkeys.toggleRecording]
modifiers = ["ctrl", "alt", "cmd"]
key = "k"

[hotkeys.togglePause]
modifiers = ["ctrl", "alt", "cmd"]
key = "p"

# 話者候補とアバター。省略可
[[speakers]]
name = "田中"
avatar = "~/Pictures/avatars/tanaka.png"

[[speakers]]
name = "迅雷"
avatar = "https://example.com/jinrai.webp"

# AI参加を有効にする。省略するとAI機能は無効
[ai]
cli = "codex"
address = "迅雷へ"
notifySound = false
# 自動送信シートの初期値。設定だけでは開始しない
autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください" # 省略時は空欄
autoIntervalMinutes = 3 # 1〜60分、省略時は3分
```

定期送信は録音中・一時停止中にフッターの「自動送信…」から開始します。シートで毎回の依頼、間隔、作業許可を設定すると、開始から指定間隔後に最初の送信を行い、状態行へ次の時刻を表示します。手動の「AIへ…」と同じAIセッションを使い、受領済みの会話から変更がない回や返事待ちの回はスキップします。

「自動送信を停止」は録音を続けたまま自動送信を止めます。シートの「録音停止時に最後の1回を送る」は既定ONです。最終処理と保存が成功し、変更があれば送信し、返事待ちなら到着後まで保留します。保留中も同じ停止操作で取りやめられます。

自動の返事は「自動」の印付きで畳まれ、未読強調や通知音はありません。確認質問・失敗は通常どおり表示します。稼働状態は新会議・再起動で引き継がず、シートの変更を設定ファイルへ書き戻しません。詳細は [定期自動送信](docs/ai-scheduled.md) を参照してください。

話者名かアバターをクリックすると、台帳の候補選択・自由入力・既定名へのリセットができます。同じ枡の全発言に反映し、停止後は保存も更新します。別の枡で使用中の候補は選べません。台帳の名前は空と重複を認めません。

ウィンドウ上部の「話者…」で話者を手動統合し、「統合しない」で元の話者へ戻せます。停止後の変更は通常Markdownと省略前Markdownにも反映します。話者名と統合先は新しい録音の開始時にリセットします。詳しい条件は [話者の手動統合](docs/speaker-mapping.md) を参照してください。

画像はローカルパスとHTTP・HTTPSのURLに対応します。取得できない画像はイニシャルで表示し、URL画像は `~/Library/Caches/kikigaki/avatars/` へキャッシュします。台帳の変更は既存の設定再読込で反映します。

保存先には `2026-09-05_1240.md` (有効時は同名の `.wav`) を1会議1ファイルで書きます。

新しく保存する発話行とAI用の会話ファイルは `[HH:MM:SS] 話者名: 本文` の実時刻です。一時停止の長さを反映し、既存の経過時刻形式のファイルは変換しません。

本文下の1行入力欄から、録音中・一時停止中だけ⌘Enterで投稿できます。素のEnter・Shift+Enterでは投稿も改行もしません。固定名「手入力」は4話者とは別で、改名・統合・相槌省略の対象外です。IMEのEnterは変換確定を優先し、Escでは下書きを残します。手入力のURLはクリックで開け、名前と本文は検索対象です。

`MeetingSession.typedEntries` を音声処理から独立して保持し、`TranscriptEntries.merge` で音声位置順に併合します。typedは必須のpostedAtを持ち、画面・Markdown・AI文脈は `TranscriptRenderer.clock` で投稿日時を表示します。AI送信のtypedは最初のawaitより前に固定します。詳細は [手入力の設計](docs/typed-entry.md)。

同じ分に録音を始め直した場合、既存の保存物があれば `_2`、`_3` と連番を付けます。

`dropRepeatedBackchannels = true` は、停止時に「うんうん」「そうそう」など短い反復の候補を省きます。録音中は省略せず、通常の `.md` と停止後の画面へ省略結果を反映し、省略前の書き起こしは同名の `.raw.md` に残します。話者名の変更は両方へ反映します。原文ファイルの保存に失敗した会議は、通常の `.md` と画面へ原文を残します。

1回だけの相槌や同じ話者に判定された繰り返しは対象外です。実際の発話者を保証する機能ではなく、誤った省略もあり得ます。詳細は [繰り返し相槌の仕様と検証](docs/repeated-backchannels.md) を参照してください。設定変更は次の録音から適用します。

## AIへの受け渡し

会議中・停止後の「会話をコピー」は、固定したローカル会話ファイルへの参照と読む範囲をコピーします。AI側には `skills/kikigaki` を導入します。続きのコピー、訂正、再コピーの契約は [AIへの受け渡し](docs/ai-handoff.md) を参照してください。話者名はウィンドウ上部の「話者名…」でまとめて変更できます。

`[ai]` を設定すると、herdrの専用ペインへ依頼や返答を送り、返事を同じ会議へ回収できます。既定はCodex・宛名「迅雷へ」・通知音なし・ショートカット `ctrl+alt+cmd+A`。CLI種別や設定は会議開始時に固定し、変更は次の会議から反映します。初回は固定cwdへの信頼を利用者がherdrペインで承認します。CLIとherdrの実行ファイルはPATHのほか `~/.local/bin`・miseのshims・Homebrewを探し、見つからないときは `command` / `herdrCommand` の絶対パスで指定します。詳細は [AI参加者の設計](docs/ai-participant.md) を参照してください。

- `KikigakiCore`: AI設定、独立stream履歴、envelope、質問と受信イベント、Markdown。herdr・AppKit・Processを置かない
- `KikigakiAIIO`: アプリと返送CLIが共有するfd検証、原子的な保存、sessionとフック観測の型
- `KikigakiCLI`: `accept`・`reply`・`notify`。reply本文はstdinから読み、固定requestの受信箱へ排他公開する。会議Markdownへ直接書かない
- `scripts/make-app.sh`: `Contents/Helpers/kikigaki-cli` を同梱し、helperを先に署名してから.appを署名する。配布ZIPでもhelperの存在と署名を検証する

Claudeのフック設定はセッション専用の `--settings` JSONへ生成し、同梱CLIの絶対パスだけをallowします。利用者のグローバルsettingsは編集しません。Codexのnotifyはセッション限定で差し替え、TOMLで読める配列を渡します。フックは回答の正本にせず、未返送の補助表示に留めます。

## コミットメッセージ

Conventional Commits 形式で日本語で書く。

```
<type>(<scope>): <description>
```

- `type`: `feat`, `fix`, `refactor`, `style`, `docs`, `chore`, `build`, `ci`, `test`
  - 破壊的変更がある場合は `feat!` のように `!` を付ける
  - 見た目だけの変更 (余白・色・サイズなど挙動が変わらないもの) は `feat` ではなく `style` を使う
  - 判定基準: **読み取れる情報や挙動が変わるなら `feat`、同じ情報の見せ方だけなら `style`。迷ったら `feat`**
- ユーザーから見て1つの対応は1コミットにまとめる (タダシとのやりとりで生じた調整・手直しは分けず統合する)
- `scope`: `session`, `aligner`, `window`, `config`, `hotkey` など機能単位 (省略可)
- `description`: ユーザー視点で何が変わったかを簡潔に書く
- AI Agent (owlery) がコミットする場合は `--author="<名前> <slug@owlery.local>"` で author を自分の Agent 名にする (committer はデフォルトのまま)

## テスト実行

ビルド・ユニットテストはリポジトリルートで以下を実行します。

```bash
swift build
swift test
```

動作確認は `./scripts/make-app.sh` で組んだ `.build/KIKIGAKI.app` で行います (マイクの TCC 許可は Info.plist の説明文が要るためバンドル実行が前提。日常利用も `.app` 起動を標準とします)。

マイク無しでパイプラインの端から端までを確認するには、音声ファイルをマイクの代わりに流す開発用フラグを使います。流し終えると保存して終了します。

```bash
swift run Kikigaki --config /path/to/config.toml --replay /path/to/audio.wav
```

- `--config <path>`: 設定ファイルを差し替える (保存先を作業用ディレクトリにするため)
- `--replay <wav>`: マイクの代わりに音声ファイルを実時間より速く流す
- `--show-window`: 起動直後に書き起こしウィンドウを表示する (見た目の確認用)
- `--smoke`: UI を起動せず設定の読み込みだけ確認して終了する (CI 用)
- 環境変数 `KIKIGAKI_DEBUG_AI_ASK="40:;100:問い"`: replayの音声経過秒に達したら本番のsubmitAIで送信する。空の問いは声の末尾を使い、返事待ちは順番を保つ。前問がfailed/cancelledで接続が送信不可なら次問のために新世代へ作り直す。期限に達していない問いや失敗した問いの再送は行わない
- 環境変数 `KIKIGAKI_DEBUG_AI_AUTO="3:議事録を更新してください"`: replay開始時に本番の自動送信を開始する。間隔は有限の正の秒数、プロンプトは必須。最初のコロンだけで分割し、以後のコロン・改行を保持する。作業許可は設定値、停止時の最後の1回はON。通常回の差分なし・返事待ちをスキップし、自動で世代を再作成しない。判定時の効果・接続可否・変更の有無・request数をstderrへ出す。ASKと併用でき、停止後の最終待機と返送回収にはHOLDを設定する。この変数も通常起動では無視し、`--smoke --replay <wav>` で形式だけ検証できる
- 環境変数 `KIKIGAKI_DEBUG_REPLAY_HOLD=180`: replayの停止・保存後に指定秒だけ終了を遅らせる。0〜86400秒、既定0。到達済みの送信待ちと回答回収を継続する
- 環境変数 `KIKIGAKI_DEBUG_AI_RENAME="0=田中"`: HOLD中に結果が届いた時点で0始まりの枡を一度改名する。結果がなければHOLD終了直前に行う。この3変数は通常起動では無視し、`--smoke --replay <wav>` で入力形式だけ検証できる
- 環境変数 `KIKIGAKI_DEBUG_TYPED_ENTRIES='[{"seconds":20,"text":"https://example.com:8080/a;b"}]'`: replayの処理済み音声秒が指定位置に達したら本番のsubmitTypedで投稿する。startは実際の受付時点の収録位置で、処理が遅れていれば指定秒より後になる。JSON配列なのでURL中のコロン・セミコロンを保持し、同じ指定秒では配列順を保つ
  - 投稿に `"pauseSeconds":2` を足すと、その位置で一時停止し、実時間2秒後に投稿して再開する。0秒超・60秒以下だけを受け付ける。一時停止中の音声は通常の録音と同じく取り込まない。検証フラグ併用時は一時停止中・再開直後の会話、timelineと実ウィンドウも保存する
- 環境変数 `KIKIGAKI_DEBUG_TYPED_VERIFY=1`: replay中の投稿直後と停止後に本番の全体コピーを通し、保存先の `typed-verification/` に行JSON・コピープロンプト・Markdownを残す。停止後は改名、先頭2話者の統合、統合解除も通す。名前はAI_RENAMEの指定、なければ「改名確認」。クリップボードは変えず、AI登録簿も保存先の `.typed-test-support/` に隔離する。この2変数も通常起動では無視し、`--smoke --replay <wav>` で形式だけ検証できる
  - AI_ASKを併用する場合、この検証モードだけは指定秒に到達した問いを停止後のHOLDで送る。HOLDを設定し、停止による確定待ち取消を挟まず最終会話の送信と返送後の保存を確認する
- 環境変数 `KIKIGAKI_DEBUG_LIVE=1`: 停止直前の録音中表示を stderr に出す (録音中と最終結果の差を調べる用)
- 環境変数 `KIKIGAKI_DEBUG_LIVE_TRACE=1`: 録音中の表示更新時に、音声経過秒と全文を stderr に出す。診断ログに会話本文を含む
- 環境変数 `KIKIGAKI_DEBUG_PHRASES=1`: 停止時のフレーズごとに、トークンの時刻と窓判定から多数決後への話者の変化を stderr に出す
  - `[segment]` は窓集計前の音声側の話者区間。発話が重なる場合は複数話者の区間も重なる
- 話者判別の既定は `highContextV2_1`。長いチャンクを使い、採用版の出力遅延は約30.4秒。アプリの話者固定猶予とは別の値
- 環境変数 `KIKIGAKI_SORTFORMER=fast` または `balanced`: 比較用に `fastV2_1` または `balancedV2_1` へ切り替える。モデルは初回に HuggingFace から取得する。`high-context` の明示指定も既定と同じ動作になる

通常起動でHigh Contextを使います。Fastを比較する場合は、起動中のKIKIGAKIを終了してから `open --env KIKIGAKI_SORTFORMER=fast .build/KIKIGAKI.app` で起動します。High Contextでは停止時に話者エンジンだけへ無音を補い、不完全な末尾チャンクも判定します。保存する録音と会議時間は延長せず、話者区間も実音声の終端で切ります。

### 表示品質の検証

短い別話者区間は通常、フレーズの多数派へ揃えます。ただし語境界で完結し、文字・数字が2文字以上ある1語、または文末句読点まで含む区間は元の判定を残します。0.6秒以上で「ですか」など限定した応答末尾を持ち、語境界で完結する区間も保持します。「はい」「すごいね。」「あ、本当ですか」を吸収しないための条件であり、話者の正しさを保証するものではありません。多数派の音声区間が区間全体を覆う場合(相槌が重なり主話者が喋り続けている場面)は、1語でも相槌・応答の語彙(はい・うん・なるほど 等)に限って残し、「代表」のような文中の語は多数派へ戻します。どの話者区間にも当たらない不明の島は、語の途中を切るものなら長さに関係なく多数派へ付け、語として完結する長いものだけ不明のまま残します。詳細は [短い返答の話者を残す条件](docs/short-speaker-turns.md) を参照してください。

語内で話者が割れた場合は、ASRトークンと語の両端が一致し、既知話者の文字数で過半数がある語だけ境界を補正します。同点・不明・凍結済みを含む語は補正しません。補正前の短い別話者区間の端がこれで修復された場合は、完全な語の核を保持します。詳細は [話者交代の語頭・語尾補正](docs/speaker-boundaries.md) を参照してください。

録音中は確定した文字起こしの古いトークンだけ話者判定を凍結し、停止時は凍結を外して全体を再判定します。文字起こしの確定と話者判定の正しさは別であり、確定した文字列でも話者は誤ることがあります。

長い1文字に続く文字の確定結果がまだ無い場合は、その文字から先の凍結を保留します。尾部の語頭補正が後続結果に依存するためです。重複区間の短い複数語を句点だけで別話者として保持しない条件を含め、最新の評価と残る課題は [議事品質の改善計画](docs/minutes-quality-plan.md) を参照してください。

- プロトと同じ音声で保存結果が一致することは移植の検証です。精度や録音中の表示の安定性は別に確認します
- `KIKIGAKI_DEBUG_LIVE` が出すのは停止直前の1回分です。録音中の全時点の検証には、途中の表示と、その時点の確定・暫定トークンを確認する必要があります
- `KIKIGAKI_DEBUG_PHRASES` の変更前の話者も、前後0.5秒の窓で集計した推定値です。実際の発話者の正解ラベルではありません。相槌の除去を評価するときは、原音と突き合わせ、本文の誤削除も確認します
- 修正前後を比べるときは、入力音声を揃え、出力先をそれぞれ別の検証用ディレクトリにします。ビルドの終了コードが成功であることを確認してから実行します

FluidAudio の Sortformer モデルは初回起動時に HuggingFace から `~/Library/Application Support/FluidAudio/Models` へ落ちます。Apple Speech の日本語アセットも初回に自動取得されます。

## リリース方法

GitHub Actions の `Release` workflow を `main` ブランチから手動実行します。

semantic-release が前回のタグ以降の Conventional Commits から次のバージョンを決定し、`v<バージョン>` タグ、リリースノート、`KIKIGAKI-<バージョン>.zip` (署名済み KIKIGAKI.app) を含む GitHub Release を作成し、homebrew-tap の Cask (`kikigaki`) を更新します。リリース対象となるコミットがなければ何も公開しません。

- 署名は自己署名証明書 `kikigaki-dev` で固定します (repo secrets: `MACOS_CERT_P12_BASE64` / `MACOS_CERT_PASSWORD`)。マイクの TCC 許可をリリースをまたいで維持するためです
- tap 更新には repo secret `TAP_GITHUB_TOKEN` (homebrew-tap への Contents: Read and write 権限の fine-grained PAT) を使います
- `Resources/Info.plist` の追跡中のバージョンは `0.0.0-development` のまま維持し、リリースバージョンは配布 ZIP 内にだけ埋め込みます
