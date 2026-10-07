---
title: はじめに・インストール
description: KIKIGAKIを入れて、初めての録音を始めるまで
---

KIKIGAKIを入れて、会議やひとりの声を録音する準備をします。
最後に、話した言葉がMarkdownに残るところまで試します。

## 動作環境

- macOS 26以降
- マイクへのアクセス許可
- 初回のネットワーク接続
    - 話者判別のモデルをダウンロードします。約193 MBです
    - Apple Speechの日本語アセットがまだ無ければ、それもダウンロードします

## インストール

Homebrewで入れます。

```bash
brew install --cask tadashi-aikawa/tap/kikigaki
```

更新は次のコマンドです。

```bash
brew upgrade --cask kikigaki
```

Homebrewで入れると、AIエージェント(Claude Code か Codex のCLI)の参加に使う `kikigaki-cli` も端末から呼び出せます。
使い方は [AIエージェントを会議に参加させる](../ai-participant/) で説明します。

## 初回起動の許可

KIKIGAKIは自己署名のアプリです。
初回起動がブロックされた場合は、システム設定 → プライバシーとセキュリティ → 「このまま開く」で許可してください。

起動するとメニューバーにKIKIGAKIのロゴが出ます。
Dockには出ません。

### マイク

初めて録音を始めるときに、macOSがマイクの使用を確認します。
ここで許可してください。

許可しなかった場合は録音を始められません。
システム設定 → プライバシーとセキュリティ → マイク で、KIKIGAKIを許可してください。

### システム音声

オンライン会議の相手の声を取り込む会議では、初回にmacOSが「システムオーディオ録音」の許可を求めます。
画面収録の許可は要りません。
詳しくは [オンライン会議で使う](../online-meetings/) を参照してください。

## モデルの取得

KIKIGAKIは2つのモデルを使います。
初回にダウンロードした後は、Macの中にあるものを使います。

| モデル | 用途 | 取得元 |
| --- | --- | --- |
| Nemotron 3 Diarization | 話者判別 | Hugging Face |
| Apple Speechの日本語アセット | 文字起こし | Apple |

モデルの置き場は次のとおりです。

- Nemotron 3 Diarization
    - 置き場: `~/Library/Application Support/FluidAudio/Models/nemotron-3-diarization`
- Apple Speechの日本語アセット
    - 置き場: macOSが管理

- 話者判別を使う設定なら、アプリの起動時からモデルを読み込みます
- ダウンロードが終わる前に録音を始めると、「準備中」のまま待ちます
- 話者判別を「区別しない」で使う会議では、話者判別モデルを読み込みません
- ダウンロードのために、音声や書き起こしを送ることはありません

話者判別モデルは [Nemotron 3 Diarization](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml) です。
利用条件は [OpenMDW License Agreement 1.1](https://openmdw.ai/license/1-1/) で、商用利用もできます。

## 最初の録音

1. メニューバーのKIKIGAKIのロゴをクリックして「開く」を選びます
2. 「録音を開始」を押し、シートの設定を確かめて「開始」を押します
    - 操作: 何も変えずにReturnでも始められます
3. 話すと、話した言葉が話者付きで順に出ます
    - 表示: 半透明の行は、文字や話者が後から変わることがあります
4. 停止すると、`~/Documents/KIKIGAKI` にMarkdownを保存します

録音の開始・停止・一時停止は、メニューバーのメニューからも操作できます。
画面の見方と直し方は [録音と書き起こし](../recording/) で説明します。

## 設定ファイル

設定は `~/.config/kikigaki/config.toml` に書きます。
ファイルが無くても既定値で動くので、最初は作らなくてかまいません。

```toml
outputDir = "~/Documents/KIKIGAKI"
saveRecording = false # trueで録音WAVも残す
```

書き換えたら、メニューバーのメニューの「設定を再読込」で読み直します。
全キーは [設定リファレンス](../configuration/) を参照してください。
