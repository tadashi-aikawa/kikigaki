import AppKit
import UniformTypeIdentifiers
import KikigakiCore

/// 背景で構築を終えた後は変更しない。表示中のTextKitオブジェクトは背景へ渡さない。
private struct MinutesRenderedBody: @unchecked Sendable {
    let value: NSAttributedString
}

/// 本文と表を同じ行長へ制限し、余った紙面は右側に残す。
private final class MinutesTextView: NSTextView {
    // 上部バーの高さ変更でclip viewが文書原点を移しても、本文の先頭は常に0に置く。
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(.zero) }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        super.setFrameOrigin(.zero)
        textContainer?.containerSize = NSSize(width: min(720, max(1, newSize.width - 48)), height: .greatestFiniteMagnitude)
    }
}

private final class MinutesPathCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect).insetBy(dx: 6, dy: 0)
        let height = min(result.height, ceil((font?.ascender ?? 10) - (font?.descender ?? -3)) + 2)
        result.origin.y += (result.height - height) / 2; result.size.height = height
        return result
    }
}

private final class MinutesPathField: NSTextField {
    var focused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        Washi.paper.setFill(); bounds.fill()
        super.draw(dirtyRect)
        (focused ? Washi.ink : Washi.rule).setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        outline.lineWidth = 1; outline.stroke()
    }
}

/// パス編集と本文閲読を分離する。通知が来てもfield editorのドラフトは変更しない。
@MainActor final class MinutesPreviewView: NSView, NSTextFieldDelegate {
    let pathField: NSTextField = MinutesPathField(string: "")
    let headerBar = NSView()
    let textView: NSTextView
    let scroll = NSScrollView()
    let message = NSTextField(wrappingLabelWithString: "")
    let notice = NSTextField(wrappingLabelWithString: "")
    private let retryButton = HoverButton(title: "再読込", target: nil, action: nil)
    private let cancelButton = HoverButton(title: "読込を取り消す", target: nil, action: nil)
    private let emptyChoose = HoverButton(title: "ファイルを選ぶ…", target: nil, action: nil)
    var onSelect: ((String?) throws -> Void)?
    var onClose: (() -> Void)?
    private var path: String?
    private var source: MinutesState.Source?
    private var editing = false
    private var commitError: String?
    private var contextGeneration = 0
    private var active = false
    private var monitor: MinutesFileMonitor?
    private var body: String?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private(set) var lastRenderMainMilliseconds: Double = 0

    override init(frame: NSRect) {
        let storage = NSTextStorage(), manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = true
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        textView = MinutesTextView(frame: .zero, textContainer: container)
        super.init(frame: frame)
        Washi.surface(self, color: Washi.paper)
        pathField.cell = MinutesPathCell(textCell: "")
        pathField.isEditable = true; pathField.isSelectable = true
        pathField.cell?.isScrollable = true
        pathField.placeholderString = "議事録の絶対パス"
        pathField.font = .systemFont(ofSize: 12)
        pathField.isBezeled = false; pathField.isBordered = false; pathField.drawsBackground = false
        pathField.focusRingType = .none; pathField.textColor = Washi.ink
        pathField.delegate = self
        pathField.target = self; pathField.action = #selector(commitPath)
        pathField.setAccessibilityLabel("議事録のパス")
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = HoverButton(title: "ファイルを選ぶ…", target: self, action: #selector(chooseFile))
        let close = HoverButton(title: "", target: self, action: #selector(closePreview))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "議事録を隠す")
        close.toolTip = "議事録を隠す"; close.setAccessibilityLabel("議事録を隠す")
        let top = row([pathField, choose, close], spacing: 8)
        headerBar.addSubview(top); top.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            top.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 12),
            top.heightAnchor.constraint(equalToConstant: 32),
            pathField.heightAnchor.constraint(equalToConstant: 24)
        ])
        notice.font = .systemFont(ofSize: 11); notice.textColor = Washi.muted; notice.isHidden = true
        Washi.surface(headerBar)
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 24, height: 24)
        container.widthTracksTextView = false; container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        textView.setAccessibilityLabel("議事録")
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        message.font = .systemFont(ofSize: 14); message.textColor = Washi.muted; message.alignment = .center
        message.setAccessibilityLabel("議事録の状態")
        retryButton.target = self; retryButton.action = #selector(reload)
        cancelButton.target = self; cancelButton.action = #selector(cancelRead)
        emptyChoose.target = self; emptyChoose.action = #selector(chooseFile)
        let status = NSStackView(views: [message, emptyChoose, retryButton, cancelButton])
        status.orientation = .vertical; status.alignment = .centerX; status.spacing = 16
        status.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        message.widthAnchor.constraint(equalTo: status.widthAnchor, constant: -48).isActive = true
        let bodyView = NSView()
        bodyView.addSubview(scroll); bodyView.addSubview(status)
        for view in [scroll, status] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bodyView.topAnchor), scroll.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            status.centerXAnchor.constraint(equalTo: bodyView.centerXAnchor),
            status.widthAnchor.constraint(equalTo: bodyView.widthAnchor, constant: -48),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: bodyView.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(lessThanOrEqualTo: bodyView.trailingAnchor, constant: -20)
        ])
        // 案内の先頭を上から1/3へ。本文スクロールとは独立させる。
        let guide = NSLayoutGuide(); bodyView.addLayoutGuide(guide)
        guide.topAnchor.constraint(equalTo: bodyView.topAnchor).isActive = true
        guide.heightAnchor.constraint(equalTo: bodyView.heightAnchor, multiplier: 0.28).isActive = true
        status.topAnchor.constraint(equalTo: guide.bottomAnchor).isActive = true
        let bodyColumn = column([notice, bodyView], spacing: 0, inset: 0)
        let layout = column([headerBar, separator(), bodyColumn], spacing: 0, inset: 0)
        addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor), layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor), layout.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        showMessage("議事録のファイルを指定するか、AIに書かせると表示します")
    }
    required init?(coder: NSCoder) { fatalError() }
    func resetContext() {
        stop(); path = nil; body = nil; editing = false; commitError = nil; contextGeneration += 1
        window?.makeFirstResponder(nil)
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        scroll.contentView.scroll(to: .zero)
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat, inset: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true }
        return stack
    }
    private func separator() -> NSView {
        let line = NSView(); Washi.surface(line, color: Washi.rule); line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    func update(path: String?, source: MinutesState.Source?, active: Bool, warning: String? = nil) {
        let changed = self.path != path
        let start = active && (!self.active || changed || self.source != source)
        self.path = path; self.source = source; self.active = active
        if editing || pathField.currentEditor() != nil {
            if changed { notice.stringValue = "表示対象が変わりました。編集中のパスは保持しています"; notice.isHidden = false }
        } else { pathField.stringValue = path ?? ""; pathField.toolTip = path; notice.isHidden = warning == nil; notice.stringValue = warning ?? "" }
        if let commitError { notice.stringValue = commitError; notice.isHidden = false }
        if !active { cancelRender(); monitor?.stop(); monitor = nil; return }
        if start { beginRead(reset: changed) }
    }

    private func beginRead(reset: Bool) {
        cancelRender()
        monitor?.stop(); monitor = nil
        if reset { body = nil; textView.textStorage?.setAttributedString(NSAttributedString(string: "")); scroll.contentView.scroll(to: .zero) }
        guard let path else { showMessage("議事録のファイルを指定するか、AIに書かせると表示します"); return }
        showMessage("読み込んでいます…", cancel: true)
        monitor = MinutesFileMonitor(path: path) { [weak self] result in self?.receive(result) }
    }

    func receive(_ result: MinutesFileResult) {
        switch result {
        case .body(let source, let blocks):
            if blocks.isEmpty { cancelRender(); body = source; showMessage("議事録はまだ空です"); return }
            guard body != source else { cancelRender(); showBody(); return }
            cancelRender()
            let generation = renderGeneration
            renderTask = Task { [weak self] in
                let rendered = await Task.detached(priority: .utility) {
                    MinutesRenderedBody(value: MarkdownBodyRenderer.render(blocks))
                }.value
                guard !Task.isCancelled, let self, self.renderGeneration == generation else { return }
                self.install(rendered.value, source: source)
            }
        case .missing: cancelRender(); showMessage(source == .ai ? "AIが通知したファイルはまだありません。作成されると自動で表示します" : "指定したファイルはまだありません。作成されると自動で表示します", retry: true)
        case .cloud: cancelRender(); showMessage("iCloudからのダウンロードを待っています…", cancel: true)
        case .failure(let reason): cancelRender(); showMessage(reason, retry: true)
        case .changed: break
        }
    }

    private func install(_ rendered: NSAttributedString, source: String) {
            let started = Date()
            defer { lastRenderMainMilliseconds = Date().timeIntervalSince(started) * 1000 }
            showBody()
            body = source
            let selection = textView.selectedRange(), oldY = scroll.contentView.bounds.minY
            let manager = textView.layoutManager!, container = textView.textContainer!
            let visible = NSRect(x: 0, y: max(0, oldY - textView.textContainerInset.height), width: container.containerSize.width, height: scroll.contentSize.height)
            manager.ensureLayout(forBoundingRect: visible, in: container)
            let point = NSPoint(x: 0, y: max(0, oldY - textView.textContainerInset.height))
            let glyph = manager.glyphIndex(for: point, in: container)
            let character = glyph < manager.numberOfGlyphs ? manager.characterIndexForGlyph(at: glyph) : 0
            let offset = glyph < manager.numberOfGlyphs ? manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY - oldY : 0
            textView.textStorage?.setAttributedString(rendered)
            manager.ensureLayout(forBoundingRect: visible, in: container)
            let count = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location))))
            var y: CGFloat = 0
            if count > 0, oldY > 0 {
                let anchor = manager.glyphIndexForCharacter(at: min(character, count - 1))
                y = manager.lineFragmentRect(forGlyphAt: anchor, effectiveRange: nil).minY - offset
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, textView.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func cancelRender() { renderGeneration += 1; renderTask?.cancel(); renderTask = nil }
    private func showBody() {
        message.isHidden = true; emptyChoose.isHidden = true; retryButton.isHidden = true; cancelButton.isHidden = true; scroll.isHidden = false
    }

    private func showMessage(_ value: String, retry: Bool = false, cancel: Bool = false) {
        message.stringValue = value; message.isHidden = false; scroll.isHidden = true
        emptyChoose.isHidden = path != nil
        retryButton.isHidden = !retry; cancelButton.isHidden = !cancel
    }
    func controlTextDidBeginEditing(_ obj: Notification) { editing = true; (pathField as? MinutesPathField)?.focused = true }
    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false; pathField.stringValue = path ?? ""; notice.isHidden = commitError == nil
        (pathField as? MinutesPathField)?.focused = false
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitPath(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editing = false; commitError = nil; window?.makeFirstResponder(nil); pathField.stringValue = path ?? ""; notice.isHidden = true
            (pathField as? MinutesPathField)?.focused = false
            return true
        }
        return false
    }
    @objc func commitPath() {
        do {
            let input = pathField.stringValue
            let path: String? = input.isEmpty ? nil : (input as NSString).expandingTildeInPath
            if let path, !path.hasPrefix("/") { throw AIError.invalid("absolute path") }
            let normalized = path.map { value in
                var parts: [Substring] = []
                for part in value.split(separator: "/") {
                    if part == "." { continue }
                    if part == ".." { if !parts.isEmpty { parts.removeLast() } }
                    else { parts.append(part) }
                }
                return "/" + parts.joined(separator: "/")
            }
            if let normalized { try MinutesPath.validate(normalized) }
            try onSelect?(normalized)
            editing = false; commitError = nil; window?.makeFirstResponder(nil)
            (pathField as? MinutesPathField)?.focused = false
            pathField.stringValue = self.path ?? normalized ?? ""; notice.isHidden = true
        } catch { commitError = "パスを保存できません。絶対パスの.mdファイルを指定してください"; notice.stringValue = commitError!; notice.isHidden = false }
    }
    @objc private func chooseFile() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let generation = contextGeneration
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, self.contextGeneration == generation, let url = panel.url else { return }
            self.pathField.stringValue = url.path; self.commitPath()
        }
    }
    @objc private func closePreview() { onClose?() }
    @objc private func reload() { beginRead(reset: false) }
    @objc private func cancelRead() { cancelRender(); monitor?.stop(); monitor = nil; showMessage("読み込みを取り消しました", retry: true) }
    func stop() { cancelRender(); active = false; monitor?.stop(); monitor = nil }
}
