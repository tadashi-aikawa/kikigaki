import AppKit
import KikigakiCore

@MainActor
final class AIScheduleSheet: NSObject, NSTextViewDelegate {
    let window: NSWindow
    var onStart: ((AIScheduleOptions) -> Void)?
    var onCancel: (() -> Void)?
    var onDraft: ((String) -> Void)?
    var onDestination: ((Int) -> Void)?
    /// 準備済みセッションを選んだ。呼び手が紐づけてから一覧を差し替える
    var onPrepared: ((Int, UUID) -> Void)?
    private let destination = AIDestinationPicker()
    private let title = Washi.label("", size: 17, weight: .semibold)
    private let editor = AIQuestionEditor()
    private let interval = NSPopUpButton()
    private let work = NSButton(checkboxWithTitle: "作業を許可する(ファイル編集・コマンド実行)", target: nil, action: nil)
    private let final = NSButton(checkboxWithTitle: "録音停止時に最後の1回を送る", target: nil, action: nil)
    private let startButton = NSButton(title: "開始", target: nil, action: nil)
    private let hint = Washi.label(size: 11, color: Washi.tentative)

    init(prompt: String, minutes: Int, workAllowed: Bool, sendFinal: Bool = true, participant: String = "迅雷") {
        window = AIQuestionWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = Washi.paper
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        title.stringValue = "\(participant)へ 自動送信"
        destination.onChange = { [weak self] in self?.onDestination?($0) }
        destination.onPrepared = { [weak self] slot, id in self?.onPrepared?(slot, id) }
        editor.placeholder = "毎回送る依頼を書いてください"
        editor.onSubmit = { [weak self] in self?.start() }
        editor.onCancel = { [weak self] in self?.cancel() }
        editor.string = prompt; editor.font = .systemFont(ofSize: 14); editor.textColor = Washi.ink
        editor.backgroundColor = Washi.paper; editor.isRichText = false; editor.delegate = self
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("毎回送るプロンプト")
        editor.frame = NSRect(x: 0, y: 0, width: 460, height: 100)
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        for minute in AIScheduleOptions.minuteChoices(including: minutes) {
            interval.addItem(withTitle: "\(minute)分"); interval.lastItem?.tag = minute
        }
        interval.selectItem(withTag: minutes); interval.setAccessibilityLabel("送信間隔")
        let frequency = NSStackView(views: [Washi.label("間隔", size: 13), interval]); frequency.spacing = 12
        work.state = workAllowed ? .on : .off; final.state = sendFinal ? .on : .off
        startButton.bezelStyle = .rounded; startButton.target = self; startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "閉じる", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancel, startButton]); actions.spacing = 12
        for view in [title, destination, scroll, Washi.label("⌘Enterで送信して開始 · Enterで改行", size: 11, color: Washi.muted), frequency, hint, work, final, actions] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        (window as? AIQuestionWindow)?.onDismiss = { [weak self] in self?.cancel() }
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    /// 準備済みを選んで紐づけている最中。確定するまで開始させない
    private var binding = false
    func setBinding(_ active: Bool) {
        binding = active
        destination.setEnabled(!active)
        if active { startButton.isEnabled = false; hint.stringValue = "準備済みのAIセッションへ紐づけています" }
        else { update() }
    }

    /// 宛先の一覧と選択を差し替える。
    func updateDestinations(_ items: [AIDestinationPicker.Item], selected: Int, participant: String) {
        destination.update(items: items, selected: selected)
        title.stringValue = "\(participant)へ 自動送信"
    }

    func present(on parent: NSWindow) {
        parent.beginSheet(window); window.makeFirstResponder(editor)
        (window as? AIQuestionWindow)?.monitorOutsideClicks()
    }
    func close() { if let parent = window.sheetParent { parent.endSheet(window) }; window.orderOut(nil) }
    func focus() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor) }
    func update(warning: String? = nil) {
        let invalid: String?
        if editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid = "毎回行ってほしい作業を入力してください" }
        else if editor.string.contains("\0") { invalid = "使用できない文字が含まれています" }
        else if editor.string.utf8.count > AILimits.questionBytes { invalid = "入力が長すぎます。32 KiB以内に短くしてください" }
        else { invalid = nil }
        startButton.isEnabled = invalid == nil && !binding
        hint.stringValue = warning ?? invalid ?? "指定間隔ごとに差分を送ります"
        hint.textColor = warning != nil || invalid != nil ? Washi.gold : Washi.tentative
    }
    func textDidChange(_ notification: Notification) {
        editor.needsDisplay = true; onDraft?(editor.string); update()
    }
    @objc private func start() {
        guard startButton.isEnabled, !editor.hasMarkedText(),
              let options = try? AIScheduleOptions(prompt: editor.string, interval: Double(interval.selectedTag()) * 60,
                                                  workAllowed: work.state == .on, sendFinal: final.state == .on) else { return }
        startButton.isEnabled = false
        onStart?(options)
    }
    @objc private func cancel() { close(); onCancel?() }
}
