import AppKit

final class AIQuestionWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let editor = firstResponder as? AIQuestionEditor,
           (event.keyCode == 36 && (editor.hasMarkedText() || event.modifierFlags.contains(.shift))) ||
           (event.keyCode == 53 && editor.hasMarkedText()) {
            editor.keyDown(with: event); return
        }
        super.sendEvent(event)
    }
}

final class AIQuestionEditor: NSTextView {
    var placeholder = ""
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(in: bounds.insetBy(dx: 11, dy: 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: Washi.muted])
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, !hasMarkedText(), !event.modifierFlags.contains(.shift) { onSubmit?(); return }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { inputContext?.discardMarkedText(); unmarkText() }
        else { onCancel?() }
    }
}

@MainActor
final class AIQuestionSheet: NSObject, NSTextViewDelegate {
    let window: NSWindow
    var onSubmit: ((String, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onDraft: ((String) -> Void)?
    var onWorkAllowedChange: ((Bool) -> Void)?
    private let editor = AIQuestionEditor()
    private let sendButton = NSButton(title: "送信 ⏎", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let range = Washi.label(size: 11, color: Washi.muted)
    private let full = NSButton(checkboxWithTitle: "会話を最初から送り直す", target: nil, action: nil)
    private let work = NSButton(checkboxWithTitle: "作業を許可する(ファイル編集・コマンド実行)", target: nil, action: nil)
    private let pane = NSButton(title: "ペインを開く", target: nil, action: nil)
    var onPane: (() -> Void)?
    var rangePreview: ((Bool) -> String)?
    private var sent = false

    init(participant: String, parentNumber: Int?, draft: String, voice: String, range: String, tentative: Bool, canSubmit: Bool, confirmation: String? = nil, workAllowed: Bool = true) {
        window = AIQuestionWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 344), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = Washi.paper
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let title = Washi.label(parentNumber.map { "#\($0)への返答" } ?? "\(participant)へ", size: 17, weight: .semibold)
        self.range.stringValue = range
        full.target = self; full.action = #selector(updateRange)
        work.state = workAllowed ? .on : .off
        work.target = self; work.action = #selector(workChanged)
        editor.placeholder = voice; editor.string = draft; editor.font = .systemFont(ofSize: 14)
        editor.textColor = Washi.ink; editor.backgroundColor = Washi.paper; editor.isRichText = false
        editor.textContainerInset = NSSize(width: 6, height: 8); editor.delegate = self
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder; scroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
        editor.frame = NSRect(x: 0, y: 0, width: 460, height: 86)
        hint.font = .systemFont(ofSize: 11); hint.textColor = Washi.tentative
        hint.stringValue = canSubmit ? (tentative ? "空欄なら声の末尾を送ります。聞き取り中の末尾は最大3秒待ちます" : "空欄なら声の末尾を送ります") : "返事待ちです。下書きは保持されます"
        sendButton.bezelStyle = .rounded; sendButton.target = self; sendButton.action = #selector(submit)
        sendButton.keyEquivalent = "\r"
        sendButton.isEnabled = canSubmit
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        pane.isBordered = false; pane.target = self; pane.action = #selector(openPane)
        let actions = NSStackView(views: [pane, NSView(), cancel, sendButton]); actions.orientation = .horizontal; actions.spacing = 12
        var views: [NSView] = [title, self.range]
        if let confirmation {
            let context = NSTextField(wrappingLabelWithString: "? " + confirmation)
            context.font = .systemFont(ofSize: 12); context.textColor = Washi.ink
            context.maximumNumberOfLines = 3; context.toolTip = confirmation
            views.append(context)
            window.setContentSize(NSSize(width: 504, height: 394))
        }
        views += [scroll, hint, full, work, actions]
        for view in views {
            stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        editor.onSubmit = { [weak self] in self?.submit() }; editor.onCancel = { [weak self] in self?.cancel() }
    }
    func present(on parent: NSWindow) { parent.beginSheet(window); window.makeFirstResponder(editor) }
    func close() { if let parent = window.sheetParent { parent.endSheet(window) }; window.orderOut(nil) }
    func update(progress: String?, canSubmit: Bool, warning: String? = nil) {
        if progress == nil { updateRange() }
        hint.stringValue = progress ?? warning ?? (canSubmit ? "空欄なら声の末尾を送ります" : "返事待ちです。下書きは保持されます")
        sendButton.isEnabled = canSubmit && !sent
        editor.isEditable = !sent || progress == nil
        work.isEnabled = !sent || progress == nil
        if progress == nil { sent = false; sendButton.isEnabled = canSubmit }
    }
    func textDidChange(_ notification: Notification) { editor.needsDisplay = true; onDraft?(editor.string) }
    @objc private func updateRange() { if let rangePreview { range.stringValue = rangePreview(full.state == .on) } }
    @objc private func workChanged() { onWorkAllowedChange?(work.state == .on) }
    @objc private func submit() {
        guard sendButton.isEnabled, !editor.hasMarkedText() else { return }
        sent = true; sendButton.isEnabled = false; editor.isEditable = false; work.isEnabled = false
        onSubmit?(editor.string, full.state == .on)
    }
    @objc private func cancel() { onCancel?(); close() }
    @objc private func openPane() { onPane?() }
}
