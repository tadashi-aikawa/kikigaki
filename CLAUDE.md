# CLAUDE

## プロダクト

KIKIGAKI(聞き書き)は、会議の発話をマイクから聴いて話者付きでリアルタイムに文字起こしし、Markdown で残す macOS ネイティブアプリ (Swift) です。

- 文字起こし: Apple の Speech フレームワーク `SpeechTranscriber` (macOS 26 以降、端末内処理)
- 話者判別: FluidAudio の Sortformer (ストリーミング、最大4話者)。FluidAudio への依存はこのためだけ
- 音源は MVP ではマイクのみ。`AudioSource` プロトコルで差し替えられるようにしてあり、システム音声は次の段で足す

## リポジトリ構成

- `Sources/KikigakiCore/`: 純粋ロジック層 (Foundation + TOMLKit のみ。ユニットテストの主戦場)
  - `Aligner.swift`: トークン時刻と話者区間の突き合わせ。フレーズ単位の多数決・島の扱い・決定的な同点処理
  - `SpeakerFreeze.swift`: 8秒より古い話者判定の凍結 (Sortformer の暫定区間が過去へ届いても表示を動かさない)
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

# グローバルショートカット。既定は ctrl+alt+cmd+K (開始/停止) と ctrl+alt+cmd+P (一時停止/再開)
[hotkeys.toggleRecording]
modifiers = ["ctrl", "alt", "cmd"]
key = "k"

[hotkeys.togglePause]
modifiers = ["ctrl", "alt", "cmd"]
key = "p"
```

保存先には `2026-09-05_1240.md` (有効時は同名の `.wav`) を1会議1ファイルで書きます。

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

FluidAudio の Sortformer モデルは初回起動時に HuggingFace から `~/Library/Application Support/FluidAudio/Models` へ落ちます。Apple Speech の日本語アセットも初回に自動取得されます。

## リリース方法

GitHub Actions の `Release` workflow を `main` ブランチから手動実行します。

semantic-release が前回のタグ以降の Conventional Commits から次のバージョンを決定し、`v<バージョン>` タグ、リリースノート、`KIKIGAKI-<バージョン>.zip` (署名済み KIKIGAKI.app) を含む GitHub Release を作成し、homebrew-tap の Cask (`kikigaki`) を更新します。リリース対象となるコミットがなければ何も公開しません。

- 署名は自己署名証明書 `kikigaki-dev` で固定します (repo secrets: `MACOS_CERT_P12_BASE64` / `MACOS_CERT_PASSWORD`)。マイクの TCC 許可をリリースをまたいで維持するためです
- tap 更新には repo secret `TAP_GITHUB_TOKEN` (homebrew-tap への Contents: Read and write 権限の fine-grained PAT) を使います
- `Resources/Info.plist` の追跡中のバージョンは `0.0.0-development` のまま維持し、リリースバージョンは配布 ZIP 内にだけ埋め込みます
