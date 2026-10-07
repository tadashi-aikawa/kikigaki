# CLAUDE

## プロダクト

KIKIGAKI(聞書)は、会議の発話をマイクから聴いて話者付きでリアルタイムに文字起こしし、Markdown で残す macOS ネイティブアプリ (Swift) です。

- 文字起こし: Apple の Speech フレームワーク `SpeechTranscriber` (macOS 26 以降、端末内処理)
- 話者判別: FluidAudio の Nemotron 3 Diarization fast128 (ストリーミング、最大8話者)。FluidAudio への依存はこのためだけ。設計は [Nemotron fast128 への話者判別の切替](docs/nemotron-integration.md)
- 音源はマイク、またはマイクとシステム音声の混合。開始シートで選ぶ。設計は [システム音声の取り込み](docs/system-audio.md)

## リポジトリ構成

- `Sources/KikigakiCore/`: ロジック層 (Foundation + NaturalLanguage + TOMLKit。ユニットテストの主戦場)。herdr・AppKit・Processを置かない
  - `Aligner.swift`: トークン時刻と話者区間の突き合わせ。窓判定・語内補正と長い語頭の付け替え・決定的な同点処理
  - `SpeechTail.swift`: 長い1文字の末尾の声と後続文字を使う語頭補正
  - `WordBoundaries.swift`: 日本語の語境界を調べ、語内補正の対象の語をASRトークンの範囲で返す
  - `SpeakerFreeze.swift`: 判定に読む入力が全て確定したフレーズを丸ごと凍結する。高精度側で未確定のトークンは凍結しない
  - `SpeakerIslands.swift`: 話し手の声が重なった短い別話者の島を両隣の話者へ戻す。判定は毎回補正前のラベルで行う
  - `SpeakerRuns.swift`: 話者判別の10ms確率を届いた分から話者区間へ畳む。確率の履歴は持たず、食い違った出力は取り込まない
  - `MeetingArchive.swift`: 会議の本文と設定の保存。改名・再判定・AIの更新でMarkdownを生成し直す
  - `SpeakerNames.swift` / `TranscriptRenderer.swift` / `MeetingMarkdown.swift` / `MeetingFiles.swift`: 話者名の枡・行の整形・Markdown 生成・ファイル命名
  - `Config.swift` / `AIConfig.swift`: 設定ファイルのパースと既定値。キーの一覧は [設定リファレンス](docs/config.md)
  - `RecordingState.swift`: 録音状態とメニュー表題
  - `SystemAudioMix.swift`: システム音声の3択、出力の3値判定、16kHzの加算とピーク保護
  - `URLScheme.swift`: `kikigaki://start` の解析。開始シートの入口だけを開け、録音は始めない
  - AI設定、独立stream履歴、envelope、質問と受信イベント、AIの返事のMarkdownもここに置く。契約は [AI参加者の設計](docs/ai-participant.md)
- `Sources/KikigakiAIIO/`: アプリと返送CLIが共有するfd検証、原子的な保存、sessionとフック観測の型
- `Sources/KikigakiCLI/`: 同梱CLI `kikigaki-cli`。配置は `.app/Contents/Helpers/kikigaki-cli`
  - コマンド: `accept`・`reply`・`progress`・`notify`・`minutes`・`skill`。書式は `ReturnCommand.swift` と `SkillCommand.swift`
  - `reply` の本文はstdinから読み、固定requestの受信箱へ排他公開する。`minutes` は議事録の絶対パスを独立イベントとして同じ検証で保存する。会議Markdownへは直接書かない
  - `skill install|uninstall` は利用者が端末で打つ配布Skillの導入口。モデルの返送では使わない
- `Sources/Kikigaki/`: 実行ターゲット (AppKit + Speech + FluidAudio)。Swift 5 言語モード (非 Sendable な型を音声スレッドと MainActor で受け渡すため)
  - `MeetingSession.swift`: 音源→WAV(任意)+話者判別+文字起こし→突き合わせ→表示、停止で保存、の流れ
  - `AudioSource.swift`: `MicSource` / `FileSource` (`--replay` 用) / `WavWriter`
  - `SystemAudioHardware.swift` / `SystemAudioCapture.swift` / `MicAndSystemSource.swift`: 出力の判定、プロセスタップとマイクの同時取り込み、継続的な変換、失敗時のマイクへの切替
  - `AppleTranscriber.swift` / `SpeakerDiarizer.swift`: エンジンのラッパー
  - `StartSheet.swift`: 録音開始シート。会議ごとの話者判別・議事録・自動送信を `session.start` の前に決める
  - `TranscriptWindow.swift` / `StatusItem.swift` / `AppDelegate.swift`
  - `AI*.swift` / `Minutes*.swift`: AI参加のherdr接続・会議の記録・進行表示と、議事録ペイン
- `Tests/`: ユニットテスト (swift-testing)
  - `KikigakiCoreTests`: ロジック層。主戦場
  - `KikigakiAppTests`: AppKitとセッション。撮影用の環境変数は [開発用のフラグと環境変数](docs/dev-flags.md)
  - `KikigakiCLITests`: 同梱CLI
- `Resources/`: アプリバンドル用の Info.plist。マイクの `NSMicrophoneUsageDescription`、システム音声の `NSAudioCaptureUsageDescription`、URLスキームの `CFBundleURLTypes` を含む
- `skills/kikigaki/`: AI参加者用の配布Skill。`.app` へ同梱し、同梱CLIの `skill install` が利用者のSkill置き場へリンクする
- `web/minutes/`: 議事録の描画資産のソース。再生成は [議事録の描画と検索](docs/minutes-rendering.md)
- `site/`: 利用者向けのサイト。Astro 1本で、トップのティザーは `src/pages/index.astro`、ドキュメントはStarlightで `src/content/docs/docs/` に置く
  - 配信先はGitHub Pagesの `https://tadashi-aikawa.github.io/kikigaki/`。ドキュメントは `/kikigaki/docs/` 以下
  - ビルドは `pnpm --dir site install --frozen-lockfile` と `pnpm --dir site build`。mainへのpushで `.github/workflows/pages.yml` が配備する
  - トップの絵・動画・キャプチャは `public/illustrations/` `public/demos/` `public/captures/` に置くと出る。無ければ仮置きを出す。ファイル名は `index.astro` の `Media` の `src`
  - ドキュメントは `docs/` の正本を利用者の言葉で書き直したもの。分担と対応表は「変える前に知っておくこと」の「利用者向けドキュメントとの分担」
- `experiments/nemotron/`: 話者判別モデルの比較用の独立CLI。アプリにはエンジンの切替を置かない
- `experiments/system-audio/`: システム音声とマイクの同時取り込みを検証する独立CLI。検証記録は [システム音声取り込みの実現性試作](docs/records/system-audio-spike.md)
- `scripts/`: アプリバンドル組み立て・リリース成果物・Cask・tap更新
  - `make-app.sh`: `Contents/Helpers/kikigaki-cli` と `Contents/Resources/skills/kikigaki`、本体と第三者のライセンスを置く `Contents/Resources/licenses` を同梱し、helperを先に署名してから.appを署名する。配布ZIPでもhelperとSkillの存在、helperの署名を検証する
  - `build_release.sh`: リリース成果物 (ZIP) を作る
  - `render_cask.sh`: Cask本文を標準出力へ書く
  - `update_tap.sh`: 本文をtapへ置くだけにして、pushせずに `brew audit --cask` や手元tapでの導入・削除を試せるようにする
  - `make-icon.sh`: 配布用アイコンの再生成。手順は [ロゴの管理](docs/logo.md)

設計上の前提と判断の理由は各ファイルのコメントに書いてあります (プロトで反証された仮定を含む)。変える前に読んでください。

## 変える前に知っておくこと

コードを変える前に踏みやすい前提。理由と条件は各リンク先が正本。

- 設定ファイルへ書き戻さない: 録音開始シートや画面で決めた値はその会議だけに効く。書き戻すと設定ファイルの正本が2つになる。[録音開始シート](docs/start-sheet.md)
- 廃止して戻さないと決めたもの: 詳細は各リンク先
  - グローバルショートカット。[録音開始シート](docs/start-sheet.md)
  - 短い別話者区間をフレーズの多数派へ吸収する補正。[話者の割当と固定](docs/speaker-assignment.md)
  - 稼働中のherdrペインへ接続する `attach` / `displayAgent` と、会議に紐づかない準備済みAIセッション。[AI設定の複数プロファイル](docs/ai-profiles.md)
  - AIの返事の未読表示と既読操作。[AIへの定期自動送信](docs/ai-scheduled.md)
  - 単数の `[ai]`。設定エラーにして `[[ai]]` を示す。[設定リファレンス](docs/config.md)
- 停止後は新しい依頼を送れない: 「手動実行…」「返答する」「再送」は停止で無効になり、後片付けの後にherdrのペインを閉じる。[AI参加者の設計](docs/ai-participant.md)
- 利用者のグローバル設定は書き換えない: CodexとClaudeの設定は、セッション限定の引数と専用の `--settings` JSONで渡す。[AI参加者の設計](docs/ai-participant.md)
- manifestが欠損した会議登録は保持するが、対処できない警告は出さない。`AIRecordStore` の復元がこの扱い
- 受け入れたリスク
  - `outputDir` をCodexの書き込み許可へ加えるため、全会議のMarkdown・state・archive・minutes・返送tokenを含むrequestsをモデルから書き換えられる。会議Markdownを直接編集しない制約はSkillの規則で、サンドボックスでは保証されない。[議事録プレビューの設計](docs/minutes-preview.md) の「Skillの規則と書き込み許可」
  - 速報を並走させると高精度側の認識結果も変わり、語尾や助詞が落ちやすくなる。認識品質の検証は等倍で行う。[文字起こしの速報表示](docs/fast-transcription.md)
  - 話者補正が残す限界。吸収の廃止で元の形に戻る事例を含む。[話者の割当と固定](docs/speaker-assignment.md) の「受け入れた限界」
- テストが本文を読む文書: `docs/board.md` の内蔵プロンプトの全文はテストが `BoardPrompt.builtIn` と機械照合する。囲みのコードフェンスを崩さない。[議論のボード](docs/board.md)
- 文書の置き場
  - `docs/` 直下は現行仕様の正本だけを置く。同じ仕様を複数の文書に書かず、正本を1つに決めて他は1行とリンクにする
  - 試験・検証の記録、廃止した機能の条件、設計時の実装順は `docs/records/` へ置く。冒頭に時点と「現行の仕様ではない」旨を書き、本文は書き換えない
  - 文書を移す・消すときは、この索引と `README.md`、`Sources/` ・ `Tests/` ・ `scripts/` のコメントにある文書パスを直す
  - このファイルには機能ごとの振る舞いを書かない。振る舞いは正本の文書へ書く
- 利用者向けドキュメント (`site/src/content/docs/docs/`) との分担
  - 読み手が違う。`docs/` は開発者とAIエージェント向けの仕様、`site/` は利用者向け。実装名・ファイル名・設計の理由・受け入れたリスクの内訳は `site/` に書かない
  - 振る舞いを変えたら、`docs/` の正本を直し、下の「利用者向けページの対応」で該当ページを引いて同じ変更で直す。片方だけ直したコミットを作らない
  - 両方に書く情報は、利用者の言葉で言い直した重複として許す。ただし値 (既定値、上限、ファイル名、コマンド) は `docs/` を正本にし、食い違ったら `site/` を直す
  - 利用者だけに要る情報 (導入手順、データの行き先の表、業務利用の注意) は `site/` を正本にしてよい。その場合は `docs/` に書かず、必要なら `docs/` からサイトのページへリンクする
  - 事実は `docs/` とコードで確かめてから書く。README・記憶・既存のサイト本文から写さない

### 利用者向けページの対応

| 利用者向けページ | 元になる正本 |
| --- | --- |
| `getting-started.md` はじめに・インストール | README の導入、[Nemotron fast128 への話者判別の切替](docs/nemotron-integration.md) のモデル取得 |
| `recording.md` 録音と書き起こし | [録音開始シート](docs/start-sheet.md)、[発話の確定表示](docs/utterance-progress.md)、[話者判別の切替](docs/diarization-toggle.md)、[話者の手動統合](docs/speaker-mapping.md)、[小音量発話の除外](docs/audio-exclusion.md)、[手入力の設計](docs/typed-entry.md)、[書き起こしウィンドウ](docs/transcript-window.md) |
| `online-meetings.md` オンライン会議で相手の声を取り込む | [システム音声の取り込み](docs/system-audio.md) |
| `ai-participant.md` AIを会議に参加させる | [AI参加者の設計](docs/ai-participant.md)、[AI設定の複数プロファイル](docs/ai-profiles.md)、[AIへの定期自動送信](docs/ai-scheduled.md)、[AIを会話の参加者として並べる](docs/ai-timeline.md)、[AIへの受け渡し](docs/ai-handoff.md) |
| `minutes-and-board.md` 議事録とボード | [議事録ペイン](docs/minutes-pane.md)、[議事録の描画と検索](docs/minutes-rendering.md)、[議事録プレビューの設計](docs/minutes-preview.md)、[議論のボード](docs/board.md)、[録音開始シート](docs/start-sheet.md) の `kikigaki://start` |
| `data.md` データの行き先 | サイト側が正本。根拠は [議事録プレビューの設計](docs/minutes-preview.md) の書き込み許可、[AI参加者の設計](docs/ai-participant.md) の受け渡し、[設定リファレンス](docs/config.md) の保存物 |
| `configuration.md` 設定リファレンス | [設定リファレンス](docs/config.md)、[AI設定の複数プロファイル](docs/ai-profiles.md) |

## 文書の索引

`docs/` の現行仕様の文書。変える部分に近いものを、コードを変える前に読む。

| 文書 | 内容 | 読むとき |
| --- | --- | --- |
| [設定リファレンス](docs/config.md) | `config.toml` の全キー、廃止したキー、画面で決める値 | 設定キーを足す・変えるとき |
| [開発用のフラグと環境変数](docs/dev-flags.md) | 起動フラグ、replay、検証・撮影用の環境変数 | replayや検証ハーネスを使う・足すとき |
| [発話から文字・話者確定までのフロー](docs/utterance-flow.md) | 文字起こしから話者の確定、表示までの流れと実コードの対応 | 発話の処理全体を追うとき。最初に読む |
| [文字起こしの速報表示](docs/fast-transcription.md) | 速報と高精度の合流、確定数、AI送信の待ち | `AppleTranscriber` ・ `TranscriptMerge` ・確定数を変える前 |
| [発話の確定表示](docs/utterance-progress.md) | 行の半透明と通常の濃さの条件 | 行の確定前後の表示を変える前 |
| [話者の割当と固定](docs/speaker-assignment.md) | 補正の順序、語内補正、被りの島、フレーズ凍結、受け入れた限界 | `Aligner` ・ `SpeakerIslands` ・ `SpeakerFreeze` の判定を変える前 |
| [話者判定の再比較手順](docs/speaker-compare.md) | 入力の保存と、本番の判定を同じ入力へ当て直す手順 | 話者補正を変えて前後を比べるとき |
| [Nemotron fast128 への話者判別の切替](docs/nemotron-integration.md) | 依存、モデル、区間化、失敗の扱い、8枠、保存互換 | `SpeakerDiarizer` ・ `SpeakerRuns` ・FluidAudioを変える前 |
| [話者判別の切替](docs/diarization-toggle.md) | 話者判別のオン・オフ、無効時の行分割 | 話者判別の有効・無効の経路を変える前 |
| [システム音声の取り込み](docs/system-audio.md) | 開始シートの3択、出力判定、同時取り込みと混合、失敗時の扱い | 音源・混合・システム音声の許可を変える前 |
| [話者の手動統合](docs/speaker-mapping.md) | 統合先の指定と解除、使用枠 | 統合・枠の数え方を変える前 |
| [小音量発話の除外](docs/audio-exclusion.md) | 除外の判定、操作、保存・コピー・AI送信への適用 | 除外の判定や適用先を変える前 |
| [小音量発話の計測](docs/audio-levels.md) | 音量トラックと診断表示、`.levels.json` | 音量の計測・保存を変える前 |
| [手入力の設計](docs/typed-entry.md) | 手入力の投稿、画像添付、併合、AI文脈 | 手入力・`TranscriptEntries.merge` を変える前 |
| [録音開始シート](docs/start-sheet.md) | 会議ごとの指定、`kikigaki://start` | 開始経路・URLスキームを変える前 |
| [書き起こしウィンドウ](docs/transcript-window.md) | 配色、行の構造、改名、フッター、ピン留め、幅 | ウィンドウの見た目・操作を変える前 |
| [議事録ペイン](docs/minutes-pane.md) | 右ペインの操作、履歴、幅と復元、ファイル監視 | 議事録ペインのUIを変える前 |
| [議事録の描画と検索](docs/minutes-rendering.md) | 対応する記法、検索、Wikiリンク、描画資産の再生成 | 議事録の描画・`web/minutes` を変える前 |
| [議事録プレビューの設計](docs/minutes-preview.md) | 議事録の受け渡し、`ai/minutes.json`、書き込み許可と受け入れたリスク | 議事録の書き先・通知・Codexの許可を変える前 |
| [議事録プレビューの表示例](docs/minutes-preview-example.md) | 描画の確認に使う議事録の例 | 描画を目で確かめるとき |
| [議論のボード](docs/board.md) | ボードの設定、内蔵プロンプト、見出しの扱い | ボード・`BoardPrompt` を変える前。テストが本文を読む |
| [AI参加者の設計](docs/ai-participant.md) | 会議参加モードの契約、envelope、受信箱、同梱CLI、Skill、フック、停止後の後片付け | AI参加・同梱CLI・返送・Skillを変える前 |
| [AIへの受け渡し](docs/ai-handoff.md) | 「会話をコピー」と会話ファイルの契約 | 手動コピーを変える前 |
| [AI設定の複数プロファイル](docs/ai-profiles.md) | `[[ai]]` のキー・検証、宛先の選択 | `AIConfig` ・宛先選択を変える前 |
| [AIへの定期自動送信](docs/ai-scheduled.md) | 自動送信の状態機械、ロボットの操作、最後の1回 | 自動送信・ロボットの表示を変える前 |
| [AI依頼の進行表示](docs/ai-progress.md) | 返事待ち行の進行文と4分割バー | `AIProgress` を変える前 |
| [AIを会話の参加者として並べる](docs/ai-timeline.md) | AIの行の種類と並べ方 | AIの行・送信の印を変える前 |
| [AIの返事のMarkdown表示](docs/ai-markdown.md) | 返事本文の分解と描画 | `MarkdownBlocks` を変える前 |
| [ロゴの管理](docs/logo.md) | 元画像と配布用アイコン | ロゴ・アイコンを変える前 |

`docs/records/` は試験・検証の記録。現行の仕様ではない。仕様を確かめるときは上の表の文書を読み、経緯を調べるときだけ開く。

- [繰り返し相槌の省略の旧仕様](docs/records/repeated-backchannels.md)
- [議事としての話者判定と発話分割の改善計画](docs/records/minutes-quality-plan.md)
- [短い返答の話者を残す条件](docs/records/short-speaker-turns.md)
- [話者交代の語頭・語尾補正の測定記録](docs/records/speaker-boundaries.md)
- [話者補正の除外比較とフレーズ固定の試験](docs/records/speaker-correction-trial.md)
- [被りの島の補正を段階的に強める試験](docs/records/speaker-overlap-islands.md)
- [Nemotron fast128 への切替の検証記録](docs/records/nemotron-verification.md)
- [システム音声取り込みの実現性試作の検証記録](docs/records/system-audio-spike.md)
- [議事録プレビューの実装記録](docs/records/minutes-preview-implementation.md)
- [会議参加モードの検証項目と段1〜5の実装記録](docs/records/ai-participant-implementation.md)
- [AI参加者の通信境界: 段2の実測](docs/records/ai-participant-spike.md)
- [AI設定の複数プロファイルの実装順の記録](docs/records/ai-profiles-implementation.md)
- [定期自動送信の検証計画と段2〜4の実装記録](docs/records/ai-scheduled-implementation.md)
- [定期自動送信の結合検証](docs/records/ai-scheduled-verification.md)
- [AIを会話の行として並べる表示の段1〜3の記録](docs/records/ai-timeline-implementation.md)
- [AIを会話の行として並べる表示の結合検証](docs/records/ai-timeline-verification.md)
- [AI依頼の進行表示の検証記録](docs/records/ai-progress-verification.md)
- [議論のボードの検証記録と受入手順](docs/records/board-verification.md)

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
- `scope`: `session`, `aligner`, `window`, `config` など機能単位 (省略可)
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

起動フラグ、replayの指定、検証・撮影用の環境変数の一覧は [開発用のフラグと環境変数](docs/dev-flags.md) を参照してください。

### 検証の注意

- プロトと同じ音声で保存結果が一致することは移植の検証です。精度や録音中の表示の安定性は別に確認します
- `KIKIGAKI_DEBUG_LIVE` が出すのは停止直前の1回分です。録音中の全時点の検証には、途中の表示と、その時点の確定・暫定トークンを確認する必要があります
- `KIKIGAKI_DEBUG_PHRASES` の変更前の話者も、前後0.5秒の窓で集計した推定値です。実際の発話者の正解ラベルではありません。話者の割当を評価するときは、原音と突き合わせます
- 修正前後を比べるときは、入力音声を揃え、出力先をそれぞれ別の検証用ディレクトリにします。ビルドの終了コードが成功であることを確認してから実行します

## リリース方法

GitHub Actions の `Release` workflow を `main` ブランチから手動実行します。

semantic-release が前回のタグ以降の Conventional Commits から次のバージョンを決定し、`v<バージョン>` タグ、リリースノート、`KIKIGAKI-<バージョン>.zip` (署名済み KIKIGAKI.app) を含む GitHub Release を作成し、homebrew-tap の Cask (`kikigaki`) を更新します。リリース対象となるコミットがなければ何も公開しません。

- 署名は自己署名証明書 `kikigaki-dev` で固定します (repo secrets: `MACOS_CERT_P12_BASE64` / `MACOS_CERT_PASSWORD`)。マイクの TCC 許可をリリースをまたいで維持するためです
- tap 更新には repo secret `TAP_GITHUB_TOKEN` (homebrew-tap への Contents: Read and write 権限の fine-grained PAT) を使います
- `Resources/Info.plist` の追跡中のバージョンは `0.0.0-development` のまま維持し、リリースバージョンは配布 ZIP 内にだけ埋め込みます
- Cask の本文は `scripts/render_cask.sh <バージョン> <sha256>` が書き出します。tap へ push する前に、この出力を手元の tap へ置いて `brew audit --cask` と導入・削除を確認できます
