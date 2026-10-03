# 設定リファレンス

`~/.config/kikigaki/config.toml` (TOML) の全キーを1か所で引けるようにする。すべて省略可で、省略時は既定値。ファイルが無くても起動する。

- 変更の反映: メニューバーのフクロウの「設定を再読込」で読み直す。AIの設定は会議開始時に固定するため、進行中の会議には効かず、次の会議から反映する
- 読み込めないとき: 構文や検証に失敗すると再読込は止まり、理由を表示する
- 画面から決める値は設定ファイルへ書き戻さない。下の「設定ファイルで決めないもの」を参照する

## 設定例

```toml
# Markdown (と録音WAV) の保存先。既定: ~/Documents/KIKIGAKI
outputDir = "~/Documents/KIKIGAKI"
# 録音WAVを Markdown と並べて残すか。既定: false (通常利用では不要でディスクを食うだけ)
saveRecording = false
# 診断表示: 発話ごとの音量と候補を表示・別途保存する。除外設定とは独立。既定: false
measureAudioLevels = false

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
autoStart = true          # 録音開始シートの宛先の既定になる。配列で1つまで
# 手動・自動実行シートと録音開始シートのプロンプト初期値
autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください" # 省略時は空欄
# board = "## ボード"          # 自動はこの見出しだけ更新。autoPromptは手動の初期値
# boardLocation = "~/Documents/minutes/${yyyyMMdd_HHmmss}.md として作成し、変数は現在日時" # パス未指定時の作成指示
# boardPrompt = "独自のボードのプロンプト全文" # board指定時のみ。省略時は内蔵
autoIntervalMinutes = 3 # 1〜60分、省略時は3分

[[ai]]
name = "相談"
cli = "claude"
effort = "max"
address = "ネオへ"
```

## 共通のキー

| キー | 既定 | 説明 |
| --- | --- | --- |
| `outputDir` | `~/Documents/KIKIGAKI` | Markdown (と録音WAV) の保存先。絶対パスか `~` 始まりだけを受け付ける。相対パスと空文字は設定エラー |
| `saveRecording` | `false` | 録音WAVを Markdown と並べて残す |
| `measureAudioLevels` | `false` | 発話ごとの音量と小音量候補の診断表示と保存。除外の設定とは独立。次の会議から効く。詳細は [小音量発話の計測](audio-levels.md) |

`outputDir` は Codex の書き込み許可にも追加する。議事録を書けるようにするためで、許可の範囲と受け入れたリスクは [議事録プレビューの設計](minutes-preview.md) の「Skillの規則と書き込み許可」を参照する。

### 保存されるファイル

保存先には 1会議1ファイルで `2026-09-05_1240.md` の形の名前を書く。

- `.wav`: `saveRecording = true` のとき、同名で並べる
- `.levels.json`: `measureAudioLevels = true` のとき、音量の記録を同名で残す
- `<会議名>.attachments/`: 手入力へ貼り付けた画像。詳細は [手入力の設計](typed-entry.md)
- 同じ分に録音を始め直した場合は、既存の保存物があれば `_2`、`_3` と連番を付ける

## 話者台帳 `[[speakers]]`

話者名の候補とアバターの台帳。名前をクリックして選ぶ操作は [書き起こしウィンドウ](transcript-window.md) の「話者台帳とクリック改名」を参照する。

| キー | 説明 |
| --- | --- |
| `name` | 話者名。空と重複は設定エラー |
| `avatar` | 省略可。ローカルパス (`~/` 始まりも可) か HTTP・HTTPS の画像URL |

- 取得できない画像は、枡の色の地にイニシャルを出す
- URL画像は `~/Library/Caches/kikigaki/avatars/` へキャッシュする。AIのアバターと共通
- 台帳の変更は「設定を再読込」で反映する

## AI参加 `[[ai]]`

`[[ai]]` を書くと、herdr の専用ペインで動く Codex・Claude Code を会議へ参加させられる。書かなければAI機能は無効。配列の1つ目が既定で、送信ごとに宛先を選べる。単数の `[ai]` は互換で読む。

キーの既定値・検証・振る舞いの正本は [AI設定の複数プロファイル](ai-profiles.md)。ここには一覧と1行の説明だけを置く。

| キー | 既定 | 説明 |
| --- | --- | --- |
| `name` | `address` から導く参加者名 | プロファイルの表示名。重複は設定エラー |
| `cli` | `codex` | `codex` か `claude` |
| `command` | PATH と既知の置き場から探す | CLIの絶対パス。見つからないときだけ指定する |
| `herdrCommand` | PATH と既知の置き場から探す | herdr の絶対パス。全プロファイル共通で、2つ目以降は省略でき先頭の値を引き継ぐ。先頭と違う値を明示すると設定エラー |
| `model` | CLIの既定 | モデル名 |
| `effort` | CLIの既定 | 推論の強さ。CLIごとの引数へ翻訳する。値域は下記 |
| `address` | `迅雷へ` | 宛名。末尾の「へ」を除いた部分が参加者名になる |
| `avatar` | 紫のイニシャル | AIの返事行の画像。話者台帳と同じローカルパスか HTTP・HTTPS のURL |
| `cwd` | 固定の既定 | 起動時の作業ディレクトリ。絶対パスか `~/` 始まり |
| `extraArgs` | 空 | CLIへの追加引数。対応済みの指定だけを受け付ける |
| `prompt` | 空 | 全送信に付く追加指示 |
| `notifySound` | `false` | 返事が届いたときの通知音。返答元の設定で鳴らす |
| `allowWork` | `true` | 送信シートの「作業を許可する」の初期値 |
| `autoStart` | `false` | 録音開始シートの自動送信の宛先の既定にする。配列全体で1つまで。`board` を指定しない宛先は `autoPrompt` が必要 |
| `autoPrompt` | 空 | 手動・自動実行シートと録音開始シートのプロンプト初期値 |
| `autoIntervalMinutes` | `3` | 自動送信の間隔。1〜60分 |
| `board` | ボードなし | ボードとして自動更新する見出し。1行のMarkdown見出し。宛先間で同じ見出しを使える |
| `boardPrompt` | 内蔵 | ボードのプロンプト全文の差し替え。`board` があるときだけ指定できる |
| `boardLocation` | なし | 議事録のパスが無いときの作成指示。`board` があるときだけ指定できる。変数はAIが解釈し、アプリでは展開しない |

- `effort` の値域: Codex は `none` / `minimal` / `low` / `medium` / `high` / `xhigh` / `max` / `ultra` を `-c model_reasoning_effort` へ渡す。Claude は `low` / `medium` / `high` / `xhigh` / `max` を `--effort` へ渡す
    - 注意: 実際に通る値はモデルによる
    - 注意: `extraArgs` での effort 指定は二重指定になるため設定エラー
- CLIとherdrの探し方: PATH のほか `~/.local/bin`・mise の shims・Homebrew を探す。見つからないときは `command` / `herdrCommand` の絶対パスで指定する。詳細は [AI設定の複数プロファイル](ai-profiles.md) の「CLIとherdrの実行ファイルの探し方」
- 宛先の選び方: 「手動実行…」と「自動実行…」のシートと録音開始シートで送信ごとに選ぶ。詳細は [AI設定の複数プロファイル](ai-profiles.md)
- 自動送信の始まり方: 詳細は [AIへの定期自動送信](ai-scheduled.md) と [録音開始シート](start-sheet.md)
- ボード: `board` の設定・内蔵文面・限界は [議論のボード](board.md)
- 手動コピーだけで使う場合は `[[ai]]` を書かなくてよい。手順は [会議中の会話をAIへ渡す](ai-handoff.md)

## 廃止したキー

設定ファイルに残っていても、次のように扱う。

- `dropRepeatedBackchannels`: 廃止した実験機能のキーとして、値や型に関係なく読み飛ばす。エラーにも警告にもしない。
    - 理由: 既存の設定ファイルを書き換えずに済ませるため

- `[hotkeys]` と `[ai.hotkey]`: グローバルショートカットの廃止に伴い、読み飛ばす。エラーにも警告にもしない。既存の設定ファイルを書き換えずに済ませるため
- `maxSpeakers`: 話者の人数上限設定の廃止に伴い、無視する
- `attach` と `displayAgent`: 稼働中のherdrペインへ接続する案の取り下げに伴い、書くと設定エラーにする。KIKIGAKI が自分でセッションを起こす。経緯は [AI設定の複数プロファイル](ai-profiles.md) の「取り下げた案(経緯)」
- 会議に紐づかない「準備済みAIセッション」: 実装ごと撤去した。利用者の台帳 `~/Library/Application Support/KIKIGAKI/ai-prepared.json` と準備用の置き場は読まず、消さない

## 設定ファイルで決めないもの

会議ごとに変える値や、画面で操作する値は設定ファイルへ書かない。

- 小音量の除外のON/OFFとしきい値: 「話者」ポップアップと録音開始シートで決める。詳細は [小音量発話の除外](audio-exclusion.md)
- 話者判別の有効・無効: 録音開始シートで決める。初期値は有効で、選択は記憶する。詳細は [話者判別の切替](diarization-toggle.md)
- 話者名の変更と話者の統合: ウィンドウ上で操作する。詳細は [書き起こしウィンドウ](transcript-window.md) と [話者の手動統合](speaker-mapping.md)
- 会議ごとの議事録・自動送信の指定: 録音開始シートで決める。詳細は [録音開始シート](start-sheet.md)
