import AppKit
import KikigakiCore

/// 返事を1つのtextStorageに載せ、コード・表を跨ぐ選択とコピーを保つ。
/// NSTextTableを使うためTextKit 1を明示し、計測も表示と同じlayoutManagerで行う。
final class MarkdownBodyView: NSTextView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // 選択の追跡を終えてから既読を保存する。ピルが消える再レイアウトで
        // ドラッグ選択の開始位置が動かないようにする。
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    private var source: String?
    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat = 0
    /// 描画は幅を知らずに1回だけ行うので、表の列は自然幅のまま置かれている。
    /// 本文幅が決まってから、収まらない表だけ列を詰め直すために覚えておく。
    private var tables: [TableColumns] = []
    private var appliedWidth: CGFloat?

    private struct TableColumns {
        let cells: [[NSTextTableBlock]]
        let naturals: [CGFloat]
    }

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        allowsUndo = false
        drawsBackground = false
        textContainerInset = NSSize(width: 2, height: 2)
        isHorizontallyResizable = false
        isVerticallyResizable = false
        linkTextAttributes = [.foregroundColor: Washi.red, .underlineStyle: NSUnderlineStyle.single.rawValue]
        setAccessibilityLabel("AIの返事")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        _ = height(for: newSize.width)
    }

    func update(_ markdown: String) {
        // 既読化・改名・録音の進行では文字列を差し替えず、選択とスクロール位置を保つ。
        guard source != markdown else { return }
        source = markdown
        textStorage?.setAttributedString(MarkdownBodyRenderer.render(MarkdownBlocks.parse(markdown)))
        measuredWidth = nil
        appliedWidth = nil
        collectTables()
    }

    /// 表の枡を列ごとに集める。自然幅は描画が置いた絶対値をそのまま覚える。
    /// コード・引用・水平線の器は割合で幅を持つので、絶対値の枡だけを拾って区別する。
    private func collectTables() {
        tables = []
        guard let storage = textStorage, storage.length > 0 else { return }
        var order: [NSTextTable] = []
        var columns: [ObjectIdentifier: [Int: [NSTextTableBlock]]] = [:]
        var naturals: [ObjectIdentifier: [Int: CGFloat]] = [:]
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            // admonitionの中の表は外側の器が前置されるので、最も内側の器を見る。
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                  cell.contentWidthValueType == .absoluteValueType else { return }
            let key = ObjectIdentifier(cell.table)
            if columns[key] == nil { order.append(cell.table) }
            columns[key, default: [:]][cell.startingColumn, default: []].append(cell)
            naturals[key, default: [:]][cell.startingColumn] = cell.contentWidth
        }
        tables = order.compactMap { table in
            let key = ObjectIdentifier(table)
            let indices = Array(0..<table.numberOfColumns)
            guard let cells = columns[key], let widths = naturals[key],
                  indices.allSatisfy({ cells[$0] != nil && widths[$0] != nil }) else { return nil }
            return TableColumns(cells: indices.map { cells[$0]! }, naturals: indices.map { widths[$0]! })
        }
    }

    /// 収まらない表だけ、広い列から順に均して詰める。狭い列は自然幅のまま残すので、
    /// 比例配分のように短い見出しが1文字ずつ折り返すことがない。
    private func applyTableWidths(available: CGFloat) -> Bool {
        guard appliedWidth != available else { return false }
        appliedWidth = available
        guard !tables.isEmpty else { return false }
        for table in tables {
            // 枡ごとの余白5pt×2と罫0.5pt×2は幅の予算から先に引く。
            let widths = MarkdownBodyView.fit(table.naturals, into: available - CGFloat(table.naturals.count) * 11)
            for (column, cells) in table.cells.enumerated() {
                for cell in cells { cell.setContentWidth(widths[column], type: .absoluteValueType) }
            }
        }
        return true
    }

    /// 自然幅の合計が予算を超えるときだけ、広い列から等しく詰める最大公平配分。
    /// 下限24ptを割ってもなお超える表は、TextKitが器の幅まで比例で詰める。
    static func fit(_ naturals: [CGFloat], into budget: CGFloat) -> [CGFloat] {
        guard budget > 0, naturals.reduce(0, +) > budget else { return naturals }
        var widths = naturals
        var remaining = budget
        var left = naturals.count
        for index in naturals.indices.sorted(by: { naturals[$0] < naturals[$1] }) {
            let share = max(24, remaining / CGFloat(left))
            widths[index] = min(naturals[index], share)
            remaining -= widths[index]
            left -= 1
        }
        return widths
    }

    func height(for width: CGFloat) -> CGFloat {
        if measuredWidth == width { return measuredHeight }
        guard let container = textContainer, let manager = layoutManager else { return 0 }
        let inner = max(1, width - textContainerInset.width * 2)
        container.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        if applyTableWidths(available: inner), let storage = textStorage {
            // 枡の幅は段落属性の変更ではないので、器の寸法だけでは組み直されない。
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                     actualCharacterRange: nil)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let extra = manager.extraLineFragmentTextContainer === container ? manager.extraLineFragmentRect.maxY : 0
        measuredHeight = ceil(max(used.maxY, extra) + textContainerInset.height * 2)
        measuredWidth = width
        return measuredHeight
    }
}

/// フォント・色・段落はここでだけ決める。保存する返事本文とCoreのトークンは変更しない。
enum MarkdownBodyRenderer {
    static func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        render(blocks, into: result, enclosing: [])
        // 表の空セル・空コードにも終端段落が必要。通常本文の余分な終端だけを取り除く。
        if result.length > 0 {
            let last = result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil) as? NSParagraphStyle
            if last?.textBlocks.isEmpty != false { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        }
        return result
    }

    /// admonitionの本文は外側の器を持ったまま再帰で描く。1つのtextStorageのままにして、
    /// 枠を跨ぐ選択とコピーを保つ。
    private static func render(_ blocks: [MarkdownBlock], into result: NSMutableAttributedString,
                               enclosing: [NSTextBlock]) {
        // `<br>` は段落を割らずに行だけ折る。文字は通常の改行にしてコピーの見え方を保ち、
        // 折り返し後の行は本文の開始位置(headIndent)へ揃え、段落の余白は最後の行にだけ残す。
        func append(_ runs: [MarkdownInline], paragraph: NSMutableParagraphStyle = paragraph(),
                    size: CGFloat = 15, weight: NSFont.Weight = .regular,
                    color: NSColor = Washi.ink, code: Bool = false) {
            guard runs.contains(where: \.isLineBreak) else {
                line(runs, paragraph: paragraph, size: size, weight: weight, color: color, code: code)
                return
            }
            var segments: [[MarkdownInline]] = [[]]
            for run in runs {
                if run.isLineBreak { segments.append([]) } else { segments[segments.count - 1].append(run) }
            }
            for (index, segment) in segments.enumerated() {
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                if index > 0 { style.firstLineHeadIndent = paragraph.headIndent }
                if index < segments.count - 1 { style.paragraphSpacing = 0 }
                line(segment, paragraph: style, size: size, weight: weight, color: color, code: code)
            }
        }
        func line(_ runs: [MarkdownInline], paragraph: NSMutableParagraphStyle = paragraph(),
                  size: CGFloat = 15, weight: NSFont.Weight = .regular,
                  color: NSColor = Washi.ink, code: Bool = false) {
            paragraph.textBlocks = enclosing + paragraph.textBlocks
            var attributes: [NSAttributedString.Key: Any] = [
                .font: code ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .paragraphStyle: paragraph
            ]
            for run in runs {
                let font = run.isCode || code
                    ? NSFont.monospacedSystemFont(ofSize: run.isCode ? max(13, size * 0.85) : size, weight: run.style.contains(.strong) ? .semibold : weight)
                    : NSFont.systemFont(ofSize: size, weight: run.style.contains(.strong) ? .semibold : weight)
                var current = attributes
                current[.font] = font
                if run.style.contains(.emphasis) { current[.obliqueness] = 0.15 }
                if run.style.contains(.strikethrough) {
                    current[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    current[.foregroundColor] = Washi.muted
                }
                if run.isCode { current[.backgroundColor] = Washi.shade }
                if run.destination != nil {
                    current[.foregroundColor] = Washi.red
                    current[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    if let url = run.webURL { current[.link] = url }
                }
                result.append(NSAttributedString(string: run.text, attributes: current))
            }
            // 空の段落も属性を持たせ、空セルや空のコードブロックをレイアウトできるようにする。
            attributes[.paragraphStyle] = paragraph
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        for (index, block) in blocks.enumerated() {
            switch block {
            case .paragraph(let runs):
                let style = paragraph(spacing: runs.isEmpty ? 0 : 3)
                if runs.isEmpty, index > 0, case .heading = blocks[index - 1] {
                    // 原文の空行をコピーには残し、見出しと本文の視覚的な分離だけ抑える。
                    style.minimumLineHeight = 0.1
                    style.maximumLineHeight = 0.1
                    style.lineSpacing = 0
                }
                append(runs, paragraph: style, size: runs.isEmpty ? 6 : 15)
            case .heading(let level, let content):
                let style = paragraph(spacing: 5)
                style.paragraphSpacingBefore = result.length == 0 ? 0 : [14.0, 11, 8][min(max(level, 1), 3) - 1]
                append(content, paragraph: style, size: [18.0, 16, 15, 15][min(max(level, 1), 4) - 1], weight: .semibold,
                       color: level >= 4 ? Washi.muted : Washi.ink)
            case .listItem(let item):
                let marker = (item.ordered ? item.marker : item.checked == nil ? "•" : "")
                    + (item.checked.map { (item.ordered ? " " : "") + ($0 ? "☑" : "☐") } ?? "")
                let style = paragraph(spacing: 3)
                let indent = CGFloat(item.depth) * 18
                let markerWidth = ceil((marker as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15)]).width)
                style.firstLineHeadIndent = indent
                style.headIndent = indent + markerWidth + 7
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                let start = result.length
                append([.init(marker + "\t")] + item.content, paragraph: style)
                result.addAttribute(.foregroundColor, value: Washi.muted,
                                    range: NSRange(location: start, length: (marker as NSString).length))
            case .quote(let lines):
                let box = fullWidthBlock()
                box.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                box.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
                box.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
                box.setBorderColor(Washi.rule)
                box.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
                box.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                for line in lines {
                    let style = paragraph(spacing: 2)
                    style.textBlocks = [box]
                    style.firstLineHeadIndent = CGFloat(max(0, line.depth - 1)) * 12
                    style.headIndent = style.firstLineHeadIndent
                    append(line.content, paragraph: style, color: Washi.muted)
                }
            case .code(let text, _):
                let box = fullWidthBlock()
                box.backgroundColor = Washi.shade
                box.setWidth(8, type: .absoluteValueType, for: .padding)
                box.setWidth(5, type: .absoluteValueType, for: .margin, edge: .minY)
                box.setWidth(5, type: .absoluteValueType, for: .margin, edge: .maxY)
                let style = paragraph(spacing: 0)
                style.textBlocks = [box]
                style.lineBreakMode = .byCharWrapping
                style.headIndent = 16
                style.lineSpacing = 2
                style.tabStops = []
                style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
                append([.init(text)], paragraph: style, size: 13, code: true)
            case .table(let model):
                let table = NSTextTable()
                table.numberOfColumns = model.header.count
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.collapsesBorders = true
                table.hidesEmptyCells = false
                // 表の幅は指定せず、列の絶対幅の合計からTextKitに決めさせる。短い表は本文幅まで
                // 伸びず左に寄る。描画は幅を知らずに1回だけ行うので、ここでは自然幅を置くだけにし、
                // 合計が本文幅を超える表の詰め直しは幅が決まる height(for:) に任せる。
                let rows = [model.header] + model.rows
                // 列幅はその列のヘッダ・ボディの自然幅の最大。見出しはsemiboldで測る。
                // 上限は長いセル1つが他の列を押し潰さないため。
                let widths = model.header.indices.map { column -> CGFloat in
                    let natural = rows.enumerated().map { row, cells in
                        let font = NSFont.systemFont(ofSize: 13, weight: row == 0 ? .semibold : .regular)
                        return (cells[column].map(\.text).joined() as NSString).size(withAttributes: [.font: font]).width
                    }.max() ?? 0
                    // +1は測定と組版の丸め差で最後の1文字が折り返さないための余裕。
                    return min(260, max(24, ceil(natural) + 1))
                }
                for (row, cells) in rows.enumerated() {
                    for (column, content) in cells.enumerated() {
                        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        cell.setContentWidth(widths[column], type: .absoluteValueType)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(Washi.rule)
                        cell.setWidth(5, type: .absoluteValueType, for: .padding)
                        cell.verticalAlignment = .topAlignment
                        if row == 0 {
                            cell.backgroundColor = Washi.shade
                            cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                        }
                        let style = paragraph(spacing: 0)
                        style.lineSpacing = 2
                        style.textBlocks = [cell]
                        switch model.alignments[column] {
                        case .left: style.alignment = .left
                        case .center: style.alignment = .center
                        case .right: style.alignment = .right
                        }
                        append(content, paragraph: style, size: 13, weight: row == 0 ? .semibold : .regular)
                    }
                }
            case .rule:
                let box = fullWidthBlock()
                box.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                box.setBorderColor(Washi.rule)
                box.setWidth(12, type: .absoluteValueType, for: .margin, edge: .minY)
                box.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
                let style = paragraph(spacing: 0)
                style.textBlocks = [box]
                style.lineSpacing = 0
                append([], paragraph: style, size: 1)
            case .admonition(let admonition):
                // 引用は細い罫と薄墨の本文だけ。admonitionは色の付いた太い左罫と題の帯で見分ける。
                let accent = accent(admonition.kind)
                let table = NSTextTable()
                table.numberOfColumns = 1
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.setContentWidth(100, type: .percentageValueType)
                // 題を空にした指定では帯を出さない。本文が無ければ帯だけで枠を描く。
                let hasBand = !admonition.title.isEmpty, hasBody = !admonition.blocks.isEmpty
                let cells = (0..<max(1, (hasBand ? 1 : 0) + (hasBody ? 1 : 0))).map { row -> NSTextTableBlock in
                    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: 0, columnSpan: 1)
                    cell.setContentWidth(100, type: .percentageValueType)
                    cell.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                    cell.setBorderColor(accent)
                    cell.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minX)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
                    cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
                    cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
                    return cell
                }
                cells.first?.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
                cells.last?.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
                if hasBand {
                    cells[0].backgroundColor = Washi.shade
                    let style = paragraph(spacing: 0)
                    style.textBlocks = [cells[0]]
                    append(admonition.title, paragraph: style, size: 14, weight: .semibold, color: accent)
                }
                if hasBody, let body = cells.last {
                    render(admonition.blocks, into: result, enclosing: enclosing + [body])
                }
            }
        }
    }

    /// 種別ごとの色は既存のWashiだけを使う。未知の種別はnoteと同じ顔にする。
    private static func accent(_ kind: MarkdownAdmonition.Kind) -> NSColor {
        switch kind {
        case .danger, .error, .bug, .failure: return Washi.red
        case .warning, .attention, .caution: return Washi.goldInk
        case .tip, .hint, .important, .success: return Washi.ai.background
        case .note, .info, .abstract, .summary, .seealso, .example, .question, .quote: return Washi.muted
        }
    }

    private static func fullWidthBlock() -> NSTextBlock {
        // 素のNSTextBlockはTextKit 1の実画面でpadding・地色・罫が反映されない。
        // そのサブクラスの1セルブロックでネイティブの段落枠を使う。別ビューや画像にはせず、
        // コード・引用・本文を跨ぐ選択とコピーを同じtextStorageに保つ。
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        cell.setContentWidth(100, type: .percentageValueType)
        return cell
    }

    private static func paragraph(spacing: CGFloat = 3) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        return style
    }
}
