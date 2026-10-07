---
title: 設定リファレンス
description: config.toml に書ける設定と、画面で選ぶもの
---

保存先やAIへの頼み方を、`~/.config/kikigaki/config.toml` で決められます。
書けるすべてのキーと、既定値・設定例をまとめます。

## 設定ファイルの基本

- 書式はTOMLです
- どのキーも省略できます
    - 動き: 省略したキーは既定値になります
- ファイルが無くても起動します
- 書き換えたら、メニューバーのメニューの「設定を再読込」で読み直します
    - 反映: AIの設定は会議の開始時に決まります。次の会議から効きます
- 書式や値が正しくないと、読み直しを止めて理由を表示します
- 開始シートや画面で決めた値は、設定ファイルへ書き戻しません

## 設定例

```toml
# Markdown (と録音WAV) の保存先。既定: ~/Documents/KIKIGAKI
outputDir = "~/Documents/KIKIGAKI"
# 録音WAVを Markdown と並べて残すか。既定: false
saveRecording = false
# 発話ごとの音量と除外候補を表示・保存する診断表示。既定: false
measureAudioLevels = false

# 話者名の候補とアバター
[[speakers]]
name = "田中"
avatar = "~/Pictures/avatars/tanaka.png"

[[speakers]]
name = "迅雷"
avatar = "https://example.com/jinrai.webp"

# AI参加を有効にする。書かなければAI機能は無効。1つ目が既定
[[ai]]
name = "議事録"           # 省略時は address から導く名前。重複は不可
cli = "codex"
address = "迅雷へ"
avatar = "~/Pictures/jinrai.png" # 省略時は紫のイニシャル。http/httpsのURLも使える
effort = "high"           # 推論の強さ
notifySound = false       # 返事が届いたときの通知音
cwd = "~/work/minutes"    # 起動時の作業ディレクトリ。省略時は固定の既定
autoStart = true          # 録音開始シートの自動送信の既定にする。全体で1つまで
# 手動・自動実行シートと録音開始シートのプロンプト初期値
autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください"
autoIntervalMinutes = 3   # 1〜60分

[[ai]]
name = "相談"
cli = "claude"
effort = "max"
address = "ネオへ"
```

## 共通のキー

| キー | 既定 | 説明 |
| --- | --- | --- |
| `outputDir` | `~/Documents/KIKIGAKI` | Markdownと録音WAVの保存先。絶対パスか `~` から始まるパスで書く。相対パスと空文字は設定エラー |
| `saveRecording` | `false` | `true` で、録音WAVをMarkdownと同じ名前で並べて残す |
| `measureAudioLevels` | `false` | `true` で、発話ごとの音量と小音量の候補を画面に出し、`.levels.json` とMarkdown末尾の表に残す。音量を調べるための表示。次の会議から効く |

- `measureAudioLevels` は、小さな声を除外する設定とは別です
- `outputDir` は、AI参加でCodexに書き込みを許可する場所でもあります
    - 詳細: [データの行き先](../data/)
- 保存されるファイルの名前と中身は [録音と書き起こし](../recording/) を参照してください

## 話者の候補 `[[speakers]]`

話者名をクリックしたときに出す候補とアバターです。
1人ごとに `[[speakers]]` を1つ書きます。

| キー | 既定 | 説明 |
| --- | --- | --- |
| `name` | なし | 話者名。空と重複は設定エラー |
| `avatar` | なし | 省略可。画像のローカルパスか、HTTP・HTTPSの画像URL。`~/` から始まるパスも使える |

```toml
[[speakers]]
name = "田中"
avatar = "~/Pictures/avatars/tanaka.png"
```

- 画像を読み込めないときは、話者の色の上に名前の頭文字が出ます
- URLの画像は `~/Library/Caches/kikigaki/avatars/` に保存します
- アバター画像は1枚10MiB、全フレーム合計4,000万画素までです
    - 対象: ローカルの画像とURLの画像に共通です
    - 失敗時: 読めない画像は保存せず、名前の頭文字を表示します
- URL画像の読み込み失敗の記録には、接続方法・サーバー名・画像のパスだけを残します
- 候補の変更も「設定を再読込」で反映します

## AI参加 `[[ai]]`

`[[ai]]` を書くと、[herdr](https://herdr.dev/) の専用ペインでCodex・Claude Codeが会議に参加します。
書かなければAI機能は無効です。
複数書くと、送信ごとに宛先を選べます。1つ目が既定です。

使い方は [AIを会議に参加させる](../ai-participant/) を参照してください。

### 宛先と起動

| キー | 既定 | 説明 |
| --- | --- | --- |
| `name` | `address` から決まる名前 | 宛先の表示名。重複は設定エラー。自分で書く場合は64バイトまで |
| `cli` | `codex` | `codex` か `claude` |
| `command` | 自動で探す | CLIの絶対パス。見つからないときだけ書く |
| `herdrCommand` | 自動で探す | herdrの絶対パス。全宛先で共通。2つ目以降は省略でき、先頭の値を引き継ぐ。先頭と違う値を書くと設定エラー |
| `model` | CLIの既定 | モデル名 |
| `effort` | CLIの既定 | 推論の強さ。値は下記 |
| `address` | `迅雷へ` | 宛名。末尾の「へ」を除いた部分が会議でのAIの名前になる |
| `avatar` | 紫のイニシャル | AIの返事の行に出す画像。`[[speakers]]` と同じくローカルパスかHTTP・HTTPSのURL |
| `cwd` | `~/Library/Application Support/KIKIGAKI/ai-work/` | AIを起動する作業ディレクトリ。絶対パスか `~/` から始まるパスで、存在するディレクトリを書く |
| `extraArgs` | 空 | CLIへの追加の引数。使える指定は下記 |

### 送信

| キー | 既定 | 説明 |
| --- | --- | --- |
| `prompt` | 空 | すべての送信に付ける追加の指示。32 KiBまで |
| `allowWork` | `true` | 送信シートの「作業を許可する」の初期値 |
| `notifySound` | `false` | `true` で、この宛先から返事や確認質問が届いたときに通知音を鳴らす。自動送信への通常の返事では鳴らさない |

### 自動送信

| キー | 既定 | 説明 |
| --- | --- | --- |
| `autoStart` | `false` | `true` で、録音開始シートの自動送信の宛先の既定にする。全宛先で1つまで。`board` の無い宛先では `autoPrompt` が必要 |
| `autoPrompt` | 空 | 手動・自動実行シートと録音開始シートのプロンプトの初期値。32 KiBまで |
| `autoIntervalMinutes` | `3` | 自動送信の間隔。1〜60分。シートの選択肢に無い値も、その値で選べるようになる |

### ボード

| キー | 既定 | 説明 |
| --- | --- | --- |
| `board` | なし | ボードとして自動送信で更新する見出し。`## ボード` のような1行のMarkdown見出し。複数の宛先で同じ見出しを使える |
| `boardPrompt` | 内蔵 | ボードのプロンプトを全文差し替える。`board` があるときだけ書ける |
| `boardLocation` | なし | 議事録のパスが無いときの書き先をAIに伝える。`board` があるときだけ書ける。`${...}` や `~` はAIが解釈する |

ボードの使い方は [議事録とボード](../minutes-and-board/) を参照してください。

`boardLocation` の変数は、KIKIGAKIでは展開しません。

### `effort` の値

| `cli` | 書ける値 | CLIへの渡し方 |
| --- | --- | --- |
| `codex` | `none` `minimal` `low` `medium` `high` `xhigh` `max` `ultra` | `-c model_reasoning_effort="<値>"` |
| `claude` | `low` `medium` `high` `xhigh` `max` | `--effort <値>` |

- 使える値はモデルによります
    - 例外: CLIが受け付けないと、起動に失敗したことを表示します
- 推論の強さは `effort` に書いてください
    - 制約: `extraArgs` に書くと設定エラーです

### `extraArgs` で使える指定

`extraArgs` は文字列の配列で書きます。シェルの文字列ではありません。

```toml
extraArgs = ["--search", "--add-dir", "/Users/you/work/shared"]
```

| `cli` | 値なしの指定 | 決まった値だけを受け付ける指定 | 絶対パスを1つ受け付ける指定 |
| --- | --- | --- | --- |
| `codex` | `--search` `--no-alt-screen` `--strict-config` | `--sandbox` / `-s`: `read-only` `workspace-write` `danger-full-access`<br />`--ask-for-approval` / `-a`: `on-request` `never` | `--add-dir` |
| `claude` | `--verbose` | `--permission-mode`: `default` `manual` `acceptEdits` `plan` `auto` `dontAsk` | `--add-dir` |

- `--key=value` の形でも書けます
- 表に無い指定は設定エラーです
    - 対象: 起動時のプロンプト、サブコマンド、短い指定の連結、Codexの `-c` と `--config` も受け付けません
- 権限モードは、自分で書いたときだけ渡します
    - 動き: KIKIGAKIが自分で足すことはありません

### CLIとherdrの探し方

`command` と `herdrCommand` を省略すると、PATHのほかに次の場所を順に探します。

1. `~/.local/bin`
2. `~/.local/share/mise/shims`
3. `/opt/homebrew/bin`
4. `/usr/local/bin`

Finderなどから起動したKIKIGAKIでは、普段のシェルのPATHが使えません。
見つからないときは、絶対パスを書いてください。
herdrが見つからない間も、「会話をコピー」は使えます。

## 廃止したキー

設定ファイルに残っていると、次のように扱います。

| キー | 扱い |
| --- | --- |
| 単数の `[ai]` | 設定エラー。`[[ai]]` と書き直す |
| `[[ai]]` の `attach` と `displayAgent` | 設定エラー。起動中のherdrのペインへつなぐ機能は無くなった。KIKIGAKIが自分でAIを起動する |

「準備済みAIセッション」の機能も無くなりました。
以前の `~/Library/Application Support/KIKIGAKI/ai-prepared.json` と準備用の置き場は残ります。
KIKIGAKIは読みません。

不要なら、手で消してください。

単数の `[ai]` は、次のように `[[ai]]` へ書き直します。

```toml
# 以前の書き方。設定エラーになる
[ai]
cli = "codex"

# いまの書き方
[[ai]]
cli = "codex"
```

## 設定ファイルで決めないもの

会議ごとに変える値や、画面で操作する値は、設定ファイルには書きません。

| 値 | 決める場所 |
| --- | --- |
| システム音声の取り込み | 録音開始シート |
| 話者判別の有効・無効 | 録音開始シート。前回の選択を覚える |
| 小さな声の除外のオン・オフとしきい値 | 録音開始シートと、ウィンドウ上部の人型のボタン |
| 話者名の変更と話者の統合 | 書き起こしウィンドウ |
| 会議ごとの議事録と自動送信 | 録音開始シート |
