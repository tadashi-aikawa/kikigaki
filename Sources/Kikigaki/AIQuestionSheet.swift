import AppKit
import KikigakiCore

/// 文面とは別に、送信の末尾へ毎回付く指示を知らせる。操作部の文字は固定サイズ。
@MainActor
final class AIAlwaysPromptHint: NSView {
    let label = Washi.label("＋ 毎回付く指示あり", size: 11, color: Washi.muted)
    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update("")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ prompt: String) {
        isHidden = prompt.isEmpty
        toolTip = prompt.isEmpty ? nil : prompt
        label.toolTip = toolTip
        label.setAccessibilityHelp(toolTip)
    }
}

/// シート共通の窓。Escで閉じ、Enterはプロンプト編集中だけ改行へ回す。
/// 開始シート(`StartSheetWindow`)がここへ⌘⏎の開始を足すため、継承できるようにしてある。
class AIQuestionWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        // accessoryアプリは、シートが見えていても別のアプリが前面のことがある。
        // 標準ツールチップは既定でその間出ない。開始・手動・自動のシートだけ許可する。
        allowsToolTipsWhenApplicationIsInactive = true
    }
    var onDismiss: (() -> Void)?
    private var outsideMonitor: Any?
    var monitorsOutsideClicks: Bool { outsideMonitor != nil }
    deinit { if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) } }

    /// シートの背後へのクリックは親の停止ボタン等へ流さず、閉じる操作だけに使う。
    func monitorOutsideClicks() {
        stopMonitoringOutsideClicks()
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleOutsideClick(event)
        }
    }
    func handleOutsideClick(_ event: NSEvent) -> NSEvent? {
        guard monitorsOutsideClicks, attachedSheet == nil,
              let parent = sheetParent, parent.attachedSheet === self,
              event.window === parent, let onDismiss else { return event }
        let screenPoint = parent.convertPoint(toScreen: event.locationInWindow)
        guard !frame.contains(screenPoint) else { return event }
        onDismiss()
        return nil
    }
    private func stopMonitoringOutsideClicks() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
    }
    override func orderOut(_ sender: Any?) {
        stopMonitoringOutsideClicks()
        super.orderOut(sender)
    }
    override func cancelOperation(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            editor.inputContext?.discardMarkedText(); editor.unmarkText()
        } else if let onDismiss { onDismiss() }
        else { super.cancelOperation(sender) }
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, onDismiss != nil,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            cancelOperation(nil); return
        }
        if event.type == .keyDown, let editor = firstResponder as? AIQuestionEditor,
           (event.keyCode == 36 || event.keyCode == 76) ||
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
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if modifiers == .command {
                if isEditable { onSubmit?() }
                return
            }
            if modifiers.isEmpty || modifiers == .shift {
                if isEditable { insertNewline(nil) }
                return
            }
        }
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
    var onDestination: ((Int) -> Void)?
    private let destination = AIDestinationPicker()
    private let title = Washi.label("", size: 17, weight: .semibold)
    private let editor = AIQuestionEditor()
    let alwaysPromptHint = AIAlwaysPromptHint()
    let sendButton = NSButton(title: "送信", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let range = Washi.label(size: 11, color: Washi.muted)
    private let full = NSButton(checkboxWithTitle: "会話を最初から送り直す", target: nil, action: nil)
    private let work = NSButton(checkboxWithTitle: "作業を許可する(ファイル編集・コマンド実行)", target: nil, action: nil)
    private let pane = NSButton(title: "ペインを開く", target: nil, action: nil)
    var onPane: (() -> Void)?
    var rangePreview: ((Bool) -> String)?
    private var sent = false

    /// 宛先を選ばせないシートの枠。確認への返答と失敗の再送が使う。
    /// 選択欄を隠すだけでは `owningSlot` が選択値を見るので、取消の宛先が動く。
    private let fixedSlot: Int?

    init(participant: String, parentNumber: Int?, draft: String, voice: String, range: String, tentative: Bool, canSubmit: Bool, confirmation: String? = nil, workAllowed: Bool = true, fixedSlot: Int? = nil, alwaysPrompt: String = "") {
        self.fixedSlot = fixedSlot
        window = AIQuestionWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 370), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = Washi.paper
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        title.stringValue = parentNumber.map { "#\($0)への返答" } ?? "\(participant)へ"
        destination.onChange = { [weak self] in self?.onDestination?($0) }
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
        sendButton.keyEquivalent = "\r"; sendButton.keyEquivalentModifierMask = .command
        sendButton.isEnabled = canSubmit
        let cancel = NSButton(title: "閉じる", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        pane.isBordered = false; pane.target = self; pane.action = #selector(openPane)
        let actions = NSStackView(views: [pane, NSView(), cancel, sendButton]); actions.orientation = .horizontal; actions.spacing = 12
        // 確認への返答と再送は元質問と同じ宛先へ送る。宛先を選び直させない。
        destination.isHidden = fixedSlot != nil
        var views: [NSView] = [title]
        if fixedSlot == nil { views.append(destination) }
        views.append(self.range)
        if let confirmation {
            let context = NSTextField(wrappingLabelWithString: "? " + confirmation)
            context.font = .systemFont(ofSize: 12); context.textColor = Washi.ink
            context.maximumNumberOfLines = 3; context.toolTip = confirmation
            views.append(context)
            window.setContentSize(NSSize(width: 504, height: 420))
        }
        alwaysPromptHint.update(alwaysPrompt)
        views += [scroll, alwaysPromptHint, Washi.label("⌘Enterで送信 · Enterで改行", size: 11, color: Washi.muted), hint, full, work, actions]
        for view in views {
            stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        editor.onSubmit = { [weak self] in self?.submit() }; editor.onCancel = { [weak self] in self?.cancel() }
        (window as? AIQuestionWindow)?.onDismiss = { [weak self] in self?.cancel() }
    }
    /// このシートが送信を始めた枠。取消はここへ返す。
    /// 送信後に宛先を選び直せると、接続待ちの依頼を取り消せなくなる。
    private(set) var activeSlot: Int?
    /// 固定した枠があればそれ、送信を始めていなければ現在の選択、始めていればそのときの枠
    var owningSlot: Int { fixedSlot ?? activeSlot ?? destination.selected }
    var permitsAppendix: Bool { fixedSlot == nil }

    /// 宛先の一覧と選択を差し替える。固定した枠と送信を始めた後は差し替えない。
    func updateDestinations(_ items: [AIDestinationPicker.Item], selected: Int, participant: String) {
        guard activeSlot == nil, fixedSlot == nil else { return }
        destination.update(items: items, selected: selected)
        title.stringValue = "\(participant)へ"
    }

    func present(on parent: NSWindow) {
        parent.beginSheet(window); window.makeFirstResponder(editor)
        (window as? AIQuestionWindow)?.monitorOutsideClicks()
    }
    var draft: String { editor.string }
    func updateAlwaysPrompt(_ prompt: String) { alwaysPromptHint.update(prompt) }
    func restoreDraft(_ text: String) {
        editor.unmarkText()
        editor.string = text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        editor.needsDisplay = true
    }
    func close() { if let parent = window.sheetParent { parent.endSheet(window) }; window.orderOut(nil) }
    func update(progress: String?, canSubmit: Bool, warning: String? = nil, appending: Bool = false, workAllowed: Bool? = nil) {
        sendButton.title = appending ? "追記して送る" : "送信"
        full.isEnabled = !appending; work.isEnabled = !appending
        if appending { full.state = .off }
        if let workAllowed { work.state = workAllowed ? .on : .off }
        if progress == nil { updateRange() }
        hint.stringValue = progress ?? warning ?? (appending ? "前回送った所から後の会話と文面を追記します。作業許可は元の依頼を引き継ぎます" : canSubmit ? "空欄なら声の末尾を送ります" : "送信できません。下書きは保持されます")
        sendButton.isEnabled = canSubmit && !sent
        editor.isEditable = !sent || progress == nil
        work.isEnabled = !appending && (!sent || progress == nil)
        if progress == nil {
            sent = false; sendButton.isEnabled = canSubmit
            // 送信が終わって次の下書きへ戻ったら、宛先をまた選べるようにする。
            activeSlot = nil; destination.setEnabled(true)
        }
    }
    func textDidChange(_ notification: Notification) { editor.needsDisplay = true; onDraft?(editor.string) }
    @objc private func updateRange() { if let rangePreview { range.stringValue = rangePreview(full.state == .on) } }
    @objc private func workChanged() { onWorkAllowedChange?(work.state == .on) }
    @objc private func submit() {
        guard sendButton.isEnabled, !editor.hasMarkedText() else { return }
        sent = true; sendButton.isEnabled = false; editor.isEditable = false; work.isEnabled = false
        // 送信を始めた枠を固定し、宛先も操作させない。取消の宛先が動くと元の依頼が残る。
        activeSlot = destination.selected
        destination.setEnabled(false)
        onSubmit?(editor.string, full.state == .on)
    }
    @objc private func cancel() { onCancel?(); close() }
    @objc private func openPane() { onPane?() }
}
