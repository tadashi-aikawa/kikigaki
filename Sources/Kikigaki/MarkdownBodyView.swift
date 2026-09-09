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
    }

    func height(for width: CGFloat) -> CGFloat {
        if measuredWidth == width { return measuredHeight }
        guard let container = textContainer, let manager = layoutManager else { return 0 }
        container.containerSize = NSSize(width: max(1, width - textContainerInset.width * 2),
                                         height: .greatestFiniteMagnitude)
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
        func append(_ runs: [MarkdownInline], paragraph: NSMutableParagraphStyle = paragraph(),
                    size: CGFloat = 15, weight: NSFont.Weight = .regular,
                    color: NSColor = Washi.ink, code: Bool = false) {
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
                table.setContentWidth(100, type: .percentageValueType)
                let rows = [model.header] + model.rows
                // 短い番号列と長い説明列を同じ幅にせず、内容から割合を配分する。
                // 上限は長いセル1つが他の列を押し潰さないため。実幅は表全体に追従させる。
                let widths = model.header.indices.map { column -> CGFloat in
                    let natural = rows.map { row in
                        (row[column].map(\.text).joined() as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
                    }.max() ?? 0
                    return min(260, max(32, natural + 12))
                }
                let total = widths.reduce(0, +)
                for (row, cells) in rows.enumerated() {
                    for (column, content) in cells.enumerated() {
                        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        cell.setContentWidth(widths[column] / total * 100, type: .percentageValueType)
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
            }
        }
        // 表の空セル・空コードにも終端段落が必要。通常本文の余分な終端だけを取り除く。
        if result.length > 0 {
            let last = result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil) as? NSParagraphStyle
            if last?.textBlocks.isEmpty != false { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        }
        return result
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
