import AppKit
import KikigakiCore
import UniformTypeIdentifiers

/// 録音を始める前に、その会議だけの指定をまとめて決めるシート。
///
/// `session.start` の**前**に出す。取消は録音を始めないので、会議の巻き戻し(取り止め)は要らない。
/// 並べるのは会議ごとに変えたいものだけで、保存先や話者台帳のような設定ファイルへ書くものは置かない。
/// 決めた値は設定ファイルへ書き戻さず、この録音にだけ効く。
@MainActor
final class StartSheet: NSObject, NSTextViewDelegate {
    /// シートが決めた、この録音だけの指定。
    struct Options: Equatable {
        var diarizationEnabled = true
        /// 議事録の絶対パス。nilは指定なし
        var minutesPath: String?
        /// 自動送信の宛先の枠。nilは「送らない」
        var scheduleSlot: Int?
        /// 宛先があるときの自動送信の指定
        var schedule: AIScheduleOptions?
    }

    let window: NSWindow
    var onStart: ((Options) -> Void)?
    var onCancel: (() -> Void)?
    /// 「区別する」を選んだ時点で話者モデルを先読みする。次回設定は書き換えない
    var onDiarizationPreload: (() -> Void)?

    private let profiles: [ResolvedAIConfig]
    private let avatars = AvatarStore()
    /// 宛先ごとの下書き。選び直しても、その宛先で書いた文面と間隔を覚える
    private var drafts: [Int: AIScheduleSheet.Draft] = [:]
    /// 表示中の宛先。nilは「送らない」
    private(set) var selectedSlot: Int?

    private let stack = NSStackView()
    let diarizeOn = NSButton(radioButtonWithTitle: "区別する(最大4人)", target: nil, action: nil)
    let diarizeOff = NSButton(radioButtonWithTitle: "区別しない", target: nil, action: nil)
    private let diarizeHint = Washi.label(size: 11, color: Washi.muted)
    let minutesBox = StartSheetPathBox()
    private let minutesHint = Washi.label("開始と同時に、右のペインへ表示します。", size: 11, color: Washi.muted)
    private let aiSection = NSStackView()
    let destination = NSPopUpButton()
    let interval = NSPopUpButton()
    private let cwdLabel = Washi.label(size: 11, color: Washi.muted)
    let promptLine = StartSheetPromptLine()
    private let editButton = NSButton(title: "編集", target: nil, action: nil)
    private let promptRow = NSStackView()
    let editorBox = NSStackView()
    let editor = AIQuestionEditor()
    let work = NSButton(checkboxWithTitle: "作業を許可する(ファイル編集・コマンド実行)", target: nil, action: nil)
    let final = NSButton(checkboxWithTitle: "録音停止時に最後の1回を送る", target: nil, action: nil)
    let aiDetails = NSStackView()
    /// 開始は録音ボタンと同じ朱の面にする。取消と並べても「始めるもの」が一目で分かる。
    private let startButton = WashiActionButton()

    init(profiles: [ResolvedAIConfig], diarizationEnabled: Bool, exclusion: AudioExclusion,
         minutesPath: String? = nil, minutesHistory: [String] = []) {
        self.profiles = profiles
        window = StartSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Washi.paper
        avatars.onChange = { [weak self] in self?.refreshDestinationImages() }

        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        Washi.surface(stack, color: Washi.paper)
        // 幅は504ptで固定し、長いパスや依頼は縮めて収める。高さだけを中身に合わせる。
        stack.widthAnchor.constraint(equalToConstant: 504).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 0

        // 話者判別。録音開始で会議へ固定するので、始めてからは変えられない。
        for radio in [diarizeOn, diarizeOff] { radio.target = self; radio.action = #selector(diarizationChanged) }
        diarizeOn.state = diarizationEnabled ? .on : .off
        diarizeOff.state = diarizationEnabled ? .off : .on
        let radios = NSStackView(views: [diarizeOn, diarizeOff])
        radios.orientation = .horizontal; radios.spacing = 20
        add(row("話者判別", column([radios, diarizeHint], spacing: 4)), to: rows)

        // 小音量除外は次回設定の文字だけ。操作は録音中の「話者…」に残す。
        add(separator(), to: rows)
        let exclusionText = Washi.label(exclusion.enabled
            ? String(format: "ON · %.0f dBFS未満を除外", exclusion.thresholdDBFS) : "OFF · 全発話を含む", size: 13)
        let exclusionNote = Washi.label("録音中に「話者…」から調整できます", size: 11, color: Washi.muted)
        exclusionNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let exclusionRow = NSStackView(views: [exclusionText, exclusionNote])
        exclusionRow.orientation = .horizontal; exclusionRow.spacing = 10; exclusionRow.alignment = .firstBaseline
        add(row("小音量除外", exclusionRow), to: rows)

        // 議事録。指定すると開始と同時に右のペインへ出す。
        add(separator(), to: rows)
        minutesBox.completes = false
        minutesBox.isButtonBordered = true
        minutesBox.font = .systemFont(ofSize: 12)
        minutesBox.placeholderString = "議事録の絶対パス"
        minutesBox.setAccessibilityLabel("議事録のパス")
        minutesBox.addItems(withObjectValues: minutesHistory)
        minutesBox.numberOfVisibleItems = 10
        minutesBox.stringValue = minutesPath ?? ""
        minutesBox.onDrop = { [weak self] path in self?.setMinutesPath(path) }
        minutesBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 欄の幅は固定する。NSComboBoxの固有幅は中身で決まり、積極的には伸びない。
        minutesBox.widthAnchor.constraint(equalToConstant: 266).isActive = true
        let choose = NSButton(title: "ファイルを選ぶ…", target: self, action: #selector(chooseMinutes))
        choose.bezelStyle = .rounded
        choose.setContentHuggingPriority(.required, for: .horizontal)
        let minutesRow = NSStackView(views: [minutesBox, choose])
        minutesRow.orientation = .horizontal; minutesRow.spacing = 8; minutesRow.distribution = .fill
        add(row("議事録", column([minutesRow, minutesHint], spacing: 4)), to: rows)

        // 自動送信。`[[ai]]` が無ければ区画ごと出さない。
        if !profiles.isEmpty {
            add(separator(), to: rows)
            add(row("自動送信", buildAISection()), to: rows)
        }
        stack.addArrangedSubview(Washi.label("録音を開始", size: 17, weight: .semibold))
        stack.addArrangedSubview(rows)

        let note = Washi.label("前回の設定のままです", size: 11, color: Washi.muted)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        startButton.title = "開始 ⏎"; startButton.emphasis = .primary; startButton.isBordered = false
        startButton.target = self; startButton.action = #selector(startPressed)
        startButton.keyEquivalent = "\r"
        startButton.setAccessibilityLabel("録音を開始")
        startButton.refreshStyle()
        startButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let actions = NSStackView(views: [note, NSView(), cancel, startButton])
        actions.orientation = .horizontal; actions.spacing = 12
        stack.addArrangedSubview(actions)
        for view in [rows, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        (window as? StartSheetWindow)?.onDismiss = { [weak self] in self?.cancelPressed() }
        (window as? StartSheetWindow)?.onCommandReturn = { [weak self] in self?.startPressed() }
        editor.onSubmit = { [weak self] in self?.startPressed() }
        editor.onCancel = { [weak self] in self?.cancelPressed() }
        for label in [diarizeHint, minutesHint] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        applyDiarizationHint()
        selectDestination(profiles.first(where: \.autoStart)?.slot)
        fit()
    }

    // MARK: - 組み立て

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func row(_ title: String, _ value: NSView) -> NSStackView {
        let label = Washi.label(title, size: 12, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: 68).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [label, value])
        stack.orientation = .horizontal; stack.alignment = .top; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { add(view, to: stack) }
        return stack
    }
    private func separator() -> NSView {
        let line = NSView()
        Washi.surface(line, color: Washi.rule)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func buildAISection() -> NSView {
        destination.target = self; destination.action = #selector(destinationChanged)
        destination.setAccessibilityLabel("自動送信の宛先")
        destination.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destination.setContentHuggingPriority(.defaultLow, for: .horizontal)
        (destination.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        interval.target = self; interval.action = #selector(draftChanged)
        interval.setAccessibilityLabel("送信間隔")
        interval.setContentHuggingPriority(.required, for: .horizontal)
        let intervalLabel = Washi.label("間隔", size: 13)
        intervalLabel.setContentHuggingPriority(.required, for: .horizontal)
        let head = NSStackView(views: [destination, intervalLabel, interval])
        head.orientation = .horizontal; head.spacing = 8; head.alignment = .centerY; head.distribution = .fill

        cwdLabel.lineBreakMode = .byTruncatingHead
        cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editButton.bezelStyle = .rounded; editButton.target = self; editButton.action = #selector(toggleEditor)
        editButton.setContentHuggingPriority(.required, for: .horizontal)
        promptLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptRow.setViews([promptLine, editButton], in: .leading)
        promptRow.orientation = .horizontal; promptRow.spacing = 8; promptRow.alignment = .centerY
        promptRow.distribution = .fill

        editor.font = .systemFont(ofSize: 12); editor.textColor = Washi.ink
        editor.backgroundColor = .white; editor.isRichText = false; editor.delegate = self
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.placeholder = "毎回送る依頼を書いてください"
        editor.setAccessibilityLabel("毎回送るプロンプト")
        editor.frame = NSRect(x: 0, y: 0, width: 360, height: 52)
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let close = NSButton(title: "閉じる", target: self, action: #selector(toggleEditor))
        close.bezelStyle = .rounded
        close.setContentHuggingPriority(.required, for: .horizontal)
        let foot = NSStackView(views: [Washi.label("この会議のあいだだけ覚えます", size: 11, color: Washi.muted), NSView(), close])
        foot.orientation = .horizontal; foot.spacing = 10
        editorBox.orientation = .vertical; editorBox.alignment = .leading; editorBox.spacing = 5
        add(scroll, to: editorBox); add(foot, to: editorBox)
        editorBox.isHidden = true

        for control in [work, final] { control.target = self; control.action = #selector(draftChanged) }
        aiDetails.orientation = .vertical; aiDetails.alignment = .leading; aiDetails.spacing = 6
        for view in [cwdLabel, promptRow, editorBox] { add(view, to: aiDetails) }
        aiDetails.addArrangedSubview(work)
        aiDetails.addArrangedSubview(final)
        aiSection.orientation = .vertical; aiSection.alignment = .leading; aiSection.spacing = 6
        add(head, to: aiSection); add(aiDetails, to: aiSection)
        rebuildDestinationMenu()
        return aiSection
    }

    // MARK: - 宛先

    /// 宛先メニュー。行はavatar・name・cli+model+effortの2行で、「送らない」だけ1行。
    private func rebuildDestinationMenu() {
        let menu = NSMenu()
        let none = NSMenuItem(title: "送らない", action: nil, keyEquivalent: "")
        none.tag = 0
        menu.addItem(none)
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.tag = profile.slot
            let title = NSMutableAttributedString(string: profile.name,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            title.append(NSAttributedString(string: "\n" + Self.meta(profile), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            menu.addItem(item)
        }
        destination.menu = menu
        refreshDestinationImages()
    }
    private func refreshDestinationImages() {
        for profile in profiles {
            guard let item = destination.menu?.items.first(where: { $0.tag == profile.slot }) else { continue }
            item.image = AIProfileAvatar.image(name: profile.name, source: profile.avatar, store: avatars)
        }
        refreshDestinationTitle()
    }
    /// 閉じた状態の1行。メニューの2行をそのまま出すとボタンが伸びるので、別の項目を描く。
    private func refreshDestinationTitle() {
        let item = NSMenuItem(title: "送らない", action: nil, keyEquivalent: "")
        if let slot = selectedSlot, let profile = profiles.first(where: { $0.slot == slot }) {
            item.title = profile.name + AIModelLabel.separator + Self.meta(profile)
            item.image = AIProfileAvatar.image(name: profile.name, source: profile.avatar, store: avatars)
        }
        (destination.cell as? NSPopUpButtonCell)?.menuItem = item
        destination.setAccessibilityValue(item.title)
        destination.toolTip = item.title
        destination.needsDisplay = true
    }
    /// 「Codex · gpt-5.4 · high」。未設定の項目は黙って飛ばす。
    static func meta(_ profile: ResolvedAIConfig) -> String {
        [profile.cli.rawValue.capitalized, profile.model, profile.effort]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: AIModelLabel.separator)
    }
    /// 閉じた宛先ポップアップに出ている1行。
    var destinationTitle: String { (destination.cell as? NSPopUpButtonCell)?.menuItem?.title ?? "" }

    private func draft(for slot: Int) -> AIScheduleSheet.Draft {
        if let saved = drafts[slot] { return saved }
        guard let profile = profiles.first(where: { $0.slot == slot }) else {
            return .init(prompt: "", minutes: 3, workAllowed: true)
        }
        return .init(prompt: profile.autoPrompt, minutes: profile.autoIntervalMinutes,
                     workAllowed: profile.allowWork, sendFinal: true)
    }
    private var currentDraft: AIScheduleSheet.Draft {
        .init(prompt: editor.string, minutes: interval.selectedTag(),
              workAllowed: work.state == .on, sendFinal: final.state == .on)
    }
    private func selectDestination(_ slot: Int?) {
        selectedSlot = slot
        destination.selectItem(withTag: slot ?? 0)
        // 「送らない」なら下の指定は畳む。始めないものの設定を並べても選べるものは増えない。
        aiDetails.isHidden = slot == nil
        guard let slot, let profile = profiles.first(where: { $0.slot == slot }) else {
            refreshDestinationTitle(); return
        }
        let draft = draft(for: slot)
        cwdLabel.stringValue = Self.shortPath(profile.cwd)
        editor.unmarkText(); editor.string = draft.prompt
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.needsDisplay = true
        interval.removeAllItems()
        for minute in AIScheduleOptions.minuteChoices(including: draft.minutes) {
            interval.addItem(withTitle: "\(minute)分"); interval.lastItem?.tag = minute
        }
        interval.selectItem(withTag: draft.minutes)
        work.state = draft.workAllowed ? .on : .off
        final.state = draft.sendFinal ? .on : .off
        refreshPrompt()
        refreshDestinationTitle()
    }
    private func refreshPrompt() {
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        promptLine.stringValue = text.isEmpty ? "毎回送る依頼を書いてください" : text.replacingOccurrences(of: "\n", with: " ")
        promptLine.textColor = text.isEmpty ? Washi.muted : Washi.tentative
        promptLine.toolTip = text.isEmpty ? nil : editor.string
        // 依頼が空のままでは自動送信を始められない。録音そのものは止めない。
        startButton.toolTip = selectedSlot != nil && text.isEmpty ? "依頼が空のため、自動送信は始めません" : nil
    }
    private static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: - 操作

    @objc private func diarizationChanged() {
        applyDiarizationHint()
        if diarizeOn.state == .on { onDiarizationPreload?() }
    }
    private func applyDiarizationHint() {
        diarizeHint.stringValue = diarizeOn.state == .on ? "録音を始めると変えられません。"
            : "録音を始めると変えられません。すべて「発言」として記録します。"
    }
    /// ポップアップで選び直したとき。表示中の宛先の下書きを先に保存する。
    @objc func destinationChanged() {
        if let previous = selectedSlot { drafts[previous] = currentDraft }
        let tag = destination.selectedTag()
        selectDestination(tag == 0 ? nil : tag)
        fit()
    }
    @objc private func draftChanged() {
        if let slot = selectedSlot { drafts[slot] = currentDraft }
    }
    @objc func toggleEditor() {
        editorBox.isHidden.toggle()
        promptRow.isHidden = !editorBox.isHidden
        fit()
        if !editorBox.isHidden { window.makeFirstResponder(editor) }
    }
    func textDidChange(_ notification: Notification) {
        editor.needsDisplay = true; draftChanged(); refreshPrompt()
    }
    @objc private func chooseMinutes() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.setMinutesPath(url.path)
        }
    }

    /// URLスキームやドロップから、開いている最中に議事録を差し替える入口。
    func setMinutesPath(_ path: String) {
        minutesBox.stringValue = path
        showMinutesHint(nil)
    }
    /// パス欄の下の1行。指定が読めないときだけ理由へ差し替える。
    /// URLスキームが読めない議事録を渡してきたときも、パス欄は触らずここだけを差し替える。
    func showMinutesHint(_ problem: String?) {
        minutesHint.stringValue = problem ?? "開始と同時に、右のペインへ表示します。"
        minutesHint.textColor = problem == nil ? Washi.muted : Washi.gold
    }
    /// パス欄の下にいま出ている1行。
    var minutesHintText: String { minutesHint.stringValue }

    /// 中身に合わせて高さを詰める。AI区画の畳み・プロンプトの展開で変わる。
    private func fit() {
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 504, height: ceil(stack.fittingSize.height)))
    }

    func present(on parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(nil)
    }
    func close() {
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
    func focus() { window.makeKeyAndOrderFront(nil) }

    /// パス欄の入力。確定を待たず、いま書かれている文字を読む。
    private var minutesInput: String? {
        let input = minutesBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return input.isEmpty ? nil : (input as NSString).expandingTildeInPath
    }

    /// 画面の値。開始できない入力があれば nil。
    var options: Options? {
        var result = Options(diarizationEnabled: diarizeOn.state == .on)
        if let path = minutesInput {
            guard (try? MinutesPath.validate(path)) != nil else { return nil }
            result.minutesPath = path
        }
        if let slot = selectedSlot {
            let draft = currentDraft
            // 依頼が空・間隔が不正なら自動送信は始めない。録音そのものは始める。
            if let options = try? AIScheduleOptions(prompt: draft.prompt, interval: Double(draft.minutes) * 60,
                                                   workAllowed: draft.workAllowed, sendFinal: draft.sendFinal) {
                result.scheduleSlot = slot
                result.schedule = options
            }
        }
        return result
    }

    @objc func startPressed() {
        guard !editor.hasMarkedText(), !minutesBox.hasMarkedTextForStart else { return }
        guard let value = options else {
            showMinutesHint("絶対パスの.mdファイルを指定してください")
            return
        }
        showMinutesHint(nil)
        close()
        onStart?(value)
    }
    @objc func cancelPressed() {
        close()
        onCancel?()
    }
}

/// ⌘⏎でも開始する。焦点がどこにあっても同じ操作で始められるようにする。
/// 素の⏎は既定ボタンが受け、プロンプト編集中だけ `AIQuestionWindow` が改行へ回す。
final class StartSheetWindow: AIQuestionWindow {
    var onCommandReturn: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onCommandReturn?()
            return
        }
        super.sendEvent(event)
    }
}

/// 履歴付きの議事録パス欄。`.md` のファイルをドロップしても指定できる。
final class StartSheetPathBox: NSComboBox {
    var onDrop: ((String) -> Void)?
    /// 変換中のEnterで開始しないための確認。
    var hasMarkedTextForStart: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    func droppedPath(_ pasteboard: NSPasteboard) -> String? {
        guard let url = NSURL(from: pasteboard) as URL?, url.isFileURL,
              url.pathExtension.lowercased() == "md" else { return nil }
        return url.path
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPath(sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPath(sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let path = droppedPath(sender.draggingPasteboard) else { return false }
        onDrop?(path)
        return true
    }
}

/// プロンプトの畳んだ1行。和紙の枡へ収め、押すものではないことを見せる。
final class StartSheetPromptLine: NSTextField {
    private final class InsetCell: NSTextFieldCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            super.drawingRect(forBounds: rect.insetBy(dx: 8, dy: 4))
        }
    }
    init() {
        super.init(frame: .zero)
        cell = InsetCell(textCell: "")
        isEditable = false; isSelectable = false; isBezeled = false; isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 12)
        textColor = Washi.tentative
        lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.backgroundColor = Washi.shade.cgColor
        layer?.cornerRadius = 5
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 16; size.height += 8
        return size
    }
}
