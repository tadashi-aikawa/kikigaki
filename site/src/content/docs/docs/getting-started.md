---
title: はじめに・インストール
description: KIKIGAKIを入れて、初めての録音を始めるまで
---

KIKIGAKIを入れて、会議やひとりの声を録音する準備をします。
最後に、話した言葉がMarkdownに残るところまで試します。

## 動作環境

- macOS 26以降
- 初回のネットワーク接続。話者判別と文字起こしのモデルをダウンロードします

## インストール

Homebrewで入れます。

```bash
brew install --cask tadashi-aikawa/tap/kikigaki
```

AIエージェント(Claude Code か Codex のCLI)の参加に使う `kikigaki-cli` も一緒に入ります[^cli]。
更新は `brew upgrade --cask kikigaki` です。

## 初回起動

1. KIKIGAKIを起動します
2. メニューバーにKIKIGAKIのロゴが出ます。Dockには出ません

初回は、話者判別と文字起こしのモデルをダウンロードします[^model]。
終わる前に録音を始めると、「準備中」のまま待ちます。

## 最初の録音

1. メニューバーのKIKIGAKIのロゴをクリックして「開く」を選びます
2. 「録音を開始」を押し、シートの設定を確かめて「開始」を押します
3. 初回だけ、macOSがマイクの使用を確認するので、許可します
4. 話すと、話した言葉が話者付きで順に出ます
5. 停止すると、`~/Documents/KIKIGAKI` にMarkdownを保存します

<video src="/kikigaki/demos/transcription.mp4" aria-label="対面の会議を録音中の画面。左に書き起こし、右にAIエージェントが更新するボード" autoplay loop muted playsinline controls preload="metadata"></video>

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

## 困ったとき

### 初回起動がブロックされる

KIKIGAKIは自己署名のアプリです。
システム設定 → プライバシーとセキュリティ → 「このまま開く」で許可してください。

### マイクを許可しなかった

システム設定 → プライバシーとセキュリティ → マイク で、KIKIGAKIを許可してください。

[^cli]: 使い方は [AIエージェントを会議に参加させる](../ai-participant/) で説明します。
[^model]: 話者判別は [Nemotron 3 Diarization](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml) をHugging Faceから、文字起こしはApple Speechの日本語アセットをAppleから取得します。その後はMacの中にあるものを使い、ダウンロードのために音声や書き起こしを送ることはありません。話者判別のモデルは `~/Library/Application Support/FluidAudio/Models/nemotron-3-diarization` に置きます。
