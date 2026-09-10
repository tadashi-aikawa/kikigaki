import Foundation

/// 表示に必要な意味だけを運ぶ。AppKitの属性やURLを開く処理は描画側が持つ。
public struct MarkdownInline: Equatable, Sendable {
    public struct Style: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let strong = Self(rawValue: 1)
        public static let emphasis = Self(rawValue: 2)
        public static let strikethrough = Self(rawValue: 4)
    }
    public var text: String
    public var style: Style
    public var isCode: Bool
    /// 非http(s)の明示リンクも原文の行き先を保持する。クリック可否はwebURLで判定する。
    public var destination: String?
    public init(_ text: String, style: Style = [], isCode: Bool = false, destination: String? = nil) {
        self.text = text; self.style = style; self.isCode = isCode; self.destination = destination
    }
    public var webURL: URL? {
        guard let destination,
              !destination.contains(where: { $0.isWhitespace }),
              let url = URL(string: destination),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

public struct MarkdownListItem: Equatable, Sendable {
    public var depth: Int
    /// 番号を文字列のまま持つことで、先頭の0と桁数も表示時に失わない。
    public var marker: String
    public var ordered: Bool
    public var checked: Bool?
    public var content: [MarkdownInline]
}

public struct MarkdownQuoteLine: Equatable, Sendable {
    public var depth: Int
    public var content: [MarkdownInline]
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case left, center, right }
    public var header: [[MarkdownInline]]
    public var alignments: [Alignment]
    public var rows: [[[MarkdownInline]]]
}

public enum MarkdownBlock: Equatable, Sendable {
    /// 1原文行を1段落にする。空行も空の配列で保持し、行送りは描画側で決める。
    case paragraph([MarkdownInline])
    case heading(level: Int, content: [MarkdownInline])
    case listItem(MarkdownListItem)
    case quote([MarkdownQuoteLine])
    case code(text: String, language: String?)
    case table(MarkdownTable)
    case rule
}

/// AIの返事用の限定Markdown。HTMLや任意のブロック入れ子を構築しない。
/// 記法が成立しない行は原文の段落へ戻し、読める内容を捨てない。
public enum MarkdownBlocks {
    public static func parse(_ source: String, minutes: Bool = false) -> [MarkdownBlock] {
        let source = minutes ? withoutFrontmatter(source) : source
        guard !source.isEmpty else { return [] }
        func inline(_ text: String) -> [MarkdownInline] { InlineScanner(Array(text), minutes: minutes).parse() }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var index = 0
        var indents = [0]
        while index < lines.count {
            let line = lines[index]
            if let fence = openingFence(line) {
                var body: [String] = []
                index += 1
                while index < lines.count && !closesFence(lines[index], fence) {
                    body.append(lines[index]); index += 1
                }
                result.append(.code(text: body.joined(separator: "\n"), language: fence.language))
                if index < lines.count { index += 1 }
                indents = [0]
                continue
            }
            if index + 1 < lines.count, !startsBlock(line),
               let header = tableCells(line), let separators = tableCells(lines[index + 1]),
               header.count == separators.count,
               let alignments = tableAlignments(separators) {
                var rows: [[[MarkdownInline]]] = []
                index += 2
                while index < lines.count, !startsBlock(lines[index]),
                      let cells = tableCells(lines[index]), cells.count <= header.count {
                    rows.append((cells + Array(repeating: "", count: header.count - cells.count)).map(inline))
                    index += 1
                }
                result.append(.table(MarkdownTable(header: header.map(inline), alignments: alignments, rows: rows)))
                indents = [0]
                continue
            }
            if let heading = captures(#"^ {0,3}(#{1,6})(?:[ \t]+(.*)|$)"#, line) {
                let text = heading[1].replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                result.append(.heading(level: heading[0].count, content: inline(text)))
                indents = [0]
            } else if isRule(line) {
                result.append(.rule); indents = [0]
            } else if let item = listLine(line) {
                while indents.count > 1 && item.indent < indents.last! { indents.removeLast() }
                if item.indent > indents.last! { indents.append(item.indent) }
                result.append(.listItem(MarkdownListItem(depth: indents.count - 1,
                    marker: item.marker, ordered: item.ordered, checked: item.checked, content: inline(item.text))))
            } else if let quote = quoteLine(line, minutes: minutes) {
                var quoted = [quote]
                while index + 1 < lines.count, let next = quoteLine(lines[index + 1], minutes: minutes) {
                    quoted.append(next); index += 1
                }
                result.append(.quote(quoted)); indents = [0]
            } else {
                result.append(.paragraph(inline(line)))
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { indents = [0] }
            }
            index += 1
        }
        return result
    }

    public static func inline(_ source: String) -> [MarkdownInline] {
        InlineScanner(Array(source)).parse()
    }

    private static func withoutFrontmatter(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines.dropFirst(end + 1).joined(separator: "\n")
    }

    private struct Fence {
        var marker: Character
        var count: Int
        var language: String?
    }
    private static func openingFence(_ line: String) -> Fence? {
        guard let parts = captures(#"^ {0,3}(`{3,}|~{3,})(.*)$"#, line) else { return nil }
        let marker = parts[0].first!
        guard marker != "`" || !parts[1].contains("`") else { return nil }
        let info = parts[1].trimmingCharacters(in: .whitespaces)
        return Fence(marker: marker, count: parts[0].count, language: info.isEmpty ? nil : info)
    }
    private static func closesFence(_ line: String, _ fence: Fence) -> Bool {
        let leading = line.prefix { $0 == " " }.count
        guard leading <= 3 else { return false }
        let rest = line.dropFirst(leading)
        let markers = rest.prefix { $0 == fence.marker }.count
        return markers >= fence.count && rest.dropFirst(markers).allSatisfy { $0 == " " || $0 == "\t" }
    }
    private static func isRule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard let first = marks.first, ["-", "*", "_"].contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }
    private static func listLine(_ line: String) -> (indent: Int, marker: String, ordered: Bool, checked: Bool?, text: String)? {
        guard let parts = captures(#"^([ \t]*)([-+*]|[0-9]{1,9}[.)])(?:[ \t]+(.*)|$)"#, line) else { return nil }
        let indent = parts[0].reduce(0) { $1 == "\t" ? $0 + 4 - $0 % 4 : $0 + 1 }
        var text = parts[2]
        var checked: Bool?
        if let task = captures(#"^\[([ xX])\](?:[ \t]+(.*)|$)"#, text) {
            checked = task[0] != " "; text = task[1]
        }
        return (indent, parts[1], parts[1].first?.isNumber == true, checked, text)
    }
    private static func quoteLine(_ line: String, minutes: Bool = false) -> MarkdownQuoteLine? {
        guard let parts = captures(#"^ {0,3}>(.*)$"#, line) else { return nil }
        var text = parts[0], depth = 1
        if text.first == " " { text.removeFirst() }
        while text.first == ">" {
            depth += 1; text.removeFirst()
            if text.first == " " { text.removeFirst() }
        }
        return MarkdownQuoteLine(depth: depth, content: InlineScanner(Array(text), minutes: minutes).parse())
    }
    private static func startsBlock(_ line: String) -> Bool {
        openingFence(line) != nil || isRule(line) || listLine(line) != nil
            || line.range(of: #"^ {0,3}(>|#{1,6}(?:[ \t]|$))"#, options: .regularExpression) != nil
    }
    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map {
            Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// 有効なcode spanだけを隔離する。閉じていないバッククォートで残りの列を隠さない。
    private static func tableCells(_ line: String) -> [String]? {
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        guard !chars.isEmpty else { return nil }
        var cells: [String] = [], current = "", i = 0, boundaries: [Int] = []
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                // 表のパイプのエスケープは行内解析より前に解決する。
                current += chars[i + 1] == "|" ? "|" : String(chars[i...i + 1])
                i += 2; continue
            }
            if chars[i] == "`" {
                if let span = InlineScanner.codeSpan(chars, at: i) {
                    current += String(chars[i..<span.end]).replacingOccurrences(of: "\\|", with: "|")
                    i = span.end
                } else {
                    let start = i
                    while i < chars.count && chars[i] == "`" { i += 1 }
                    current += String(chars[start..<i])
                }
                continue
            }
            if chars[i] == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                boundaries.append(i)
            } else { current.append(chars[i]) }
            i += 1
        }
        guard !boundaries.isEmpty else { return nil }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if boundaries.first == 0 { cells.removeFirst() }
        if boundaries.last == chars.count - 1 { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }
    private static func tableAlignments(_ cells: [String]) -> [MarkdownTable.Alignment]? {
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            guard cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            result.append(cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .right) : .left)
        }
        return result
    }
}

/// Character単位の走査にして絵文字・結合文字を割らない。閉じない記法は文字のまま残す。
private struct InlineScanner {
    let chars: [Character]
    let minutes: Bool
    init(_ chars: [Character], minutes: Bool = false) { self.chars = chars; self.minutes = minutes }
    private static let escapable = Set(##"!\"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)

    func parse(style: MarkdownInline.Style = [], destination: String? = nil, depth: Int = 0) -> [MarkdownInline] {
        // 壊れたAI出力の過度な入れ子でもスタックを使い切らず、本文へ縮退する。
        guard depth < 32 else { return [.init(String(chars), style: style, destination: destination)] }
        var result: [MarkdownInline] = [], i = 0
        func append(_ value: MarkdownInline) {
            guard !value.text.isEmpty else { return }
            if let last = result.last, last.style == value.style, last.isCode == value.isCode,
               last.destination == value.destination {
                result[result.count - 1].text += value.text
            } else { result.append(value) }
        }
        func plain(_ text: String) { append(.init(text, style: style, destination: destination)) }
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, Self.escapable.contains(chars[i + 1]) {
                plain(String(chars[i + 1])); i += 2; continue
            }
            if chars[i] == "`" {
                if let span = Self.codeSpan(chars, at: i) {
                    append(.init(span.text, style: style, isCode: true, destination: destination))
                    i = span.end
                } else {
                    // 閉じない2個の記号の後半を、1個の開始記号として拾い直さない。
                    let start = i
                    while i < chars.count && chars[i] == "`" { i += 1 }
                    plain(String(chars[start..<i]))
                }
                continue
            }
            // 対象外の画像・wikilinkは塊で残す。中のURLや装飾だけを誤って有効にしない。
            if starts("![[", at: i), let end = find("]]", from: i + 3) {
                plain(String(chars[i..<end + 2])); i = end + 2; continue
            }
            if starts("![", at: i), let link = link(at: i + 1) {
                plain(String(chars[i..<link.end])); i = link.end; continue
            }
            if starts("[[", at: i), let end = find("]]", from: i + 2) {
                if minutes {
                    let inner = String(chars[i + 2..<end]).replacingOccurrences(of: "\\|", with: "|")
                    let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    plain(String(parts.last?.isEmpty == false ? parts.last! : parts.first ?? ""))
                } else { plain(String(chars[i..<end + 2])) }
                i = end + 2; continue
            }
            if chars[i] == "[", let link = link(at: i) {
                let label = Array(chars[i + 1..<link.labelEnd])
                for run in InlineScanner(label, minutes: minutes).parse(style: style, destination: destination ?? link.target, depth: depth + 1) {
                    append(run)
                }
                i = link.end; continue
            }
            if destination == nil, let url = bareURL(at: i) {
                append(.init(url.text, style: style, destination: url.text)); i = url.end; continue
            }
            if chars[i] == "~" {
                var end = i
                while end < chars.count && chars[end] == "~" { end += 1 }
                if end - i != 2 {
                    plain(String(chars[i..<end])); i = end; continue
                }
            }
            if let delimiter = openingDelimiter(at: i),
               let end = closingDelimiter(delimiter, from: i + delimiter.count) {
                let inner = Array(chars[i + delimiter.count..<end])
                let added: MarkdownInline.Style = delimiter == "~~" ? .strikethrough
                    : delimiter.count == 3 ? [.strong, .emphasis] : delimiter.count == 2 ? .strong : .emphasis
                for run in InlineScanner(inner, minutes: minutes).parse(style: style.union(added), destination: destination, depth: depth + 1) {
                    append(run)
                }
                i = end + delimiter.count; continue
            }
            plain(String(chars[i])); i += 1
        }
        return result
    }

    static func codeSpan(_ chars: [Character], at start: Int) -> (text: String, end: Int)? {
        var count = 0
        while start + count < chars.count && chars[start + count] == "`" { count += 1 }
        var i = start + count
        while i < chars.count {
            if chars[i] != "`" { i += 1; continue }
            var end = i
            while end < chars.count && chars[end] == "`" { end += 1 }
            if end - i == count {
                var text = String(chars[start + count..<i]).replacingOccurrences(of: "\n", with: " ")
                if text.hasPrefix(" "), text.hasSuffix(" "), !text.allSatisfy({ $0 == " " }) {
                    text.removeFirst(); text.removeLast()
                }
                return (text, end)
            }
            i = end
        }
        return nil
    }
    private func starts(_ text: String, at index: Int) -> Bool {
        let value = Array(text)
        return index + value.count <= chars.count && chars[index..<index + value.count].elementsEqual(value)
    }
    private func find(_ text: String, from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if starts(text, at: i) { return i }
            i += 1
        }
        return nil
    }
    private func link(at start: Int) -> (labelEnd: Int, target: String, end: Int)? {
        var i = start + 1, nesting = 1
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`", let span = Self.codeSpan(chars, at: i) { i = span.end; continue }
            if chars[i] == "[" { nesting += 1 }
            if chars[i] == "]" {
                nesting -= 1
                if nesting == 0 { break }
            }
            i += 1
        }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        let labelEnd = i
        i += 2
        let targetStart = i
        nesting = 1
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "(" { nesting += 1 }
            if chars[i] == ")" { nesting -= 1; if nesting == 0 { break } }
            if chars[i] == "\n" { return nil }
            i += 1
        }
        guard i < chars.count else { return nil }
        var target = String(chars[targetStart..<i]).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), target.hasSuffix(">") { target.removeFirst(); target.removeLast() }
        let raw = Array(target)
        var unescaped = "", at = 0
        while at < raw.count {
            if raw[at] == "\\", at + 1 < raw.count, Self.escapable.contains(raw[at + 1]) { at += 1 }
            unescaped.append(raw[at]); at += 1
        }
        return (labelEnd, unescaped, i + 1)
    }
    private func bareURL(at start: Int) -> (text: String, end: Int)? {
        guard starts("https://", at: start) || starts("http://", at: start) else { return nil }
        if start > 0 && (chars[start - 1].isLetter || chars[start - 1].isNumber || chars[start - 1] == "_") { return nil }
        var end = start
        while end < chars.count && !chars[end].isWhitespace && !"<>'\"`*。、，．！？「」".contains(chars[end]) { end += 1 }
        while end > start {
            let last = chars[end - 1]
            if ".,;:!?。、，．！？".contains(last) { end -= 1; continue }
            let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", "）": "（", "」": "「"]
            if let open = pairs[last] {
                let body = chars[start..<end]
                if body.filter({ $0 == last }).count > body.filter({ $0 == open }).count { end -= 1; continue }
            }
            break
        }
        let text = String(chars[start..<end])
        guard MarkdownInline(text, destination: text).webURL != nil else { return nil }
        return (text, end)
    }
    private func openingDelimiter(at start: Int) -> String? {
        for delimiter in ["***", "___", "**", "__", "~~", "*", "_"] where starts(delimiter, at: start) {
            let after = start + delimiter.count
            guard after < chars.count, !chars[after].isWhitespace else { continue }
            // foo_bar_bazは識別子として残す。
            if delimiter.first == "_", start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber { continue }
            return delimiter
        }
        return nil
    }
    private func closingDelimiter(_ delimiter: String, from start: Int) -> Int? {
        var i = start
        var nested: [Int] = []
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`", let span = Self.codeSpan(chars, at: i) { i = span.end; continue }
            if chars[i] == "[", let link = link(at: i) { i = link.end; continue }
            if chars[i] == delimiter.first! {
                var end = i
                while end < chars.count && chars[end] == delimiter.first! { end += 1 }
                let canClose = i > start && !chars[i - 1].isWhitespace
                    && (delimiter.first != "_" || end == chars.count || (!chars[end].isLetter && !chars[end].isNumber))
                let canOpen = end < chars.count && !chars[end].isWhitespace
                    && (delimiter.first != "_" || i == 0 || (!chars[i - 1].isLetter && !chars[i - 1].isNumber))
                var remaining = end - i
                if canClose {
                    // **外 *内*** の3個は内側1個→外側2個の順に閉じる。
                    // 完全なCommonMarkのdelimiter stackではなく、同じ記号の有限な装飾だけ扱う。
                    while let inner = nested.last, remaining >= inner {
                        remaining -= inner; nested.removeLast()
                    }
                    if nested.isEmpty && remaining >= delimiter.count {
                        return end - remaining
                    }
                }
                if canOpen && remaining > 0 {
                    nested.append(min(remaining, delimiter.first == "~" ? 2 : 3))
                }
                i = end; continue
            }
            i += 1
        }
        return nil
    }
}
