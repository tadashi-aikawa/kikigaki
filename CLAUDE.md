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

# AI参加を有効にする。省略するとAI機能は無効。単数の [ai] は互換で読み、1つ目が既定
[[ai]]
name = "議事録"           # 省略時は address から導く参加者名。重複は不可
cli = "codex"
address = "迅雷へ"
avatar = "~/Pictures/jinrai.png" # 省略時は紫のイニシャル。http/httpsのURLも使える
effort = "high"           # 推論の強さ。CLIごとの引数へ翻訳する。extraArgs との二重指定は不可
notifySound = false       # プロファイルごとに効く。返答元の設定で鳴らす
cwd = "~/work/minutes"    # 起動時の作業ディレクトリ。省略時は固定の既定
autoStart = true          # 録音開始で自動送信を始める。配列で1つまで
# 手動・自動実行シートのプロンプト初期値。autoStart=true は録音開始直後に1回判定、それ以外はシートから開始
autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください" # 省略時は空欄
autoIntervalMinutes = 3 # 1〜60分、省略時は3分

# ホットキーは1つ目のプロファイルにだけ書ける
[ai.hotkey]
modifiers = ["ctrl", "alt", "cmd"]
key = "a"

[[ai]]
name = "相談"
cli = "claude"
effort = "max"
address = "ネオへ"
```

`effort` の値域はCLIごとに違います。Codexは none / minimal / low / medium / high / xhigh / max / ultra を `-c model_reasoning_effort` へ渡し、Claudeは low / medium / high / xhigh / max を `--effort` へ渡します。実際に通る値はモデルによります。`extraArgs` での effort 指定は二重指定になるため設定エラーにします。

`[[ai]].avatar` は話者台帳と同じローカルパス・HTTP・HTTPSの画像に対応します。AIの返事行に使い、省略・取得失敗時は従来の紫のイニシャルを表示します。URL画像は共通の `~/Library/Caches/kikigaki/avatars/` に保存します。アバターの設定も会議開始時に固定され、過去会議は保存済みのプロファイルから表示します。

`[[ai]]` を複数書くと、「AIへ…」と「自動送信…」のシートで送信ごとに宛先を選べます。既定はどちらも1つ目で、会議内では手動と自動が独立に前回の選択を覚えるため、自動は議事録、手動は相談のように同時に使えます。会議内の番号は全体の通しで、印とMarkdownの宛名で見分けます。確認質問への返答は元の質問と同じ宛先へ返ります。

`herdrCommand` はプロファイル共通です。2つ目以降は省略でき、先頭の値を引き継ぎます。先頭と違う値を明示したときだけ設定エラーになります。ホットキーも1つ目のプロファイルのものだけを使い、宛先を選び直しても変わりません。

会議に紐づかないAIセッションは、フッターの「…」内の「AIセッションを準備…」かメニューバーの同じ項目から先に起こしておけます。待機中・録音中・一時停止中のいつでも使えます。シートでプロファイルを選んで起動すると、会議と同じフック・サンドボックス許可・返送許可を付けた状態で待機し、同じシートの下半分に溜まっているものを一覧します。行ごとに「ペインを開く」と「破棄」ができ、破棄は台帳から外して準備用の置き場も削除します。ペインは終了させません。

準備済みセッションだけは、Codexの書き込み許可を保存先の `.kikigaki-context` 全体にします。起動引数は起こしたときに焼き付いて後から変えられず、紐づけ先の会議がまだ決まっていないためです。会議から起こす通常の起動は、これまでどおりその会議の `ai/` だけを許可します。

次の録音を開始すると、未紐づけがある枠について「準備済みのAIセッション」シートが出ます。枠ごとに使うものか「新規に起動する」を選び、既定は最も古い準備済みです。取消は録音そのものを取り止め、その会議のMarkdown・録音・AIの置き場に加えて、AI会議の登録と紐づけも戻します。選び終えてから `autoStart` が動きます。引き継げなかった枠があれば選び直しになり、候補が尽きていても「新規に起動する」を選ぶまで自動送信を始めません。使わなかったものは残り、次の録音でも選べます。録音中は宛先ポップアップの字下げした行からも選んで紐づけられます。

準備シートの任意の「名前」は改行なし・UTF-8で64バイト以内です。空なら従来どおり、入力すれば一覧・紐づけシート・宛先ポップアップへ「名前 · 表題 · 起動時刻」を表示します。名前は台帳・herdrのペイン表題へ保存し、紐づけ後のenvelopeに `participant.prepared_session_name` として渡します。

名前を省略した一覧の表示は「議事録 · Kikigaki 議事録抽出 · 13:05起動」です。ペインの表題は台帳へ保存せず出すたびに引き直すため、CLIが設定するまでの間は名前と時刻だけになります。準備してから設定を変えたものは「設定が変わったため使えません」、保存先を変えたものは「保存先が変わったため使えません」として候補から外し、理由を出して破棄だけできます。返送の許可先は起動時に焼き付くため、保存先を変えると返せなくなるからです。準備済みの詳細は「…」内の「AIセッションを準備…」のホバーと準備シートで確認できます。

通常の手動実行の入力欄も、宛先の `autoPrompt` を初期表示します。編集した文面は空欄も含めて宛先ごとに会議内で保持し、送信後やシートを開き直したときに復元します。自動実行の下書きとは独立し、新しい録音で初期値へ戻ります。確認質問への返答と失敗した依頼の再送は従来の入力復元を使います。

詳細は [AI設定の複数プロファイル](docs/ai-profiles.md) を参照してください。稼働中のherdrペインへ接続する `attach` と `displayAgent` は取り下げたため、書くと設定エラーになります。

`autoStart = true` は録音開始時、それ以外はロボットの「自動実行…」シートから開始し、直後に本番の送信判定を1回行います。変更があれば即送信し、次の期限はCLIへ渡す時点から1間隔。空会話を含む変更なしなら送らず、開始時点から1間隔のカウントダウンへ進みます。「今すぐ送る」も同じ判定を直後に行います。「手動実行…」はAI依頼シートです。ダブルクリック送信はありません。

ロボットは自動OFFで薄墨の輪郭、ONで朱の輪郭。確定待ち・起動・接続中は朱の輪郭のまま目を動かし「準備中」、CLIへ渡す直前の `beginSending` からは手動・自動とも朱の反転と白い目で「実行中」です。失敗・取消・自動停止では準備中を残さず、実行IDで古い接続の後着通知を除外します。送信待ちがなく自動ONなら `2:30`・`0:45` の形式で残り時間を表示し、変更なしのスキップ理由はツールチップへ。切断・最終送信待ちは「—」、自動OFFの待機は下ラベルなしです。文字は未読と共通の9pt mediumで数字だけ等幅です。

ロボットのメニューの「自動実行解除」は録音を続けたまま自動送信を止めます。「…」から停止項目を外し、他の項目は維持します。シートの「録音停止時に最後の1回を送る」は既定ONです。最終処理と保存が成功し、変更があれば送信し、返事待ちなら到着後まで保留します。保留中も同じ停止操作で取りやめられます。

自動の返事も「自動」の印付きで未読として表示し、本文・未読ピルのクリックで既読にします。自動answeredの通知音は鳴らしません。確認質問・失敗は通常どおり表示します。稼働状態は新会議・再起動で引き継がず、シートの変更を設定ファイルへ書き戻しません。詳細は [定期自動送信](docs/ai-scheduled.md) を参照してください。

ロボットの目は表示中の準備中・返事待ちに限り1秒周期で左右へ動きます。非表示・最小化・非稼働ではタイマーを止め、「視差効果を減らす」では目を静止させます。連続アニメーションは使いません。ホットキー ctrl+alt+cmd+A は引き続き手動実行シートを開きます。

話者名かアバターをクリックすると、台帳の候補選択・自由入力・既定名へのリセットができます。同じ枡の全発言に反映し、停止後は保存も更新します。別の枡で使用中の候補は選べません。台帳の名前は空と重複を認めません。

ウィンドウ上部の人型アイコンと使用枠数で話者を手動統合し、「統合しない」で元の話者へ戻せます。停止後の変更は通常Markdownと省略前Markdownにも反映します。話者名と統合先は新しい録音の開始時にリセットします。詳しい条件は [話者の手動統合](docs/speaker-mapping.md) を参照してください。

画像はローカルパスとHTTP・HTTPSのURLに対応します。取得できない画像はイニシャルで表示し、URL画像は `~/Library/Caches/kikigaki/avatars/` へキャッシュします。台帳の変更は既存の設定再読込で反映します。

保存先には `2026-09-05_1240.md` (有効時は同名の `.wav`) を1会議1ファイルで書きます。

新しく保存する発話行とAI用の会話ファイルは `[HH:MM:SS] 話者名: 本文` の実時刻です。一時停止の長さを反映し、既存の経過時刻形式のファイルは変換しません。

画面の時刻も、発話・手入力・AIの行・送信の細い1行をすべて `HH:MM:SS` で表示します。

本文下の1行入力欄から、録音中・一時停止中だけ⌘Enterで投稿できます。素のEnter・Shift+Enterでは投稿も改行もしません。固定名「手入力」は4話者とは別で、改名・統合・相槌省略の対象外です。IMEのEnterは変換確定を優先し、Escでは下書きを残します。手入力のURLはクリックで開け、名前と本文は検索対象です。

`MeetingSession.typedEntries` を音声処理から独立して保持し、`TranscriptEntries.merge` で音声位置順に併合します。typedは必須のpostedAtを持ち、画面・Markdown・AI文脈は `TranscriptRenderer.clock` で投稿日時を表示します。AI送信のtypedは最初のawaitより前に固定します。詳細は [手入力の設計](docs/typed-entry.md)。

同じ分に録音を始め直した場合、既存の保存物があれば `_2`、`_3` と連番を付けます。

`dropRepeatedBackchannels = true` は、停止時に「うんうん」「そうそう」など短い反復の候補を省きます。録音中は省略せず、通常の `.md` と停止後の画面へ省略結果を反映し、省略前の書き起こしは同名の `.raw.md` に残します。話者名の変更は両方へ反映します。原文ファイルの保存に失敗した会議は、通常の `.md` と画面へ原文を残します。

1回だけの相槌や同じ話者に判定された繰り返しは対象外です。実際の発話者を保証する機能ではなく、誤った省略もあり得ます。詳細は [繰り返し相槌の仕様と検証](docs/repeated-backchannels.md) を参照してください。設定変更は次の録音から適用します。

## AIへの受け渡し

会議中・停止後の「会話をコピー」は、固定したローカル会話ファイルへの参照と読む範囲をコピーします。AI側には `skills/kikigaki` を導入します。続きのコピー、訂正、再コピーの契約は [AIへの受け渡し](docs/ai-handoff.md) を参照してください。話者名はウィンドウ上部の「話者名…」でまとめて変更できます。

`[ai]` を設定すると、herdrの専用ペインへ依頼や返答を送り、返事を同じ会議へ回収できます。既定はCodex・宛名「迅雷へ」・通知音なし・ショートカット `ctrl+alt+cmd+A`。CLI種別や設定は会議開始時に固定し、変更は次の会議から反映します。初回は固定cwdへの信頼を利用者がherdrペインで承認します。CLIとherdrの実行ファイルはPATHのほか `~/.local/bin`・miseのshims・Homebrewを探し、見つからないときは `command` / `herdrCommand` の絶対パスで指定します。詳細は次の2つを参照してください。

- 会議参加モードの契約: [AI参加者の設計](docs/ai-participant.md)
- 複数プロファイルと準備済みセッション: [AI設定の複数プロファイル](docs/ai-profiles.md)

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
- 環境変数 `KIKIGAKI_DEBUG_AI_AUTO="3:議事録を更新してください"`: replay開始時に本番の自動送信を開始し、直後に1回判定する。変更があれば即送信、空会話を含む変更なしなら開始から1間隔待つ。間隔は有限の正の秒数、プロンプトは必須。最初のコロンだけで分割し、以後のコロン・改行を保持する。作業許可は設定値、停止時の最後の1回はON。返事待ちをスキップし、自動で世代を再作成しない。判定時の効果・接続可否・変更の有無・request数をstderrへ出す。ASKと併用でき、停止後の最終待機と返送回収にはHOLDを設定する。通常起動では無視し、`--smoke --replay <wav>` は形式だけを検証する
- 環境変数 `KIKIGAKI_DEBUG_AI_AUTO_SECONDS=20`: 設定の `autoStart` の送信間隔を秒へ上書きする。0より大きく3600秒以下。分単位の設定値ではreplayの実行時間に収まらないため。開始そのものは本番の経路を通る
- 環境変数 `KIKIGAKI_DEBUG_AI_ASK_PROFILE="相談"`: `KIKIGAKI_DEBUG_AI_ASK` の送信先プロファイルを名前で固定する。`autoStart` と別のプロファイルを指定すると、手動と自動が同時に別のAIへ飛ぶことを確かめられる。設定に無い名前なら起動時に止まる
- 環境変数 `KIKIGAKI_DEBUG_AI_PREPARE="議事録;相談"`: 録音を始める前に、本番の準備経路でそのプロファイルのAIセッションを起こす。設定に無い名前なら起動時に止まる
- 環境変数 `KIKIGAKI_DEBUG_AI_ATTACH="1=oldest;2=new"`: 枠ごとの紐づけの選択。`oldest` は最も古い準備済み、`new` は新規に起動する。紐づけシートを出さずに本番の選択経路を通す。紐づけに失敗したら止まる
- 環境変数 `KIKIGAKI_DEBUG_AI_ATTACH_CANCEL=1`: 紐づけシートの「取消(録音を始めない)」と同じ経路で録音を取り止め、保存も置き場も残さずに終了する
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

短い別話者区間は通常、フレーズの多数派へ揃えます。ただし語境界で完結し、文字・数字が2文字以上ある1語、または文末句読点まで含む区間は元の判定を残します。0.6秒以上で「ですか」など限定した応答末尾を持ち、語境界で完結する区間も保持します。「はい」「すごいね。」「あ、本当ですか」を吸収しないための条件であり、話者の正しさを保証するものではありません。多数派の音声区間が区間全体を覆う場合、または同じフレーズで区間の直前・直後がともに多数派の場合は、相槌・応答プリセットに本文全体が一致するものだけを残します。「はい」「うん」「なるほど」「分かりました」などを保持し、「代表」のような文中の一般語は多数派へ戻します。前後の連続性は吸収前のラベルで確認し、別フレーズや第三話者をまたぎません。プリセット外の短い返答を吸収する場合もあります。どの話者区間にも当たらない不明の島は、語の途中を切るものなら長さに関係なく多数派へ付け、語として完結する長いものだけ不明のまま残します。詳細は [短い返答の話者を残す条件](docs/short-speaker-turns.md) を参照してください。

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
