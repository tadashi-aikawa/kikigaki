# 議事録の描画と検索

右ペインの本文は専用のWKWebViewで描画する。幅は左右24ptの余白を除いてペイン全体へ追従し、720ptの上限を設けない。表はセル内で折り返し、狭すぎる表とコード・図は本文全体を押し広げずに横スクロールする。

⌘Fは焦点のあるペインを検索する。右ペインでは検索欄、一致の強調、現在位置と件数を表示する。⌘G・⌘⇧G、Enter・Shift+Enter、矢印ボタンで次・前へ移動し、Escapeで閉じる。大文字小文字を区別せず、太字などの装飾をまたぐ語も検索できる。強調する一致は先頭10,000件まで。

パス欄の下のボタンで対象ファイルをNeovim・Obsidianに開ける。未作成ファイルは案内を表示する。

- Neovimは操作時に選択中のherdrワークスペースへ新しいタブを作る。作業ディレクトリは議事録の親。設定の `herdrCommand` があれば利用する。引数のパスはシェル引用し、既存ペインへコマンドを送らない。Ghosttyが起動中なら前面化する。
- Obsidianには絶対パスを `obsidian://open?path=...` で渡す。対象ファイルがObsidianのVault内にあることが必要。

## 対応記法

| 記法 | 表示 |
| --- | --- |
| 見出し・段落・引用・入れ子リスト・表・通常リンク・強調・打消し | Markdownとして描画する。 |
| タスク `[x]` と `[ ]` | 読み取り専用のチェックボックス。 |
| 脚注 `[^id]` | 本文から文末の脚注へ移動でき、戻るリンクも表示する。 |
| `> [!NOTE] 題` などのcallout | 題と本文の枠。折り畳み指定でも内容を展開して表示する。 |
| 見出し `{#id}` と `(#id)` | 本文内の見出しへ移動する。通常の見出し名でも移動できる。 |
| `[[ノート\|別名]]` | 別名を再解釈せず文字として表示する。ノートへのリンク動作は持たない。 |
| `![説明](画像)`、`![[画像.png\|幅]]` | ローカル画像とHTTP・HTTPS画像。ローカル相対パスは議事録の親を基準とする。 |
| Mermaidコードブロック | 図として描画する。失敗時は記法を残す。 |
| `$...$`、`$$...$$`、`\(...\)`、`\[...\]` | KaTeXで数式を描画する。math・latexコードブロックにも対応する。 |
| SVGコードブロック、閉じたSVGブロック | sanitize後、画像として描画する。 |
| 先頭の閉じたfrontmatter | 非表示。BOM・CRLFを扱い、閉じない場合は本文を残す。 |
| 任意HTML、ノートの埋め込み、未対応構文 | 実行せず、文字として残す。 |

コードブロックと行内コードの記法は変換しない。表のwikilinkのパイプはObsidianと同じくエスケープする。表示例は [minutes-preview-example.md](minutes-preview-example.md)。

## 実装と配布

`MinutesFileMonitor`が検証したUTF-8本文を、`MinutesWebView`から引数付きJavaScript呼び出しで渡す。本文をスクリプトへ文字列連結しない。旧TextKit用のブロック解析はプレビューの読込経路では行わない。

ファイル切替・取消の世代をSwiftとJavaScriptの両側で確認する。同じファイルの更新は先頭可視ブロックとその位置、選択の文字位置を保存して復元する。短縮時は有効範囲へ収める。別ファイルは先頭へ戻す。

描画ライブラリは `Sources/Kikigaki/MinutesAssets` に同梱する。SwiftPMの資産bundleを.appにもコピーするため、実行時のCDN接続やNodeは不要。外部画像だけはURLへ通信する。

更新時は `web/minutes` で以下を順に実行する。

```sh
npm ci --ignore-scripts
npm test
npm run build
```

生成済み資産とlockfileもコミットする。同梱ライセンスは `THIRD-PARTY-NOTICES.txt` と `preview.js.LEGAL.txt`。

## 実行境界

非永続のWebKitデータストアを使う。HTMLを無効にしたMarkdown解析、DOMPurify、CSPを重ね、任意HTML・スクリプト・iframeを読み込まない。Mermaidはstrict、KaTeXはtrust無効。図の原文はコマンド実行の口へ渡さない。

`minutes-app` schemeは同梱資産、`minutes-image` schemeは現在の議事録から参照する画像だけに使う。ローカル画像は通常ファイル・1枚24MiB以下を確認し、FIFOを待たない。読込は直列化し、1回の描画で合計96MiBまでに制限する。描画ごとに画像のhostを変え、取消時には待っている要求も終了する。本文に任意のファイル読取APIを公開しない。WebKitの生成は最初の本文描画まで遅延する。

参考にした公式資料:

- [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)
- [WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler)
- [markdown-itの描画ルール](https://github.com/markdown-it/markdown-it/blob/master/docs/examples/renderer_rules.md)
- [KaTeXの実行境界](https://katex.org/docs/security)
- [Mermaidの設定](https://mermaid.js.org/config/schema-docs/config.html)
- [Obsidian URI](https://help.obsidian.md/Extending+Obsidian/Obsidian+URI)

## 開発用の実画面確認

debug版.appは `--preview-minutes <絶対パス>` で議事録の検証画面だけを起動できる。マイク・モデル・AI・グローバルホットキーを起動しない。会議状態と幅設定は一時領域へ分け、終了時に片づける。
