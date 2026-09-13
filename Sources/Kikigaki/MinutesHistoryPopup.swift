import AppKit

/// field editorに焦点を残す一覧。クリックもキー操作もパス欄の確定へ戻す。
@MainActor final class MinutesHistoryPopup: NSView {
    override var isFlipped: Bool { true }
    private let scroll = NSScrollView()
    private let list = FlippedList()
    private(set) var rows: [MinutesHistoryRow] = []
    private(set) var selectedIndex: Int?
    var onChoose: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var selectedPath: String? { selectedIndex.map { rows[$0].path } }
    var desiredHeight: CGFloat { rows.reduce(8) { $0 + $1.rowHeight } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        Washi.surface(self, color: Washi.paper)
        layer?.cornerRadius = 6; layer?.borderWidth = 1; layer?.borderColor = Washi.rule.cgColor
        let dropShadow = NSShadow()
        dropShadow.shadowBlurRadius = 12
        dropShadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow = dropShadow
        layer?.masksToBounds = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = list; addSubview(scroll)
        setAccessibilityElement(true); setAccessibilityRole(.list)
        setAccessibilityLabel("最近表示した議事録")
    }
    required init?(coder: NSCoder) { fatalError() }
    func setPaths(_ paths: [String]) {
        rows.forEach { $0.removeFromSuperview() }; selectedIndex = nil
        rows = paths.enumerated().map { index, path in
            let parent = (path as NSString).deletingLastPathComponent
            let showDirectory = index == 0 || parent != (paths[index - 1] as NSString).deletingLastPathComponent
            let row = MinutesHistoryRow(path: path, showDirectory: showDirectory)
            row.onChoose = { [weak self] in self?.onChoose?(path) }
            list.addSubview(row)
            return row
        }
        needsLayout = true
        if !rows.isEmpty { select(0) }
    }
    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = selectedIndex.map { min(rows.count - 1, max(0, $0 + delta)) } ?? (delta > 0 ? 0 : rows.count - 1)
        select(next)
    }
    private func select(_ index: Int) {
        selectedIndex = index
        for (position, row) in rows.enumerated() { row.selected = position == index }
        rows[index].scrollToVisible(rows[index].bounds)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        NSAccessibility.post(element: window ?? self, notification: .announcementRequested,
            userInfo: [.announcement: rows[index].announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func clearSelection() {
        selectedIndex = nil; rows.forEach { $0.selected = false }
    }
    override func accessibilityChildren() -> [Any]? { rows }
    override func accessibilitySelectedChildren() -> [Any]? { selectedIndex.map { [rows[$0]] } ?? [] }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // 行のクリックだけをボタンへ渡し、枠・余白・スクロール領域の空白は閉じる操作にする。
        if hit is MinutesHistoryRow || hit is NSScroller { return hit }
        return self
    }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func layout() {
        super.layout()
        // 非表示の初期boundsはゼロ。insetByはこのとき無限大の原点を返すため、寸法を明示する。
        scroll.frame = NSRect(x: 4, y: 4, width: max(0, bounds.width - 8), height: max(0, bounds.height - 8))
        let width = scroll.contentSize.width
        list.frame = NSRect(x: 0, y: 0, width: width, height: desiredHeight - 8)
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: row.rowHeight)
            y += row.rowHeight
        }
    }
    private final class FlippedList: NSView { override var isFlipped: Bool { true } }
}

@MainActor final class MinutesHistoryRow: NSButton {
    let path: String
    let exists: Bool
    let filename: NSTextField
    let directory: NSTextField
    let missingLabel = Washi.label("見つかりません", size: 11, color: Washi.muted)
    var rowHeight: CGFloat { directory.isHidden ? 28 : 44 }
    var announcement: String { filename.stringValue + (exists ? "" : "、見つかりません") }
    var onChoose: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    init(path: String, showDirectory: Bool = true) {
        self.path = path
        exists = FileManager.default.fileExists(atPath: path)
        filename = Washi.label((path as NSString).lastPathComponent, size: 12, color: Washi.ink)
        directory = Washi.label((path as NSString).deletingLastPathComponent, size: 11, color: Washi.muted)
        super.init(frame: .zero)
        title = ""; isBordered = false; toolTip = path
        filename.lineBreakMode = .byTruncatingTail; directory.lineBreakMode = .byTruncatingHead
        directory.isHidden = !showDirectory; missingLabel.isHidden = exists
        addSubview(filename); addSubview(directory); addSubview(missingLabel)
        target = self; action = #selector(choose)
        setAccessibilityLabel(path + (exists ? "" : "、ファイルが見つかりません"))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func choose() { onChoose?() }
    override func accessibilityPerformPress() -> Bool { onChoose?(); return true }
    override func isAccessibilitySelected() -> Bool { selected }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering || isHighlighted {
            Washi.shade.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }
    override func layout() {
        super.layout()
        let noteWidth: CGFloat = exists ? 0 : ceil(missingLabel.intrinsicContentSize.width)
        filename.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 20 - (exists ? 0 : noteWidth + 8)), height: 17)
        missingLabel.frame = NSRect(x: max(10, bounds.width - 10 - noteWidth), y: 5, width: noteWidth, height: 17)
        directory.frame = NSRect(x: 10, y: 23, width: max(0, bounds.width - 20), height: 16)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
