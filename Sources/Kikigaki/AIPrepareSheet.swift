import AppKit
import KikigakiCore
import KikigakiAIIO

/// 会議に紐づかないAIセッションを起こすシート。下半分に未紐づけの一覧を置く。
/// 起こす操作と溜まっているものの確認は同じ関心なので、画面を分けない。
@MainActor
final class AIPrepareSheet: NSObject, NSTextFieldDelegate {
    struct Row {
        let id: UUID
        let label: String
        /// 準備してから設定か保存先が変わって使えない行。理由を添えて、破棄だけできる
        let reason: String?
        var stale: Bool { reason != nil }
        init(id: UUID, label: String, reason: String?) { self.id = id; self.label = label; self.reason = reason }
    }
    let window: NSWindow
    var onStart: ((Int, String?) -> Void)?
    var onCancel: (() -> Void)?
    var onPane: ((UUID?) -> Void)?
    var onDiscard: ((UUID) -> Void)?

    private let profile = NSPopUpButton()
    let nameField = NSTextField(string: "")
    private let nameHint = Washi.label("任意・64バイト以内", size: 11, color: Washi.muted)
    private var launching = false
    private let startButton = NSButton(title: "起動", target: nil, action: nil)
    private let hint = Washi.label(size: 12, color: Washi.muted)
    private let listTitle = Washi.label("準備済み", size: 12, weight: .semibold)
    private let list = NSStackView()
    private let separator = NSBox()

    init(profiles: [(slot: Int, name: String)], selected: Int) {
        window = AIQuestionWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 320),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = Washi.paper
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let title = Washi.label("AIセッションを準備", size: 17, weight: .semibold)
        for item in profiles { profile.addItem(withTitle: item.name); profile.lastItem?.representedObject = item.slot }
        profile.selectItem(at: profiles.firstIndex { $0.slot == selected } ?? 0)
        profile.setAccessibilityLabel("準備するプロファイル")
        let row = NSStackView(views: [Washi.label("プロファイル", size: 13), profile])
        row.orientation = .horizontal; row.spacing = 12; row.alignment = .centerY
        nameField.placeholderString = "例: 決定事項の確認役"
        nameField.usesSingleLineMode = true; nameField.delegate = self
        nameField.setAccessibilityLabel("準備セッションの名前")
        let nameRow = NSStackView(views: [Washi.label("名前", size: 13), nameField])
        nameRow.orientation = .horizontal; nameRow.spacing = 12
        hint.stringValue = "録音と結びつけずに起動します。次の録音を開始するときに、この準備済みセッションを選べます"
        hint.maximumNumberOfLines = 2
        startButton.bezelStyle = .rounded; startButton.target = self; startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "閉じる", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let pane = NSButton(title: "ペインを開く", target: self, action: #selector(openPane))
        pane.isBordered = false
        let actions = NSStackView(views: [pane, NSView(), cancel, startButton])
        actions.orientation = .horizontal; actions.spacing = 12
        separator.boxType = .separator
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        for view in [title, row, nameRow, nameHint, hint, actions, separator, listTitle, list] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        (window as? AIQuestionWindow)?.onDismiss = { [weak self] in self?.close() }
    }

    var selectedSlot: Int { profile.selectedItem?.representedObject as? Int ?? 1 }

    /// 未紐づけの一覧を差し替える。1件も無ければ見出しごと隠す。
    func update(rows: [Row], launching: Bool, warning: String? = nil) {
        listTitle.isHidden = rows.isEmpty && warning == nil
        separator.isHidden = listTitle.isHidden
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 警告があっても一覧は出す。起動に失敗しただけで、溜まっているものは使えるため。
        listTitle.stringValue = warning ?? "準備済み \(rows.count)件"
        listTitle.textColor = warning == nil ? Washi.ink : Washi.gold
        for row in rows { list.addArrangedSubview(entry(row)) }
        self.launching = launching
        updateNameValidity()
        nameField.isEnabled = !launching
        profile.isEnabled = !launching
        hint.stringValue = launching
            ? "起動しています。herdrのペインで初回の確認が要ることがあります"
            : "録音と結びつけずに起動します。次の録音を開始するときに、この準備済みセッションを選べます"
    }

    private func entry(_ row: Row) -> NSView {
        let label = Washi.label(row.label, size: 12, color: row.stale ? Washi.muted : Washi.ink)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [label]
        if let reason = row.reason {
            views.append(Washi.label(reason, size: 11, color: Washi.gold))
        }
        views.append(NSView())
        let pane = AIRowButton(title: "ペインを開く") { [weak self] in self?.onPane?(row.id) }
        let discard = AIRowButton(title: "破棄") { [weak self] in self?.onDiscard?(row.id) }
        views += [pane, discard]
        let line = NSStackView(views: views)
        line.orientation = .horizontal; line.spacing = 10; line.alignment = .centerY
        return line
    }

    func present(on parent: NSWindow) {
        parent.beginSheet(window)
        (window as? AIQuestionWindow)?.monitorOutsideClicks()
    }
    @objc func close() { if let parent = window.sheetParent { parent.endSheet(window) }; window.orderOut(nil); onCancel?() }
    func controlTextDidChange(_ notification: Notification) { updateNameValidity() }
    private func updateNameValidity() {
        let valid: Bool
        do { _ = try AIPreparedName.parse(nameField.stringValue); valid = true }
        catch { valid = false }
        startButton.isEnabled = !launching && valid
        nameHint.stringValue = valid ? "任意・64バイト以内" : "改行なし・64バイト以内で入力してください"
        nameHint.textColor = valid ? Washi.muted : Washi.gold
    }
    @objc private func start() {
        guard !launching else { return }
        do { onStart?(selectedSlot, try AIPreparedName.parse(nameField.stringValue)) }
        catch { updateNameValidity() }
    }
    @objc private func openPane() { onPane?(nil) }
}

/// 一覧の行に置く操作。枠を持たない文字のボタンで、無効時は色だけ抜ける。
final class AIRowButton: NSButton {
    private let callback: () -> Void
    init(title: String, action: @escaping () -> Void) {
        callback = action
        super.init(frame: .zero)
        self.title = title; isBordered = false
        font = .systemFont(ofSize: 11)
        contentTintColor = Washi.muted
        target = self; self.action = #selector(pressed)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pressed() { callback() }
}
