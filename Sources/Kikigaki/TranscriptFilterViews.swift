import AppKit
import KikigakiCore

/// 絞り込みで畳んだ行の代わりに置く1行。押すとその区間を開く。
/// 操作部なので文字の倍率は掛けない。
final class TranscriptFilterGapRow: HoverButton, DocumentRow {
    override var isFlipped: Bool { true }
    override var drawsHoverBackground: Bool { false }
    private(set) var count = 0
    /// 畳んだ行の同一性。開くときにまとめて覚える。
    private(set) var keys: [TranscriptWindowController.FilterRowKey] = []
    var onExpand: (() -> Void)?
    var text: String { "ほかの発言 \(count)件" }

    init() {
        super.init(frame: .zero)
        title = ""; isBordered = false
        target = self; action = #selector(pressed)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(count: Int, keys: [TranscriptWindowController.FilterRowKey]) {
        self.keys = keys
        guard self.count != count else { return }
        self.count = count
        toolTip = "\(text)を表示"
        setAccessibilityLabel(toolTip)
        needsDisplay = true
    }
    func height(for width: CGFloat) -> CGFloat { 30 }
    @objc private func pressed() { onExpand?() }

    override func draw(_ dirtyRect: NSRect) {
        let area = NSRect(x: 54, y: 4, width: max(0, bounds.width - 74), height: 22)
        if isEnabled && (isHovered || isHighlighted) {
            Washi.rule.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: area, xRadius: 6, yRadius: 6).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Washi.muted]
        let label = text as NSString
        let size = label.size(withAttributes: attributes)
        let x = area.midX - size.width / 2
        label.draw(at: NSPoint(x: x, y: area.midY - size.height / 2), withAttributes: attributes)
        // 文字の左右に破線を引き、行の間が詰まっていることを示す。
        Washi.rule.setStroke()
        for segment in [(area.minX + 8, x - 8), (x + size.width + 8, area.maxX - 8)] where segment.1 > segment.0 {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: segment.0, y: area.midY + 0.5))
            line.line(to: NSPoint(x: segment.1, y: area.midY + 0.5))
            line.lineWidth = 1
            line.setLineDash([3, 3], count: 2, phase: 0)
            line.stroke()
        }
    }
}

/// 絞り込み中の相手1人ぶんの札。✕でその相手を絞り込みから外す。
final class TranscriptFilterChip: NSView {
    static let height: CGFloat = 24
    static let maximumLabelWidth: CGFloat = 160
    override var isFlipped: Bool { true }
    let subject: TranscriptFilter.Subject
    let avatar = AvatarView()
    let label = Washi.label(size: 12)
    let remove = HoverButton()
    var onRemove: (() -> Void)?

    init(subject: TranscriptFilter.Subject) {
        self.subject = subject
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Washi.paper.cgColor
        layer?.borderColor = Washi.rule.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = Self.height / 2
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        remove.isBordered = false
        remove.title = ""
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        remove.imagePosition = .imageOnly
        remove.contentTintColor = Washi.muted
        remove.target = self; remove.action = #selector(removePressed)
        for view in [avatar, label, remove] { addSubview(view) }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(name: String) {
        label.stringValue = name
        label.toolTip = name
        remove.toolTip = "\(name)を絞り込みから外す"
        remove.setAccessibilityLabel(remove.toolTip)
        needsLayout = true
    }
    /// 切り詰め指定のラベルは内在幅が文字の幅より狭く出るので、文字そのものを測る。
    private var labelWidth: CGFloat {
        let text = label.stringValue as NSString
        let width = ceil(text.size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 12)]).width) + 4
        return min(width, Self.maximumLabelWidth)
    }
    var preferredWidth: CGFloat { 4 + 16 + 5 + labelWidth + 2 + 20 + 2 }
    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: 4, y: 4, width: 16, height: 16)
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 25, y: (Self.height - height) / 2, width: labelWidth, height: height)
        remove.frame = NSRect(x: label.frame.maxX + 2, y: 2, width: 20, height: 20)
    }
    @objc private func removePressed() { onRemove?() }
}

/// ヘッダーの下に出す絞り込み中の帯。札は幅に収まらなければ折り返す。
/// 全体の解除は置かず、最後の札を外すと絞り込みが解ける。
final class TranscriptFilterBar: NSView {
    struct Item {
        let subject: TranscriptFilter.Subject
        let name: String
        let configureAvatar: (AvatarView) -> Void
    }
    override var isFlipped: Bool { true }
    var onRemove: ((TranscriptFilter.Subject) -> Void)?
    /// 帯の出入りと高さの変化。書き起こしの表示域が変わるので、読んでいる位置を保ち直す。
    var onHeightChange: (() -> Void)?
    private(set) var chips: [TranscriptFilterChip] = []
    let title = Washi.label("絞り込み", size: 11, color: Washi.muted)
    private let icon = NSImageView()
    private var heightConstraint: NSLayoutConstraint!
    private static let inset = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    private static let spacing: CGFloat = 6

    init() {
        super.init(frame: .zero)
        Washi.surface(self)
        icon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = Washi.muted
        addSubview(icon); addSubview(title)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.inset.top + TranscriptFilterChip.height + Self.inset.bottom)
        heightConstraint.isActive = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("絞り込み中の話者")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ items: [Item]) {
        let existing = Dictionary(chips.map { ($0.subject, $0) }, uniquingKeysWith: { first, _ in first })
        let next = items.map { item -> TranscriptFilterChip in
            let chip = existing[item.subject] ?? TranscriptFilterChip(subject: item.subject)
            chip.update(name: item.name)
            item.configureAvatar(chip.avatar)
            chip.avatar.needsDisplay = true
            let subject = item.subject
            chip.onRemove = { [weak self] in self?.onRemove?(subject) }
            if chip.superview !== self { addSubview(chip) }
            return chip
        }
        for chip in chips where !next.contains(where: { $0 === chip }) { chip.removeFromSuperview() }
        chips = next
        let wasHidden = isHidden
        isHidden = items.isEmpty
        needsLayout = true
        if !resizeToFit(width: bounds.width) && wasHidden != isHidden { onHeightChange?() }
    }

    private var chipsStartX: CGFloat {
        Self.inset.left + 14 + 4 + ceil(title.intrinsicContentSize.width) + 10
    }
    /// 札を並べた枠を返す。幅が無いうちは1行に並べる。
    private func chipFrames(width: CGFloat) -> [NSRect] {
        let start = chipsStartX
        let limit = width > 0 ? width - Self.inset.right : .greatestFiniteMagnitude
        var x = start, y = Self.inset.top
        return chips.map { chip in
            let chipWidth = min(chip.preferredWidth, max(0, limit - start))
            if x > start && x + chipWidth > limit {
                x = start
                y += TranscriptFilterChip.height + Self.spacing
            }
            defer { x += chipWidth + Self.spacing }
            return NSRect(x: x, y: y, width: chipWidth, height: TranscriptFilterChip.height)
        }
    }
    private func fittingHeight(width: CGFloat) -> CGFloat {
        (chipFrames(width: width).map(\.maxY).max() ?? (Self.inset.top + TranscriptFilterChip.height)) + Self.inset.bottom
    }
    /// 高さが変われば制約を直して知らせる。変えたらtrue。
    @discardableResult
    private func resizeToFit(width: CGFloat) -> Bool {
        let height = fittingHeight(width: width)
        guard heightConstraint.constant != height else { return false }
        heightConstraint.constant = height
        onHeightChange?()
        return true
    }
    override func layout() {
        super.layout()
        let lineMid = Self.inset.top + TranscriptFilterChip.height / 2
        icon.frame = NSRect(x: Self.inset.left, y: lineMid - 7, width: 14, height: 14)
        let titleSize = title.intrinsicContentSize
        title.frame = NSRect(x: icon.frame.maxX + 4, y: lineMid - ceil(titleSize.height) / 2,
                             width: ceil(titleSize.width), height: ceil(titleSize.height))
        for (chip, frame) in zip(chips, chipFrames(width: bounds.width)) { chip.frame = frame }
        // 幅が変わって折り返しが変われば、配置の後で高さを合わせる。配置の途中で制約を変えない。
        if heightConstraint.constant != fittingHeight(width: bounds.width) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeToFit(width: self.bounds.width)
            }
        }
    }
}

/// ヘッダーの絞り込みボタンから開く、相手の選択。押すたびに表示へ反映する。
@MainActor
final class TranscriptFilterPopover: NSObject, NSPopoverDelegate {
    struct Item {
        let subject: TranscriptFilter.Subject
        let title: String
        let configureAvatar: (AvatarView) -> Void
    }
    var onToggle: ((TranscriptFilter.Subject, Bool) -> Void)?
    private let popover = NSPopover()
    private let stack = NSStackView()
    private let list = NSStackView()
    private let emptyHint = Washi.label("絞り込める発言はまだありません。", color: Washi.muted)
    private(set) var checkboxes: [TranscriptFilterChoice] = []
    private var items: [Item] = []
    var isShown: Bool { popover.isShown }
    var contentView: NSView { popover.contentViewController!.view }
    private static let width: CGFloat = 280

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        content.appearance = NSAppearance(named: .aqua)
        Washi.surface(content, color: Washi.paper)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.widthAnchor.constraint(equalToConstant: Self.width - 32)
        ])
        stack.addArrangedSubview(Washi.label("表示する話者", size: 13, weight: .semibold))
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        stack.addArrangedSubview(list)
        stack.addArrangedSubview(emptyHint)
        let hint = NSTextField(wrappingLabelWithString: "表示だけを絞ります。保存・コピー・AIへ渡す会話は全体のままです。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = Washi.muted
        hint.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.addArrangedSubview(hint)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
    }

    func update(items: [Item], selected: Set<TranscriptFilter.Subject>) {
        if items.map(\.subject) != self.items.map(\.subject) {
            // 相手の顔ぶれが変わった時だけ作り直し、定期更新で焦点を奪わない。
            checkboxes.forEach { $0.removeFromSuperview() }
            checkboxes = items.enumerated().map { index, item in
                let choice = TranscriptFilterChoice(subject: item.subject, width: Self.width - 32)
                choice.button.tag = index
                choice.button.target = self; choice.button.action = #selector(toggled(_:))
                list.addArrangedSubview(choice)
                return choice
            }
        }
        self.items = items
        for (item, choice) in zip(items, checkboxes) {
            choice.update(title: item.title, checked: selected.contains(item.subject))
            item.configureAvatar(choice.avatar)
            choice.avatar.needsDisplay = true
        }
        list.isHidden = items.isEmpty
        emptyHint.isHidden = !items.isEmpty
        resize()
    }
    func present(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
    func close() { popover.close() }
    private func resize() {
        contentView.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: ceil(stack.fittingSize.height) + 32)
        popover.contentSize = size
        contentView.setFrameSize(size)
        contentView.layoutSubtreeIfNeeded()
    }
    @objc private func toggled(_ sender: NSButton) {
        guard checkboxes.indices.contains(sender.tag) else { return }
        onToggle?(checkboxes[sender.tag].subject, sender.state == .on)
    }
}

/// ポップオーバーの1行。チェックボックス・行と同じアバター・名前を並べる。
/// アバターと名前を押しても、標準のチェックボックスの文字と同じく切り替わる。
/// カーソルは他の画面のチェックボックスに合わせて変えない。
final class TranscriptFilterChoice: NSStackView {
    let subject: TranscriptFilter.Subject
    let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let avatar = AvatarView()
    let label = Washi.label(size: 13)

    init(subject: TranscriptFilter.Subject, width: CGFloat) {
        self.subject = subject
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 6
        avatar.widthAnchor.constraint(equalToConstant: 20).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 20).isActive = true
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [button, avatar, label] { addArrangedSubview(view) }
        setCustomSpacing(4, after: button)
        widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        for view in [avatar, label] {
            view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var title: String { label.stringValue }
    func update(title: String, checked: Bool) {
        label.stringValue = title
        label.toolTip = title
        button.setAccessibilityLabel(title)
        button.state = checked ? .on : .off
    }
    @objc private func clicked() { button.performClick(nil) }
}
