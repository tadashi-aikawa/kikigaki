import Foundation

/// 板の見出しはMarkdownのATX見出し行そのもの。文字列比較はNFC/NFDを同一視する。
public enum BoardHeading {
    public static func level(_ heading: String) -> Int? {
        guard !heading.contains(where: \.isNewline), !heading.contains("\0") else { return nil }
        let hashes = heading.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), heading.dropFirst(hashes).first == " ",
              !heading.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return hashes
    }
    public static func validate(_ heading: String) throws {
        guard level(heading) != nil else { throw AIError.invalid("board must be a single Markdown heading (# through ######)") }
    }
}

/// fenced codeとfrontmatter内の見出しを除外し、同階層以上の見出しで区切る。
/// 編集後も他の節のバイト表現・改行を保つため、行を再結合せず元文字列の範囲を使う。
public enum BoardSection {
    public struct Parts: Equatable, Sendable {
        public let minutes: String
        public let board: String?
    }
    private static func section(_ text: String, heading: String) -> (Range<String.Index>, Range<String.Index>)? {
        guard let level = BoardHeading.level(heading) else { return nil }
        var cursor = text.startIndex
        var start: String.Index?, bodyStart: String.Index?
        var fence: (Character, Int)?
        var frontmatter = false
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(where: \.isNewline) ?? text.endIndex
            let next = end == text.endIndex ? end : text.index(after: end)
            let line = String(text[cursor..<end]).trimmingCharacters(in: .newlines)
            if cursor == text.startIndex && (line == "---" || line == "\u{FEFF}---") { frontmatter = true; cursor = next; continue }
            if frontmatter {
                if line == "---" || line == "..." { frontmatter = false }
                cursor = next; continue
            }
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            if indent <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if let open = fence {
                    if first == open.0, count >= open.1,
                       trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                } else if count >= 3 { fence = (first, count) }
                cursor = next; continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            let suffix = trimmed.dropFirst(hashes)
            let isHeading = (1...6).contains(hashes) && (suffix.isEmpty || suffix.first == " " || suffix.first == "\t")
            if fence == nil, indent <= 3, isHeading {
                let found = hashes
                if let start, let bodyStart, found <= level { return (start..<cursor, bodyStart..<cursor) }
                if start == nil, String(trimmed) == heading { start = cursor; bodyStart = next }
            }
            cursor = next
        }
        guard let start, let bodyStart else { return nil }
        return (start..<text.endIndex, bodyStart..<text.endIndex)
    }
    public static func split(_ text: String, heading: String) -> Parts {
        guard let (whole, body) = section(text, heading: heading) else { return Parts(minutes: text, board: nil) }
        return Parts(minutes: String(text[..<whole.lowerBound]) + text[whole.upperBound...], board: String(text[body]))
    }
    public static func replacing(_ text: String, heading: String, body: String) throws -> String {
        try BoardHeading.validate(heading)
        let replacement = body.isEmpty || body.hasSuffix("\n") ? body : body + "\n"
        if let (_, range) = section(text, heading: heading) {
            let prefix = String(text[..<range.lowerBound])
            return prefix + (prefix.last?.isNewline == true ? "" : "\n") + replacement + text[range.upperBound...]
        }
        return text + (text.isEmpty || text.last?.isNewline == true ? "" : "\n") + heading + "\n" + replacement
    }
}

public enum BoardPrompt {
    public static func summary(heading: String) -> String { "板を更新(\(heading))" }
    public static let builtIn = """
    議論の板を更新してください。「いま何を話しているか」を1画面で見せる板です。

    書き先は participant.minutes_path のファイル内の participant.board_heading です。必ず既存ファイルを読んでから、その見出しの直後から次の同階層以上の見出しの直前までだけを差し替えてください。他の見出しと本文は一切触りません。コードブロック内の見出しは区切りではありません。NFC/NFDの違いは同じ見出しとして扱います。見出しが無ければ末尾に見出しごと追加し、ファイルが無ければ作成してください。書き先か見出しが無ければ作業を止めて理由を返してください。

    型は次の4ブロックと順序を守ります。見出し行は participant.board_heading をそのまま使い、その配下に置きます。「論点」「立場」「直近の動き」は板より1段深い見出しにし、板が第6階層なら太字の段落にします。

    - 現在地: <ID> <論点名>
    - 更新: <HH:MM> / 第<n>版

    ### 論点

    ```mermaid
    flowchart TB
      classDef now fill:#efe6f8,stroke:#9b72c6,stroke-width:3px
      classDef hot stroke:#9b72c6,stroke-width:2px
      classDef cold color:#9a9a9a,stroke:#d5d5d5
      classDef done fill:#e3f4e1,stroke:#2e8b57
      classDef hold fill:#fff1d6,stroke:#e67e22,stroke-width:2px,stroke-dasharray:5 3
      classDef rejected fill:#f2f2f2,color:#9a9a9a,stroke:#b5b5b5,stroke-width:1px,stroke-dasharray:2 2
      T1["T1 来期の料金体系"]
      T2["✅ T2 価格改定は10月から"]
      T3["T3 値上げ幅"]
      T4["🟠 T4 海外の扱い"]
      T1 --> T2
      T1 --> T3
      T3 --> T4
      class T2 done
      class T4 hold
      class T3 now
      class T2 hot
      class T1 cold
    ```

    ### 立場

    | 論点 | タダシ | 田中 |
    | --- | --- | --- |
    | T3 値上げ幅 | 10%まで | 5%が上限 |

    ### 直近の動き

    - T3 が新しく立った
    - T2 が決まった

    規則:

    - 上の内容は型の例です。会話に無い論点・立場を足しません。聞き取れない箇所は書かず、話者の取り違えや立場が曖昧なら表へ書きません。
    - ノードIDはT1から初出順に採番します。一度付けたIDを変更・再利用せず、文言を書き直してもIDを保ちます。12個を超える場合だけ決着して2版以上動かない論点を図から畳み、IDを再利用しません。
    - 既存行の順序を保ち、変わった行だけを書き換え、新しいノードと矢印は各々の末尾へ追記します。毎回ゼロから組み直しません。flowchart TBを維持し、subgraphは使いません。
    - ラベルは20字以内で必ず ["..."] で囲み、内部に [ ] " を入れません。状態の印に続けてIDと本文を書きます。印なしはこれから決めるもの、✅ は決まった、🟠 は保留、❌ は却下、💬 は決定対象でない前提・所感です。
    - ✅ はdone、🟠 はhold、❌ はrejectedのclassを付けます。現在地はちょうど1つでnow、直前の版から内容・状態・立場が動いた論点はhot、2版以上動いていないものはcoldです。now/hot/coldは同じIDへ重ねず、状態のclassより後に指定します。
    - 派生関係は T1 --> T3 の矢印を追加順で並べます。
    - 議事録本文に論点と対応する見出しがあれば、単独行の click Tn "#見出し" で結びます。見出しに {#id} があれば "#id" を使います。存在しない見出しを作ったり、外部URLやJavaScript callbackを指定したりしません。
    - 立場の表は意見が割れている論点だけにし、全員一致と未表明は書きません。話者名は会話のまま、立場は10字以内。割れていなければ表の代わりに「まだ割れていない」と書きます。
    - 直近の動きは3行まで。古い行は消します。論点は12個までです。

    保存後にminutesで通知しないでください。表示対象は既に議事録です。accept、progress --editing、保存、progress --replying、reply --kind answeredの順に進め、answeredは「第n版: 動いた点」の1〜2行だけにしてください。
    """
}
