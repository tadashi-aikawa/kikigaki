<p align="center">
  <img src="Resources/kikigaki.png" alt="KIKIGAKIの会話フクロウ" width="180">
</p>

# KIKIGAKI

会議の発話を聴いて、話者付きでリアルタイムに文字起こしし、Markdownで残すmacOSアプリです。

## サイトとドキュメント

- **[サイト](https://tadashi-aikawa.github.io/kikigaki/)**: KIKIGAKIでできることを、絵と動画で紹介しています
- **[ドキュメント](https://tadashi-aikawa.github.io/kikigaki/docs/getting-started/)**: 導入・使い方・設定をまとめています

| 知りたいこと | ページ |
| --- | --- |
| 動作環境と導入、初めての録音 | [はじめに・インストール](https://tadashi-aikawa.github.io/kikigaki/docs/getting-started/) |
| 録音・話者名の編集・手入力 | [録音と書き起こし](https://tadashi-aikawa.github.io/kikigaki/docs/recording/) |
| イヤホンで相手の声も残す | [オンライン会議で使う](https://tadashi-aikawa.github.io/kikigaki/docs/online-meetings/) |
| CodexやClaude Codeを会議へ参加させる | [AIエージェントを会議に参加させる](https://tadashi-aikawa.github.io/kikigaki/docs/ai-participant/) |
| AIが書いた議事録とボードを見る | [議事録とボード](https://tadashi-aikawa.github.io/kikigaki/docs/minutes-and-board/) |
| 会議の内容が残る場所と送られる先 | [データの行き先](https://tadashi-aikawa.github.io/kikigaki/docs/data/) |
| `config.toml` の全キー | [設定リファレンス](https://tadashi-aikawa.github.io/kikigaki/docs/configuration/) |

## インストール

```bash
brew install --cask tadashi-aikawa/tap/kikigaki
```

初回起動の許可と動作環境は [はじめに・インストール](https://tadashi-aikawa.github.io/kikigaki/docs/getting-started/) を参照してください。

## データの行き先

音声と文字起こしは端末内で処理し、保存先も端末内です。外へ出るのは、AI参加を自分で設定して送信した内容だけです。

詳しくは [データの行き先](https://tadashi-aikawa.github.io/kikigaki/docs/data/) を参照してください。

## 開発

ビルドと開発の手順は [CLAUDE.md](CLAUDE.md) を参照してください。

## ライセンス

[MIT License](LICENSE) です。

同梱する第三者のソフトウェアとそのライセンスは [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) にまとめています。
