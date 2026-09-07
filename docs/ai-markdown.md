# AIの返事のMarkdown表示

採用方式。Coreの分解、描画の順で実装する。

## 採用方式の提案

**parliamentと同型の自前分解を採用する。** `KikigakiCore/MarkdownBlocks.swift` に文字列からブロックと行内トークンを返す純関数を置く。描画はAppKit側へ閉じ、HTML生成・WebView・外部パッケージを追加しない。

| 観点 | 自前分解 | Foundationの `AttributedString(markdown:)` |
|---|---|---|
| テスト | 値型のブロック列を直接比較できる。未対応・壊れた記法の残し方まで固定できる | UIなしでrunsとintentを検証できる。ブロック列へ変換する処理とOSの解析結果を分けて検証する必要がある |
| 表とGFM | 区切り行付きの表・チェックボックス・取り消しを対象として明示する。記法の境界を自分で保守する | 表のpresentation intentと取り消しのinline intentは公式APIに存在する。今回必要なチェックボックス・裸URL・空行・水平線がどう残るかは実入力の確認が別途必要 |
| 依存 | Foundationのみ。対象を絞った解析コードの保守を引き受ける | 追加依存なし。OS標準の解析器を使えるが、Washiへの変換と独自の縮退処理は残る |
| 判断 | 今回の有限な対象とparliamentの行単位モデルに合わせやすいため採用候補 | 一般Markdownの解釈を広げる場合は有力。今回は全面採用も行内だけの併用も見送る提案 |

Foundationが表を扱えないことを理由にはしない。公式の `NSPresentationIntent` は段落・リスト・コード・表の意味を保持する。自前方式もCommonMark/GFM完全準拠を名乗らず、下記の対象だけを契約とする。[^foundation]

## 適用範囲とCoreの契約

`AIMarkRow` の結果行を展開したときの `question.result?.body` だけを分解する。送信文・質問の抜粋・詳細行・保存する原文は平文のまま。確認の「?」は本文に連結してから解析せず、本文の外に表示して先頭の見出しやフェンスを壊さない。

ブロックは段落、見出し、箇条書き項目、引用、コード、表、水平線を値型で表す。項目には段数・記号・番号・チェック状態、表にはセル列と列の整列、コードには加工しない本文と言語名を保持する。行内は文字・コード・装飾・リンク。装飾は太字・斜体・取り消しの組合せを保持する。AppKit型・色・フォント・URLを開く副作用をCoreに置かない。

解析はフェンスを先に隔離し、区切り行を確認して表を識別し、残りを行の役割へ分類する。箇条書きはインデントの増減から段数を保持し、番号は原文を維持する。引用は連続する引用行をまとめ、calloutの `[!NOTE]` 等は引用本文として残す。任意のブロック入れ子を構築する汎用ASTには広げない。

行内コードの内側では装飾とリンクを解釈しない。エスケープを処理し、未閉鎖の行内記法は原文へ戻す。未閉鎖フェンスは末尾までコードとして扱う。段落内の改行と空行を維持する。表の区切り行が無効なら元の段落へ戻し、エスケープされた `\|` と行内コード内の `|` はセル境界にしない。列不足は空セル、列超過は表の判定を打ち切り原文の行として残し、文字を捨てない。

hash・wikilink・Vault相対パス・画像・HTMLは専用解釈しない。画像記法を通常リンクとして部分的に拾わず原文で表示する。`[text](url)` は表示と行き先を分け、押せるのは妥当なhttp(s) URLだけとする。裸http(s) URLの末尾句読点と対応しない閉じ括弧はリンクへ含めない。

## 要素と描き方

文字サイズは現行本文15ptを基準とし、段3のクロディーヌのレビューで段差と余白を調整した。

| 要素 | 描き方 |
|---|---|
| 本文 | 15pt、`Washi.ink`、行間4pt、段落間に余白 |
| h1〜h6 | semibold。h1は18pt、h2は16pt、h3以降は15pt。前余白は14・11・8pt、文頭は0pt。h4以降を `muted` にし、直後の空行は文字を残して高さだけ抑える |
| `-`・`*`・`+` | 中黒と本文を分離。段ごとに字下げし、折り返しは本文の開始位置へ揃える |
| 番号付き | 原文の番号と区切りを維持。2桁以上も含めた記号幅でぶら下げ位置を決める |
| チェックボックス | 未チェック・チェック済みの記号。閲覧用とし編集操作は持たせない |
| 引用 | `muted` の文字、`rule` の左罫、本文の左に余白。複数行を同じ引用の器に置く |
| フェンスコード | 13pt等幅、`ink`、`shade` の地。原文の改行と空白を保持し、表示幅で折り返す。地色は段落の `textBlocks` に設定した `NSTextBlock` で描く |
| 行内コード | 等幅、`shade` の地。本文内では幅に応じて表示を折り返す |
| 太字・斜体・取り消し | semibold・`obliqueness = 0.15`・薄墨の取り消し線。引用内の太字は引用の色を保つ。日本語も傾け、併用時に片方を落とさない |
| リンク・裸URL | `Washi.red` と下線。選択・コピーを保ち、クリックでhttp(s) URLを開く |
| 区切り行付きテーブル | `NSTextTable` と `NSTextTableBlock` を段落の `textBlocks` に設定。`rule` の罫、見出しセルは `shade` とsemibold。セル内は折り返し、区切り行の左右中央寄せを反映 |
| 水平線 | `rule` の1pt線と前後余白。文字を長く並べて線に見せない |

表も本文と同じtextStorage内に置き、本文幅で折り返す。短い番号列まで一律の列幅にしない。既存の `Washi` 色以外は追加しない。

表の見出し行は下罫を1ptにする。水平線の上下余白は12ptとし、表の下罫と離す。コードの継続行だけ16pt字下げする。リストの記号幅に下限を置かず、記号幅+7ptの位置に本文を揃え、記号は薄墨にする。行内コードは13ptを下限として周囲の文字サイズの85%へ追従する。

## 描画部品と高さ

返事本文を編集不可で選択可能な1つの `NSTextView` に統一する。コードと表も同じtextStorage内へ置き、返事全体の選択・コピーを維持する。コードの横スクロールよりこの操作を優先するため、コードも表示幅で折り返す。見出し余白とぶら下げは段落スタイル、コードの地色と引用の左罫は `NSTextBlock`、表は `NSTextTable` で描く。`NSTextField` から移す理由は表と段落全体の地色を同じテキストレイアウトで扱うため。

TextKit 1の `NSTextStorage`・`NSLayoutManager`・`NSTextContainer` を明示して使う。Appleは `NSTextTable` をTextKit 2で未対応の内容として説明しているため、途中の互換モード切替に頼らない。[^textview]

段3の実画面では素の `NSTextBlock` の地色・罫・余白が反映されなかったため、コード・引用・水平線にはそのサブクラス `NSTextTableBlock` の1セルを使う。段落の `textBlocks` で描き、本文と同じtextStorageに保持する。600pt・900ptの実画面で描画を確認し、本文・コード・表を跨ぐ全文コピーも専用ペーストボードで検証した。

`height(for:)` と `layout()` は同じ幅と同じレイアウト結果を使う。現行の `max(44, width - 90)` を本文幅とし、部品内部の余白をそこから差し引く。コンテナ幅を設定し、`ensureLayout(for:)` の後で `usedRect(for:)` を測り、末尾の空行とテキストビューの余白を含めて切り上げる。この高さを `measuredBody` へ返す。`cellSize` とTextKitの高さを混在させない。[^layout]

原文が変わったときだけトークンとtextStorageを更新し、既読化・改名だけの更新では本文選択を失わない。幅変更時は計測キャッシュを無効化し、表示と計測のコンテナ幅を必ず一致させる。展開時に再計測し、畳んだ行は現行の28ptを維持する。段3では本文・コード・表を跨ぐ選択とコピーも確認する。

## 段2以降の検証

Coreの入口は `MarkdownBlocks.parse(_:)` と `MarkdownBlocks.inline(_:)`。前者は `MarkdownBlock` 列、後者は装飾の組合せ・コードかどうか・行き先を持つ `MarkdownInline` 列を返す。段落は原文1行ずつとし空行も残す。見出しはATX形式、取り消しは `~~...~~`、表は各行に区切りパイプがあるものを扱う。セル区切りのハイフンは1個以上を認める。表の次の見出し・引用・箇条書き・フェンスで表を終了する。共通の行内分解を見出し・項目・引用・セルにも使い、要素ごとの装飾の欠落を防ぐ。

- Core: 対象要素を含む例と複合例、装飾の併用、入れ子の箇条書き、複数桁の番号、引用の連続、CRLF、空文字、日本語・絵文字を検証する。
- 境界: 壊れたリンク・未閉鎖フェンス・エスケープ・コード内の記号・水平線と箇条書きの識別・表の列不一致・コード内のパイプ・未対応記法で文字を失わないことを検証する。
- UI: 全対象を同じ返事に含め、狭幅・広幅と幅の往復で最終行・表・次の詳細行が重ならないことを確認する。展開・既読化・改名時の選択保持、リンク、コードの折り返し、返事全体の選択・コピーも確認する。
- 提出: `swift build` と `swift test` が成功してから署名なしの.appを組み、cacheDisplayで撮影し目視する。本人がクロディーヌへレビューを依頼する。

段2でCoreの分解とテストを実装し、本人のレビューを受ける。記録はタスク経過欄だけに残し、分身はjournalへ書かない。タスク1を終えるまで定期自動送信の設計へ進まない。

[^foundation]: [Apple: NSPresentationIntent](https://developer.apple.com/documentation/foundation/nspresentationintent)、[Apple: strikethrough](https://developer.apple.com/documentation/foundation/inlinepresentationintent/strikethrough)。parliamentのローカル参照は `packages/web/src/message-tokens.ts` と `components/MarkdownBody.vue`。冒頭コメントにはテーブル対象外という古い記述が残るが、現在のVueには表の描画があり、今回はこちらと `styles/markdown.css` の折り返し方針を参照する。
[^textview]: [Apple: NSTextView](https://developer.apple.com/documentation/appkit/nstextview)、[Apple: NSTextTable](https://developer.apple.com/documentation/appkit/nstexttable)。
[^layout]: [Apple: NSLayoutManager](https://developer.apple.com/documentation/appkit/nslayoutmanager)、[Apple: usedRect(for:)](https://developer.apple.com/documentation/appkit/nslayoutmanager/usedrect(for:))。未レイアウトの領域を含む高さは、usedRectだけでは確定しない。
