# CLAUDE

## プロダクト

KIKIGAKI(聞き書き)は、会議の発話をマイクから聴いて話者付きでリアルタイムに文字起こしし、Markdown で残す macOS ネイティブアプリ (Swift) です。

- 文字起こし: Apple の Speech フレームワーク `SpeechTranscriber` (macOS 26 以降、端末内処理)
- 話者判別: FluidAudio の Sortformer (ストリーミング、最大4話者)。FluidAudio への依存はこのためだけ
- 音源は MVP ではマイクのみ。`AudioSource` プロトコルで差し替えられるようにしてあり、システム音声は次の段で足す

## リポジトリ構成

- `Sources/KikigakiCore/`: 純粋ロジック層 (Foundation + TOMLKit のみ。ユニットテストの主戦場)
  - `Aligner.swift`: トークン時刻と話者区間の突き合わせ。フレーズ単位の多数決・島の扱い・決定的な同点処理
  - `SpeakerFreeze.swift`: 文字起こしの確定結果に属する、8秒より古いトークンの話者判定を凍結。暫定結果は凍結しない
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

`~/.config/kikigaki/config.toml` (TOML)。設定UIはありません。すべて省略可で、省略時は既定値です。

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
```

保存先には `2026-09-05_1240.md` (有効時は同名の `.wav`) を1会議1ファイルで書きます。

同じ分に録音を始め直した場合、既存の保存物があれば `_2`、`_3` と連番を付けます。

`dropRepeatedBackchannels = true` は、停止時に「うんうん」「そうそう」など短い反復の候補を省きます。録音中は省略せず、通常の `.md` と停止後の画面へ省略結果を反映し、省略前の書き起こしは同名の `.raw.md` に残します。話者名の変更は両方へ反映します。原文ファイルの保存に失敗した会議は、通常の `.md` と画面へ原文を残します。

1回だけの相槌や同じ話者に判定された繰り返しは対象外です。実際の発話者を保証する機能ではなく、誤った省略もあり得ます。詳細は [繰り返し相槌の仕様と検証](docs/repeated-backchannels.md) を参照してください。設定変更は次の録音から適用します。

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
- 環境変数 `KIKIGAKI_DEBUG_LIVE=1`: 停止直前の録音中表示を stderr に出す (録音中と最終結果の差を調べる用)
- 環境変数 `KIKIGAKI_DEBUG_PHRASES=1`: 停止時のフレーズごとに、トークンの時刻と窓判定から多数決後への話者の変化を stderr に出す

### 表示品質の検証

録音中は確定した文字起こしの古いトークンだけ話者判定を凍結し、停止時は凍結を外して全体を再判定します。文字起こしの確定と話者判定の正しさは別であり、確定した文字列でも話者は誤ることがあります。

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
