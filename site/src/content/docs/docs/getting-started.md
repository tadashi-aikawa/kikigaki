---
title: はじめに・インストール
description: KIKIGAKIの動作環境、Homebrewでの導入、初回起動の許可、モデルの取得
---

KIKIGAKIを導入して、最初の会議を録音できる状態にします。
最後に、最初の録音から保存までの流れを1度通します。

## 動作環境

- macOS 26以降
- マイクへのアクセス許可
- 初回のネットワーク接続
    - 話者判別モデルを約193 MB取得します
    - Apple Speechの日本語アセットが未導入の場合は、それも取得します

## インストール

Homebrewで導入します。

```bash
brew install --cask tadashi-aikawa/tap/kikigaki
```

更新は次のコマンドです。

```bash
brew upgrade --cask kikigaki
```

Homebrewで導入すると、AI参加で使う `kikigaki-cli` にもPATHが通ります。
使い方は [AIを会議に参加させる](../ai-participant/) で説明します。

## 初回起動の許可

KIKIGAKIは自己署名のアプリです。
初回起動がブロックされた場合は、システム設定 → プライバシーとセキュリティ → 「このまま開く」で許可してください。

起動するとメニューバーにKIKIGAKIのロゴが出ます。
Dockには出ません。

### マイク

初めて録音を始めるときに、macOSがマイクの使用を確認します。許可してください。

許可しなかった場合は録音を始められません。
システム設定 → プライバシーとセキュリティ → マイク で、KIKIGAKIを許可してください。

### システム音声

オンライン会議の相手の声を取り込む会議では、初回にmacOSが「システムオーディオ録音」の許可を求めます。
画面収録の許可は要りません。
詳しくは [オンライン会議で相手の声を取り込む](../online-meetings/) を参照してください。

## モデルの取得

KIKIGAKIは2つのモデルを使います。どちらも初回だけネットワークから取得し、以後は手元のものを使います。

| モデル | 用途 | 取得元 | 置き場 |
| --- | --- | --- | --- |
| Nemotron 3 Diarization | 話者判別 | Hugging Face | `~/Library/Application Support/FluidAudio/Models/nemotron-3-diarization` |
| Apple Speechの日本語アセット | 文字起こし | Apple | macOSが管理 |

- 話者判別モデルは約193 MBです。話者判別を使う設定なら、アプリの起動時に先読みし、録音の開始までに準備します
- 録音を始めた時点で取得が終わっていなければ、終わるまで「準備中」で待ちます
- 話者判別を「区別しない」で使う会議では、話者判別モデルを読み込みません
- モデルの取得で、音声や文字起こしを送ることはありません

話者判別モデルは [Nemotron 3 Diarization](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml) です。
利用条件は [OpenMDW License Agreement 1.1](https://openmdw.ai/license/1-1/) で、商用利用もできます。

## 最初の録音

1. メニューバーのKIKIGAKIのロゴをクリックして「開く」を選びます
2. 「録音を開始」を押し、シートで会議ごとの指定を確かめて開始します。何も変えずにReturnでも始められます
3. 話すと、発話が話者付きで順に表示されます。半透明の行は、文字や話者が後から変わる可能性があります
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
