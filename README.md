<p align="center">
  <img src="Resources/kikigaki.png" alt="KIKIGAKIの会話フクロウ" width="180">
</p>

# KIKIGAKI

会議の発話を聴いて、話者付きでリアルタイムに文字起こしし、Markdownで残すmacOSアプリです。

フクロウの顔を2つの吹き出しで表したロゴが目印。朱色と生成りに、金のくちばしを添えています。

## できること

- マイクの音声を端末内で文字起こし
- 最大4話者の判別と、話者名の編集
- 録音の一時停止・再開
- 会議ごとのMarkdown保存と、任意のWAV保存
- 「会話をコピー」から、会話ファイルの参照と必要範囲をAIへ受け渡し

話者判別は推定です。必要に応じて書き起こしと話者を確認してください。

## 動作環境

- macOS 26以降
- マイクへのアクセス許可
- 初回セットアップ時のネットワーク接続

文字起こしにはApple Speech、話者判別にはFluidAudioのSortformerを使います。必要なモデル・言語アセットは自動でダウンロードします。

- 話者判別モデル: 初回のアプリ起動直後にHugging Faceから約241 MBを取得します。以後は保存済みモデルを再利用します。
- Apple Speechの日本語アセット: 未導入の場合、初めて録音を開始するときに別途取得します。容量は上記に含みません。

取得が完了するまで、録音開始は準備待ちになります。

## インストール

Homebrewで導入します。

```bash
brew install --cask tadashi-aikawa/tap/kikigaki
```

更新は次のコマンドです。

```bash
brew upgrade --cask kikigaki
```

自己署名(未公証)のアプリです。初回起動がブロックされた場合は、システム設定 → プライバシーとセキュリティ → 「このまま開く」で許可してください。

配布物は [Releases](https://github.com/tadashi-aikawa/kikigaku/releases) の `KIKIGAKI-<バージョン>.zip` からも取得できます。アプリ名はKIKIGAKIですが、GitHubリポジトリ名は `kikigaku` です。

### ソースからビルドする場合

macOS 26のSDKとSwift 6に対応するXcodeまたはCommand Line Toolsを用意し、以下を実行します。

```bash
git clone https://github.com/tadashi-aikawa/kikigaku.git
cd kikigaku
./scripts/make-app.sh
open .build/KIKIGAKI.app
```

作成された `.build/KIKIGAKI.app` をFinderで「アプリケーション」へコピーすれば、以後は通常のアプリとして起動できます。

## 起動と基本操作

メニューバーから録音を開始すると、書き起こしウィンドウへ発話が順に表示されます。停止すると、既定では `~/Documents/KIKIGAKI` にMarkdownを保存します。

| 操作 | 既定のショートカット |
|---|---|
| 開始・停止 | Control + Option + Command + K |
| 一時停止・再開 | Control + Option + Command + P |
| AIへ | Control + Option + Command + A。AIを有効にした会議のみ |

## 設定

`~/.config/kikigaki/config.toml` で設定します。すべて省略可能です。

```toml
outputDir = "~/Documents/KIKIGAKI"
saveRecording = false
```

WAVも残す場合は `saveRecording = true` にします。

AIへ会話を渡す手順は [AIへの受け渡し](docs/ai-handoff.md)、その他の設定と開発手順は [CLAUDE.md](CLAUDE.md) を参照してください。

### 会議へAIを参加させる

herdrとCodexまたはClaude Codeを導入し、使うCLIで [kikigaki Skill](skills/kikigaki/SKILL.md) を利用できるようにします。設定へ次を追加すると、次の会議から「AIへ…」が使えます。`[ai]` を省略した場合は無効です。

```toml
[ai]
cli = "codex" # Claude Codeなら "claude"
address = "迅雷へ"
notifySound = false
# CLIとherdrはPATHのほか ~/.local/bin・miseのshims・Homebrewを探します。見つからないときだけ絶対パスを指定します
# command = "/opt/homebrew/bin/codex"
# herdrCommand = "/opt/homebrew/bin/herdr"
```

初回の送信で専用herdrペインが作られます。固定の作業場所でも最初は利用者が一度ペインで信頼確認を承認してください。送信欄は空欄なら直近の声を送り、入力した場合は入力文を優先します。返事と確認は書き起こし中の展開できる印へ届き、会議Markdownにも残ります。確認の印の「返答する」から続けられます。

録音停止後も返事を回収します。次の会議への返事と混ぜず、旧会議の返事は元のMarkdownへ保存します。保存に失敗したときは「保存を再試行」を使えます。アプリ再起動後は未完了会議の返送を回収しますが、AIセッションの再接続や送信の再試行はしません。

モデルや作業場所、追加引数の設定は [AI参加者の設計](docs/ai-participant.md#設定) を参照してください。声の作業依頼も扱う会議参加モードと、従来の手動コピーでは操作の許可範囲が異なります。

## ロゴ

共通の元画像は [Resources/kikigaki.png](Resources/kikigaki.png) です。READMEとアプリアイコンはこの画像を使います。

元画像を更新したら、次のコマンドで配布用アイコンを再生成します。

```bash
bash scripts/make-icon.sh
```

生成した `Resources/kikigaki.icns` はアプリの組み立て時に同梱されます。

owlery・parliamentへの反映手順と制作記録は [ロゴの管理](docs/logo.md) を参照してください。
