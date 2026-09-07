import AppKit

/// EnterをIMEへ渡すか投稿するかを、変換確定より前の状態で決める。
final class TypedEntryEditor: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var placeholder = "録音中に書き込めます"
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 13, y: 6), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: Washi.muted])
        }
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if isEditable && modifiers == .command { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }
    // 投稿は未確定文字のない⌘EnterのkeyDownだけ。IME確定後の改行命令も消費する。
    override func insertNewline(_ sender: Any?) {}
    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    override func paste(_ sender: Any?) {
        _ = readSelection(from: .general, type: .string)
    }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable, let text = pboard.string(forType: .string) else { return false }
        insertText(text, replacementRange: selectedRange())
        return true
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        // IMEの未確定領域には触らない。確定入力と貼り付けだけ改行を空白へ畳む。
        let line = text.replacingOccurrences(of: "\r\n", with: " ").components(separatedBy: .newlines).joined(separator: " ")
        super.insertText(line, replacementRange: replacementRange)
        needsDisplay = true
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else { window?.makeFirstResponder(nil) }
    }
}

private final class TypedEntryOutline: NSView {
    var color = Washi.rule.withAlphaComponent(0.4) { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        // 横スクロールしても紙の余白と枠は動かさない。cacheDisplayでも同じ枠を描く。
        Washi.paper.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        NSRect(x: bounds.width - 2, y: 0, width: 2, height: bounds.height).fill()
        color.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.lineWidth = 1
        path.stroke()
    }
}

final class TypedEntryField: NSScrollView, NSTextViewDelegate {
    let editor = TypedEntryEditor(frame: NSRect(x: 0, y: 0, width: 540, height: 32))
    var onSubmit: ((String) -> Bool)?
    private let draftLabel = NSTextField(labelWithString: "未投稿")
    private let outline = TypedEntryOutline()
    override init(frame: NSRect) {
        super.init(frame: frame)
        borderType = .noBorder
        wantsLayer = true
        layer?.cornerRadius = 5
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        backgroundColor = Washi.paper
        drawsBackground = true
        hasVerticalScroller = false; hasHorizontalScroller = false
        editor.font = .systemFont(ofSize: 14); editor.textColor = Washi.ink
        editor.backgroundColor = Washi.paper; editor.insertionPointColor = Washi.ink
        editor.isRichText = false; editor.importsGraphics = false
        editor.isEditable = false; editor.isSelectable = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = false
        editor.autoresizingMask = [.height]
        editor.minSize = NSSize(width: 0, height: 32)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 32)
        editor.textContainerInset = NSSize(width: 8, height: 6)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 32)
        editor.delegate = self
        editor.setAccessibilityLabel("会話に書き込む")
        editor.toolTip = "⌘Enterで投稿。録音中・一時停止中に使えます"
        editor.setAccessibilityHelp(editor.toolTip)
        editor.onSubmit = { [weak self] in
            guard let self, editor.isEditable, !editor.hasMarkedText(), onSubmit?(editor.string) == true else { return }
            reset()
        }
        documentView = editor
        draftLabel.font = .systemFont(ofSize: 11)
        draftLabel.textColor = Washi.muted
        draftLabel.backgroundColor = Washi.paper
        draftLabel.drawsBackground = true
        draftLabel.isHidden = true
        addSubview(draftLabel)
        addSubview(outline)
        editor.onFocusChange = { [weak self] in self?.updateBorder(focused: $0) }
        updateBorder()
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        // 短い入力でも空白部分までクリックを受け、長いURLだけ横へ伸びる。
        editor.minSize = NSSize(width: contentSize.width, height: 32)
        if editor.frame.width < contentSize.width { editor.setFrameSize(NSSize(width: contentSize.width, height: 32)) }
        draftLabel.frame = NSRect(x: max(0, bounds.width - 48), y: 9, width: 42, height: 16)
        outline.frame = bounds
    }
    func update(enabled: Bool, resetDraft: Bool) {
        if resetDraft { reset() }
        editor.isEditable = enabled
        editor.isSelectable = enabled
        editor.textColor = enabled ? Washi.ink : Washi.muted
        editor.backgroundColor = Washi.paper
        backgroundColor = editor.backgroundColor
        editor.toolTip = enabled ? "⌘Enterで投稿" : "録音中・一時停止中に会話へ投稿できます"
        editor.setAccessibilityHelp(editor.toolTip)
        editor.setAccessibilityEnabled(enabled)
        if !enabled, window?.firstResponder === editor { window?.makeFirstResponder(nil) }
        editor.placeholder = enabled ? "会話に書き込む… · ⌘Enterで投稿" : "録音中に書き込めます"
        draftLabel.isHidden = enabled || editor.string.isEmpty
        contentInsets.right = draftLabel.isHidden ? 2 : 50
        editor.needsDisplay = true
        updateBorder()
    }
    private func updateBorder(focused: Bool? = nil) {
        let color = !editor.isEditable ? Washi.rule.withAlphaComponent(0.4)
            : (focused ?? (window?.firstResponder === editor)) ? Washi.ink : Washi.rule
        outline.color = color
    }
    private func reset() {
        editor.unmarkText()
        editor.string = ""
        editor.undoManager?.removeAllActions(withTarget: editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        contentView.scroll(to: .zero)
        editor.needsDisplay = true
    }
    func textDidChange(_ notification: Notification) { editor.needsDisplay = true }
}
