import AppKit
import KikigakiCore

/// AIの送信と返事を、人の発話と同じ行の形で並べる。畳んだ印は使わない。
/// 位置と表示値は `AITimeline.items` が決め、ここは描き方だけを持つ。
@MainActor protocol AITimelineRowView: DocumentRow {
    var item: AITimeline.Item { get }
    func update(_ item: AITimeline.Item, state: AIViewState)
}

enum AIRowMetrics {
    static let bodyX: CGFloat = 54
    static let avatar = NSRect(x: 20, y: 8, width: 25, height: 26)
    static func bodyWidth(_ width: CGFloat) -> CGFloat { max(44, width - 90) }
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    static func measure(_ field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(44, width), height: .greatestFiniteMagnitude)).height ?? 0)
    }
}

/// 未読・確認待ち・返事待ちの印。押して既読にできるのは未読だけで、
/// 他は状態表示なので操作を持たせない。無効でも面は足さず、色だけを抜く。
final class AIStatusPill: NSButton {
    enum Style: Equatable { case unread, confirmation, waiting }
    private(set) var style: Style = .waiting
    private var configured = false
    var callback: (() -> Void)?
    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        font = .systemFont(ofSize: 11, weight: .bold)
        target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ style: Style) {
        guard self.style != style || !configured else { return }
        configured = true
        self.style = style
        title = style == .unread ? "未読" : style == .confirmation ? "確認待ち" : "返事待ち"
        isEnabled = style == .unread
        toolTip = style == .unread ? "押すと既読にします" : nil
        setAccessibilityLabel(title + (style == .unread ? "、押すと既読にします" : ""))
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 16, height: 20)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = style == .unread ? Washi.red : style == .confirmation ? Washi.gold : Washi.muted
        let filled = style != .waiting
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        if filled { color.setFill(); pill.fill() }
        else { color.setStroke(); pill.lineWidth = 1; pill.stroke() }
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: filled ? NSColor.white : color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
    @objc private func pressed() { callback?() }
}

/// 行の中の操作。押せることが分かるよう枠のピルで描く。
/// 無効な場面ではボタン自体を出さないので、無効時に面を足す状態は作らない。
final class AIRowActionButton: NSButton {
    var callback: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        callback = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 12)
        target = self; self.action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    var measuredWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 24 }
    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        Washi.muted.setStroke(); pill.lineWidth = 1; pill.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: Washi.ink]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
    @objc private func pressed() { callback?() }
}

/// 宛名の枠ピル。人側の送信行の右端に置く。
final class AIAddressPill: NSView {
    override var isFlipped: Bool { true }
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    private var font: NSFont { .systemFont(ofSize: 11, weight: .bold) }
    var measuredWidth: CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16 }
    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Washi.muted.setStroke(); pill.lineWidth = 1; pill.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Washi.muted]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}

/// 返事の上へ添える送信文の引用。既定は1行で末尾を省略し、押すと全文へ伸びる。
final class AIQuoteButton: NSButton {
    private(set) var expanded = false
    var text = ""
    var onToggle: (() -> Void)?
    init() {
        super.init(frame: .zero)
        isBordered = false
        target = self; action = #selector(pressed)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        refresh()
    }
    private func refresh() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        paragraph.lineSpacing = expanded ? 3 : 0
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Washi.muted, .paragraphStyle: paragraph
        ])
        cell?.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        (cell as? NSButtonCell)?.wraps = expanded
        toolTip = text
        setAccessibilityLabel("送信文 " + text + (expanded ? "、畳む" : "、全文を表示する"))
        needsDisplay = true
    }
    func height(for width: CGFloat) -> CGFloat {
        guard expanded else { return 18 }
        let bounds = NSRect(x: 0, y: 0, width: max(44, width - 12), height: .greatestFiniteMagnitude)
        return max(18, ceil(cell?.cellSize(forBounds: bounds).height ?? 18))
    }
    override func draw(_ dirtyRect: NSRect) {
        Washi.rule.setFill()
        NSRect(x: 0, y: 1, width: 2, height: max(0, bounds.height - 2)).fill()
        super.draw(dirtyRect)
    }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0) }
    @objc private func pressed() {
        expanded.toggle()
        refresh()
        onToggle?()
    }
}

/// 声からの送信と自動送信の細い1行。発話の直下か日時順に置く。
final class AISendLineRow: NSView, AITimelineRowView {
    override var isFlipped: Bool { true }
    private(set) var item: AITimeline.Item
    private let label = Washi.label(size: 11, color: Washi.muted)
    var displayText: String { label.stringValue }
    init(item: AITimeline.Item, state: AIViewState) {
        self.item = item
        super.init(frame: .zero)
        addSubview(label)
        label.lineBreakMode = .byTruncatingTail
        update(item, state: state)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ item: AITimeline.Item, state: AIViewState) {
        self.item = item
        let verb = item.automatic ? "へ自動送信" : "へ送信"
        var parts = ["└ " + item.participantName + verb] + item.notes
        if let date = item.date { parts.append(AIRowMetrics.clock.string(from: date)) }
        label.stringValue = parts.joined(separator: " · ")
        // 自動送信は本数が増えるので、同じ形のまま薄くして目立たせない。
        label.textColor = item.automatic ? Washi.muted.withAlphaComponent(0.65) : Washi.muted
        let range = item.timeRange.map { "\($0.start)〜\($0.end)" }
        label.toolTip = ([label.stringValue, range, item.question.isEmpty ? nil : item.question]
            .compactMap { $0 }).joined(separator: "\n")
        label.setAccessibilityLabel(label.stringValue)
        needsLayout = true
    }
    func height(for width: CGFloat) -> CGFloat { 24 }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: AIRowMetrics.bodyX, y: 3, width: max(0, bounds.width - AIRowMetrics.bodyX - 20), height: 18)
    }
}

/// 問い欄へ入力した送信と、確認への返答。人側の行として送信文そのものを置く。
/// 「手入力」とは別の名前・記号にする。手入力は会議Markdownへ残る投稿の固定名で、
/// AIへ送っただけの文が議事録に載っていると誤解させるため。
final class AITypedSendRow: NSView, AITimelineRowView {
    override var isFlipped: Bool { true }
    private(set) var item: AITimeline.Item
    private let avatar = AvatarView()
    private let nameLabel = Washi.label("AIへ送信", size: 12, weight: .semibold)
    private let timeLabel = Washi.label(color: Washi.muted)
    private let noteLabel = Washi.label(size: 11, color: Washi.muted)
    private let address = AIAddressPill()
    private let body = NSTextField(wrappingLabelWithString: "")
    private var measured: CGFloat = 0
    var displayName: String { nameLabel.stringValue }
    var addressText: String { address.text }
    var noteText: String { noteLabel.stringValue }
    init(item: AITimeline.Item, state: AIViewState) {
        self.item = item
        super.init(frame: .zero)
        avatar.typed = true
        avatar.glyph = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "AIへ送信")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Washi.paper]))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        noteLabel.lineBreakMode = .byTruncatingTail
        body.isSelectable = true
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        for view in [avatar, nameLabel, timeLabel, noteLabel, address, body] { addSubview(view) }
        update(item, state: state)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ item: AITimeline.Item, state: AIViewState) {
        self.item = item
        timeLabel.stringValue = item.date.map(AIRowMetrics.clock.string(from:)) ?? ""
        let parent = item.parentNumber.map { "#\($0)への返答" }
        noteLabel.stringValue = ([parent].compactMap { $0 } + item.notes).joined(separator: " · ")
        noteLabel.toolTip = ([noteLabel.stringValue, item.timeRange.map { "\($0.start)〜\($0.end)" }]
            .compactMap { $0 }).joined(separator: "\n")
        address.text = item.participantName + "へ"
        avatar.setAccessibilityLabel("AIへ送信")
        if body.stringValue != item.question {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
            body.attributedStringValue = NSAttributedString(string: item.question, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: Washi.ink, .paragraphStyle: paragraph
            ])
            measured = 0
        }
        avatar.needsDisplay = true
        needsLayout = true
    }
    func height(for width: CGFloat) -> CGFloat {
        measured = AIRowMetrics.measure(body, width: AIRowMetrics.bodyWidth(width))
        return max(20, measured) + 36
    }
    override func layout() {
        super.layout()
        avatar.frame = AIRowMetrics.avatar
        let nameWidth = ceil(nameLabel.intrinsicContentSize.width) + 4
        nameLabel.frame = NSRect(x: AIRowMetrics.bodyX, y: 8, width: nameWidth, height: 18)
        timeLabel.frame = NSRect(x: AIRowMetrics.bodyX + nameWidth + 12, y: 8, width: 62, height: 18)
        let pillWidth = address.measuredWidth
        address.frame = NSRect(x: bounds.width - 20 - pillWidth, y: 8, width: pillWidth, height: 20)
        let noteX = timeLabel.frame.maxX + 8
        noteLabel.frame = NSRect(x: noteX, y: 9, width: max(0, address.frame.minX - noteX - 8), height: 16)
        body.frame = NSRect(x: AIRowMetrics.bodyX, y: 31, width: AIRowMetrics.bodyWidth(bounds.width), height: max(20, bounds.height - 36))
    }
}

/// AIの行。返事待ち・返事・確認質問・失敗を同じ行IDで扱い、到着で生まれ直さない。
final class AIReplyRow: NSView, AITimelineRowView {
    override var isFlipped: Bool { true }
    private(set) var item: AITimeline.Item
    private var state: AIViewState
    var onRead: (() -> Void)?
    var onReply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onResize: (() -> Void)?
    private let avatar = AvatarView()
    private let nameLabel = Washi.label(size: 12, weight: .semibold)
    private let chip = Washi.label(size: 10, color: Washi.muted)
    private let timeLabel = Washi.label(color: Washi.muted)
    private let pill = AIStatusPill()
    private let quote = AIQuoteButton()
    private let markdownBody = MarkdownBodyView()
    private let waitingBody = Washi.label("考え中…", size: 15, color: Washi.muted)
    private let confirmationMark = Washi.label("?", size: 15, color: Washi.muted)
    private let notes = NSTextField(wrappingLabelWithString: "")
    private let failureLabel = Washi.label(size: 13, weight: .semibold)
    private lazy var replyAction = AIRowActionButton("返答する") { [weak self] in self?.onReply?() }
    private lazy var cancelAction = AIRowActionButton("取消") { [weak self] in self?.onCancel?() }
    private lazy var retryAction = AIRowActionButton("再送") { [weak self] in self?.onRetry?() }
    private var measuredQuote: CGFloat = 0
    private var measuredBody: CGFloat = 0
    private var measuredNotes: CGFloat = 0
    var chipText: String { chip.stringValue }
    var chipVisible: Bool { !chip.isHidden }
    var timeText: String { timeLabel.isHidden ? "" : timeLabel.stringValue }
    var noteText: String { notes.isHidden ? "" : notes.stringValue }
    var failureText: String { failureLabel.stringValue }
    var quoteButton: AIQuoteButton { quote }
    var statusPill: AIStatusPill { pill }

    var isFailure: Bool { if case .failure = item.kind { return true }; return false }
    var isWaiting: Bool { item.kind == .reply(.waiting) }
    /// 未読は朱、未返答の確認は金。既読と返答済みは薄墨へ戻す。
    var accent: NSColor? {
        if isFailure { return Washi.red }
        // 確認質問の金の帯は返答するまで残す。既読では消さない。
        if item.kind == .reply(.needsInput) { return item.needsAnswer ? Washi.gold : nil }
        return item.isUnread ? Washi.red : nil
    }
    var pillStyle: AIStatusPill.Style? {
        if isWaiting { return .waiting }
        if item.kind == .reply(.needsInput) { return item.needsAnswer ? .confirmation : nil }
        // 返送された失敗も未読になる。送信前の失敗は未読にならないので印も出ない。
        return item.isUnread ? .unread : nil
    }

    init(item: AITimeline.Item, state: AIViewState) {
        self.item = item; self.state = state
        super.init(frame: .zero)
        avatar.accent = Washi.ai
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        chip.alignment = .center
        notes.isSelectable = true; notes.maximumNumberOfLines = 0; notes.lineBreakMode = .byWordWrapping
        failureLabel.lineBreakMode = .byTruncatingTail
        pill.callback = { [weak self] in self?.onRead?() }
        quote.onToggle = { [weak self] in self?.onResize?() }
        for view in [avatar, nameLabel, chip, timeLabel, pill, quote, markdownBody, waitingBody,
                     confirmationMark, notes, failureLabel, replyAction, cancelAction, retryAction] { addSubview(view) }
        update(item, state: state)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ item: AITimeline.Item, state: AIViewState) {
        let widthChanged = self.item.body != item.body || self.item.question != item.question
        self.item = item; self.state = state
        nameLabel.stringValue = item.participantName
        nameLabel.textColor = isWaiting ? Washi.muted : Washi.ink
        avatar.tentative = isWaiting
        avatar.initial = String(item.participantName.prefix(1))
        avatar.setAccessibilityLabel(item.participantName)
        avatar.needsDisplay = true
        chip.stringValue = item.automatic ? "自動" : "AI"
        timeLabel.stringValue = item.date.map(AIRowMetrics.clock.string(from:)) ?? ""
        if let style = pillStyle { pill.update(style) }
        markdownBody.update(item.body)
        quote.update(item.question)
        if case let .failure(reason) = item.kind {
            // 帯は1行なので、取消後・旧接続などの注記も同じ行へ連ねる。
            failureLabel.stringValue = ([item.participantName + "へ送信できませんでした", reason] + item.notes).joined(separator: " · ")
            failureLabel.textColor = Washi.red
            failureLabel.toolTip = failureLabel.stringValue
        }
        // 注記はCoreが作る。接続の観測もitemsへ渡してあるので描画側で補わない。
        let text = item.notes.joined(separator: " · ")
        if notes.stringValue != text {
            notes.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Washi.muted
            ])
        }
        updateVisibility()
        if widthChanged { measuredBody = 0 }
        needsDisplay = true; needsLayout = true
    }

    private func updateVisibility() {
        let failure = isFailure
        failureLabel.isHidden = !failure
        retryAction.isHidden = !failure || state.readOnly
        for view in [avatar, nameLabel] { view.isHidden = failure }
        // 失敗の帯にも確定時刻を出す。返事待ちは到着していないので時刻も種別も出さない。
        timeLabel.isHidden = isWaiting
        chip.isHidden = failure || isWaiting
        pill.isHidden = pillStyle == nil
        quote.isHidden = failure || item.question.isEmpty
        markdownBody.isHidden = failure || isWaiting
        waitingBody.isHidden = failure || !isWaiting
        confirmationMark.isHidden = failure || !item.needsAnswer
        notes.isHidden = failure || notes.stringValue.isEmpty
        replyAction.isHidden = failure || !item.needsAnswer || state.readOnly
        cancelAction.isHidden = failure || !isWaiting || state.readOnly
        setAccessibilityLabel(failure ? failureLabel.stringValue
            : item.participantName + "、" + (isWaiting ? "返事待ち" : chip.stringValue) + (pillStyle == .unread ? "、未読" : ""))
    }

    func height(for width: CGFloat) -> CGFloat {
        if isFailure { return 34 }
        let bodyWidth = AIRowMetrics.bodyWidth(width)
        measuredQuote = item.question.isEmpty ? 0 : quote.height(for: bodyWidth) + 8
        // 測る前に表示と同じ幅の枠を与える。幅0のまま測るとTextKitが器の寸法を誤り、
        // 表やコードを含む返事の高さが一度だけ跳ね上がったまま計測値に残る。
        if markdownBody.frame.width != bodyWidth {
            markdownBody.setFrameSize(NSSize(width: bodyWidth, height: markdownBody.frame.height))
        }
        measuredBody = isWaiting ? 20 : markdownBody.height(for: bodyWidth)
        measuredNotes = notes.isHidden ? 0 : AIRowMetrics.measure(notes, width: bodyWidth) + 6
        let actions = [replyAction, cancelAction].contains { !$0.isHidden } ? 30.0 : 0
        return 31 + measuredQuote + max(20, measuredBody) + measuredNotes + actions + 9
    }

    override func layout() {
        super.layout()
        if isFailure {
            let retryWidth = retryAction.measuredWidth
            retryAction.frame = NSRect(x: bounds.width - 20 - retryWidth, y: 5, width: retryWidth, height: 24)
            timeLabel.frame = NSRect(x: retryAction.frame.minX - 70, y: 6, width: 62, height: 18)
            // 返送された失敗は未読になるので、押して既読にできる印を帯の中へ置く。
            let pillWidth = pill.isHidden ? 0 : ceil(pill.intrinsicContentSize.width)
            pill.frame = NSRect(x: timeLabel.frame.minX - 8 - pillWidth, y: 5, width: pillWidth, height: 20)
            let end = pill.isHidden ? timeLabel.frame.minX : pill.frame.minX
            failureLabel.frame = NSRect(x: AIRowMetrics.bodyX, y: 7, width: max(0, end - AIRowMetrics.bodyX - 8), height: 18)
            return
        }
        avatar.frame = AIRowMetrics.avatar
        let nameWidth = ceil(nameLabel.intrinsicContentSize.width) + 4
        nameLabel.frame = NSRect(x: AIRowMetrics.bodyX, y: 8, width: nameWidth, height: 18)
        let chipWidth = chip.isHidden ? 0 : ceil(chip.intrinsicContentSize.width) + 12
        chip.frame = NSRect(x: nameLabel.frame.maxX + 8, y: 9, width: chipWidth, height: 16)
        timeLabel.frame = NSRect(x: nameLabel.frame.maxX + (chip.isHidden ? 12 : chipWidth + 16), y: 8, width: 62, height: 18)
        let pillWidth = ceil(pill.intrinsicContentSize.width)
        pill.frame = NSRect(x: bounds.width - 20 - pillWidth, y: 8, width: pillWidth, height: 20)
        let bodyWidth = AIRowMetrics.bodyWidth(bounds.width)
        quote.frame = NSRect(x: AIRowMetrics.bodyX, y: 31, width: bodyWidth, height: max(0, measuredQuote - 8))
        let bodyY = 31 + measuredQuote
        markdownBody.frame = NSRect(x: AIRowMetrics.bodyX, y: bodyY, width: bodyWidth, height: max(20, measuredBody))
        waitingBody.frame = NSRect(x: AIRowMetrics.bodyX, y: bodyY, width: bodyWidth, height: 20)
        confirmationMark.frame = NSRect(x: AIRowMetrics.bodyX - 14, y: bodyY + 2, width: 12, height: 20)
        notes.frame = NSRect(x: AIRowMetrics.bodyX, y: markdownBody.frame.maxY + 6, width: bodyWidth, height: max(0, measuredNotes - 6))
        var x = AIRowMetrics.bodyX
        for button in [replyAction, cancelAction] where !button.isHidden {
            let width = button.measuredWidth
            button.frame = NSRect(x: x, y: markdownBody.frame.maxY + measuredNotes + 4, width: width, height: 24)
            x += width + 10
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let accent else { return }
        let band = bounds.insetBy(dx: 12, dy: 2)
        accent.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: band, xRadius: 5, yRadius: 5).fill()
        accent.setFill()
        NSRect(x: band.minX, y: band.minY, width: 3, height: band.height).fill()
    }
}
