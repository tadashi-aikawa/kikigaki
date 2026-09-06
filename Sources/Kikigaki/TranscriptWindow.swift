import AppKit
import KikigakiCore

/// NSButtonの操作・フォーカス・アクセシビリティを残して主操作の地だけ描く。
private final class CopyButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 32, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        (isEnabled ? (isHighlighted ? Washi.brightRed : Washi.red) : Washi.rule).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}

private final class RecordingMark: NSView {
    var paused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (paused ? Washi.muted : Washi.red).setFill()
        if paused {
            NSRect(x: 0, y: 0, width: 3, height: 9).fill()
            NSRect(x: 6, y: 0, width: 3, height: 9).fill()
        } else { NSBezierPath(ovalIn: bounds).fill() }
    }
}

@MainActor
final class TranscriptWindowController: NSWindowController, NSSearchFieldDelegate, NSMenuItemValidation {
    var onRename: ((Int, String) -> Void)?
    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onCopy: ((Bool) -> Void)?
    var onRecopy: (() -> Void)?
    var onOpenMarkdown: (() -> Void)?
    var onSpeakerMappingChange: ((Int, Int?) -> Void)?
    var onAskAI: ((UUID?) -> Void)?
    var onReadAI: ((UUID) -> Void)?
    var onOpenAIPane: (() -> Void)?
    var onCancelAI: ((UUID) -> Void)?
    private let aiPanel = AIPanel()
    private let askButton = NSButton(title: "AIに質問…", target: nil, action: nil)
    private var aiMarks: [String: AIMarkRow] = [:]
    private let speakerButton = SpeakerCountButton(title: "話者…", target: nil, action: nil)
    private var speakerSettingsPopover: SpeakerSettingsPopover?
    private let startStopButton = NSButton()
    private let pauseButton = NSButton()
    private let openButton = NSButton()
    private let copyButton = CopyButton(title: "会話をコピー", target: nil, action: nil)
    private let latestButton = NSButton(title: "最新の発言へ ↓", target: nil, action: nil)
    private let statusDot = RecordingMark()
    private let statusLabel = Washi.label(size: 13, weight: .semibold)
    private let elapsedLabel = Washi.label(color: Washi.muted)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let rangeLabel = Washi.label(color: Washi.muted)
    private var handoffNotice: (text: String, failed: Bool)?
    private var noticeDismissal: DispatchWorkItem?
    private var copyRequested = false
    private let emptyView = NSStackView()
    private let emptyLabel = Washi.label(size: 13, color: Washi.muted)
    private var renamePopover: SpeakerPopover?
    private let boundary = CopyBoundary()
    private let tentativeRow = TranscriptRow(tentative: true)
    private let avatars = AvatarStore()
    private let shouldReduceMotion: () -> Bool
    // ここから下は TranscriptWindowSearch.swift の検索も読む。extension には保存プロパティを
    // 置けないため、検索の状態もこの本体で持つ
    let scrollView = NSScrollView()
    let transcriptDocument = TranscriptDocument()
    var snapshot = SessionSnapshot()
    let searchField = NSSearchField()
    let searchCount = Washi.label(color: Washi.muted)
    let searchBar = NSStackView()
    let searchPrevious = NSButton(title: "↑", target: nil, action: nil)
    let searchNext = NSButton(title: "↓", target: nil, action: nil)
    var searchOpen = false
    var searchHits: [SearchHit] = []
    var currentHit: Int?
    // 開始時刻が重複しても落とさず、同時刻の出現順で別ビューとして扱う。
    struct RowID: Hashable { let start: Double; let occurrence: Int }
    var rows: [RowID: TranscriptRow] = [:]

    init(shouldReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.shouldReduceMotion = shouldReduceMotion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 578),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "KIKIGAKI"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Washi.shade
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 460)
        window.center()
        window.setFrameAutosaveName("KikigakiTranscript")
        super.init(window: window)
        window.contentView = buildContent()
        avatars.onChange = { [weak self] in
            guard let self else { return }
            for row in rows.values { row.updateAvatar(speakers: snapshot.speakers, store: avatars, editable: snapshot.canShare) }
            renamePopover?.refreshAvatars()
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func show() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    func apply(_ value: SessionSnapshot) {
        let previous = snapshot
        snapshot = value
        aiPanel.isHidden = value.ai == nil
        askButton.isHidden = value.ai == nil
        if let ai = value.ai {
            aiPanel.update(ai, newMeeting: previous.timeline.startedAt != value.timeline.startedAt)
            askButton.title = "AIに質問…  " + ai.shortcut
            askButton.isEnabled = value.canShare
        }
        if previous.state != value.state || previous.timeline.startedAt != value.timeline.startedAt { clearHandoffNotice() }
        if copyRequested || previous.handoffMessage != value.handoffMessage || previous.handoffFailed != value.handoffFailed {
            clearHandoffNotice()
            if let text = value.handoffMessage, !text.isEmpty {
                handoffNotice = (text, value.handoffFailed)
                if !value.handoffFailed {
                    let dismissal = DispatchWorkItem { [weak self] in
                        self?.handoffNotice = nil
                        self?.updateRangeLabel()
                    }
                    noticeDismissal = dismissal
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissal)
                }
            }
        }
        if value.state == .preparing || previous.timeline.startedAt != value.timeline.startedAt { renamePopover?.close() }
        let startTitle = value.state == .idle && value.markdownURL != nil ? "新しい録音" : value.state.startStopTitle
        symbol(startStopButton, name: value.state.canStart ? "record.circle" : "stop.fill", title: startTitle)
        startStopButton.isEnabled = value.state.canStart || value.state.canStop
        symbol(pauseButton, name: value.state == .paused ? "play.fill" : "pause.fill", title: value.state.pauseResumeTitle)
        pauseButton.isEnabled = value.state.canPauseOrResume
        pauseButton.isHidden = value.state == .idle && value.markdownURL != nil
        openButton.isHidden = !(value.state == .idle && value.saved)
        statusLabel.stringValue = value.state == .idle && value.saved ? "保存済み" : value.state.statusLabel
        statusDot.isHidden = value.state != .recording && value.state != .paused
        statusDot.paused = value.state == .paused
        elapsedLabel.stringValue = TranscriptRenderer.elapsed(value.elapsed)
        var message = value.message ?? ""
        if value.saved, message.hasPrefix("保存:") {
            message = message.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        }
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        messageLabel.textColor = value.state == .idle && !value.saved && !message.isEmpty ? Washi.red : Washi.muted
        speakerButton.update(snapshot: value)
        speakerSettingsPopover?.update(snapshot: value)
        copyButton.title = value.hasCopied ? "前回コピー以降をコピー" : "会話をコピー"
        copyButton.isEnabled = value.canShare && value.handoffPreview != nil
        copyButton.attributedTitle = NSAttributedString(string: copyButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: copyButton.isEnabled ? NSColor.white : Washi.muted
        ])
        copyButton.menu = handoffMenu()
        updateRangeLabel()
        emptyView.isHidden = !value.utterances.isEmpty || value.tentativeText != nil || !(value.ai?.conversation?.questions.isEmpty ?? true)
        emptyLabel.stringValue = value.state == .idle ? "録音を開始すると、会話がここに表示されます。" : "発言を待っています…"
        updateRows(previous: previous)
        refreshSearch(reset: previous.timeline.startedAt != value.timeline.startedAt, reveal: false)
    }

    private func clearHandoffNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        handoffNotice = nil
    }
    private func updateRangeLabel() {
        if let notice = handoffNotice {
            rangeLabel.stringValue = notice.text
            rangeLabel.textColor = notice.failed ? Washi.red : Washi.muted
        } else {
            rangeLabel.textColor = Washi.muted
            if let preview = snapshot.handoffPreview {
                let end = snapshot.state == .idle ? "終了" : "現在"
                let correction = preview.includesCorrections ? "訂正を含む · " : ""
                rangeLabel.stringValue = correction + snapshot.timeline.clock(at: preview.startTime)
                    + " 〜 " + end + " " + snapshot.timeline.clock(at: snapshot.elapsed)
            } else { rangeLabel.stringValue = snapshot.hasCopied ? "前回コピーから変更なし" : "発言を待っています" }
        }
        rangeLabel.toolTip = rangeLabel.stringValue
    }

    private func updateRows(previous: SessionSnapshot) {
        var anchor = transcriptDocument.anchor()
        let sameMeeting = previous.timeline.startedAt == snapshot.timeline.startedAt
        if !sameMeeting { rows.removeAll(); aiMarks.removeAll(); anchor = .init(candidates: [], y: 0, atBottom: true) }
        if sameMeeting, previous.utterances == snapshot.utterances, previous.ai?.conversation != snapshot.ai?.conversation {
            // 回答の到着だけでは末尾へ移動しない。人間の発言が増えたときの追従は従来どおり。
            anchor = .init(candidates: anchor.candidates, y: anchor.y, atBottom: false)
        }
        var marks: [(String, Date, String)] = []
        for question in snapshot.ai?.conversation?.questions ?? [] {
            let name = question.request.envelope.participant.participantName
            let prefix = "Q\(question.request.number) " + name
            if let sent = question.sendAttemptedAt { marks.append((question.request.id.uuidString + "/send", sent, prefix + "へ質問")) }
            if let arrived = question.resultReceivedAt {
                marks.append((question.request.id.uuidString + "/result", arrived, prefix + (question.result?.kind == .needsInput ? "の確認" : "の回答")))
            }
        }
        marks = marks.enumerated().sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1 }.map(\.element)
        var markIndex = 0
        let animated = sameMeeting && !shouldReduceMotion()
        var next: [RowID: TranscriptRow] = [:]
        var ordered: [any DocumentRow] = []
        var occurrences: [Double: Int] = [:]
        var inserted: [TranscriptRow] = []
        var changed: [TranscriptRow] = []
        for (index, utterance) in snapshot.utterances.enumerated() {
            while markIndex < marks.count, marks[markIndex].1 < snapshot.timeline.date(at: utterance.start) {
                let mark = marks[markIndex]
                let view = markView(mark)
                aiMarks[mark.0] = view; ordered.append(view); markIndex += 1
            }
            if snapshot.hasCopied, snapshot.handoffPreview?.startLine == index + 1 { ordered.append(boundary) }
            let occurrence = occurrences[utterance.start, default: 0]
            occurrences[utterance.start] = occurrence + 1
            let id = RowID(start: utterance.start, occurrence: occurrence)
            let row = rows[id] ?? TranscriptRow()
            if rows[id] == nil { inserted.append(row) }
            if row.update(utterance, names: snapshot.names, timeline: snapshot.timeline,
                          speakerPending: snapshot.pendingSpeakerRows.contains(index)) { changed.append(row) }
            row.updateAvatar(speakers: snapshot.speakers, store: avatars, editable: snapshot.canShare)
            row.onRename = { [weak self] slot, view in self?.showRename(slot: slot, relativeTo: view) }
            next[id] = row
            ordered.append(row)
        }
        while markIndex < marks.count {
            let mark = marks[markIndex]
            let view = markView(mark)
            aiMarks[mark.0] = view; ordered.append(view); markIndex += 1
        }
        if let tentative = snapshot.tentativeText {
            tentativeRow.updateTentative(tentative)
            ordered.append(tentativeRow)
        }
        rows = next
        transcriptDocument.setRows(ordered, anchor: anchor)
        for row in inserted {
            row.appear(animated: animated && snapshot.state == .recording)
            // 停止時の再分割で開始位置が変わった行も、最終結果の変更として同時に点灯する。
            if snapshot.state == .idle && !previous.utterances.isEmpty { row.highlight(animated: animated) }
        }
        for row in changed { row.highlight(animated: animated) }
        scrolled()
    }

    private func buildContent() -> NSView {
        configure(startStopButton, #selector(startStopPressed))
        configure(pauseButton, #selector(pausePressed))
        configure(openButton, #selector(openPressed))
        configure(copyButton, #selector(copyPressed))
        configure(latestButton, #selector(latestPressed))
        configure(speakerButton, #selector(speakerPressed))
        configure(askButton, #selector(askPressed))
        aiPanel.onReply = { [weak self] in self?.onAskAI?($0) }
        aiPanel.onRead = { [weak self] in self?.onReadAI?($0) }
        aiPanel.onPane = { [weak self] in self?.onOpenAIPane?() }
        aiPanel.onCancel = { [weak self] in self?.onCancelAI?($0) }
        aiPanel.isHidden = true; askButton.isHidden = true
        askButton.isBordered = false
        askButton.setContentHuggingPriority(.required, for: .horizontal)
        speakerButton.setAccessibilityLabel("話者の統合先")
        for button in [startStopButton, pauseButton, openButton] {
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        symbol(openButton, name: "doc.plaintext", title: "Markdownを開く")
        copyButton.isBordered = false
        copyButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        copyButton.toolTip = "会話ファイルへの参照と、今回読む範囲をクリップボードにコピー"
        latestButton.isHidden = true
        latestButton.controlSize = .small
        statusDot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 9).isActive = true
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.lineBreakMode = .byTruncatingMiddle
        rangeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let logoRule = NSView()
        Washi.surface(logoRule, color: Washi.rule)
        logoRule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        logoRule.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let status = row([statusDot, statusLabel, elapsedLabel], spacing: 8)
        let controls = row([Washi.logoView(size: 26), logoRule, status, NSView(), speakerButton, pauseButton, startStopButton, openButton], spacing: 12)
        let header = column([controls, messageLabel], spacing: 8, inset: 12)
        Washi.surface(header)
        scrollView.documentView = transcriptDocument
        transcriptDocument.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = Washi.paper
        transcriptDocument.autoresizingMask = [.width]
        let body = NSView()
        Washi.surface(body, color: Washi.paper)
        body.addSubview(scrollView)
        body.addSubview(emptyView)
        body.addSubview(latestButton)
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 20
        emptyView.addArrangedSubview(Washi.logoView(size: 96))
        emptyView.addArrangedSubview(Washi.label("会話を、ここに書き留める。", size: 17))
        emptyView.addArrangedSubview(emptyLabel)
        for view in [scrollView, emptyView, latestButton] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: body.topAnchor), scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            emptyView.centerXAnchor.constraint(equalTo: body.centerXAnchor), emptyView.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            latestButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -20),
            latestButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        let title = Washi.label("AIへ渡す会話", size: 13, weight: .semibold)
        let footerTitle = row([title, NSView(), rangeLabel], spacing: 12)
        copyButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerButtons = row([askButton, copyButton], spacing: 12)
        let footer = column([footerTitle, footerButtons], spacing: 8, inset: 16)
        Washi.surface(footer)
        searchField.placeholderString = "会話を検索"
        searchField.setAccessibilityLabel("会話を検索")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchCount.widthAnchor.constraint(equalToConstant: 90).isActive = true
        configure(searchPrevious, #selector(findPrevious(_:)))
        configure(searchNext, #selector(findNext(_:)))
        searchPrevious.toolTip = "前を検索 (Shift+Return)"
        searchNext.toolTip = "次を検索 (Return)"
        searchPrevious.setAccessibilityLabel("前を検索")
        searchNext.setAccessibilityLabel("次を検索")
        let close = NSButton(title: "完了", target: self, action: #selector(closeSearch(_:)))
        close.bezelStyle = .rounded
        searchBar.orientation = .horizontal
        searchBar.alignment = .centerY
        searchBar.spacing = 8
        searchBar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        for view in [searchField, searchCount, searchPrevious, searchNext, close] { searchBar.addArrangedSubview(view) }
        Washi.surface(searchBar)
        searchBar.isHidden = true
        return column([header, searchBar, separator(), body, separator(), aiPanel, footer], spacing: 0, inset: 0)
    }

    override func cancelOperation(_ sender: Any?) {
        if searchOpen { closeSearch(sender) } else { super.cancelOperation(sender) }
    }
    private func symbol(_ button: NSButton, name: String, title: String) {
        // Apple CoreGlyphsのname_availability.plistとNSImage APIで存在を確認した名称。
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }
    private func configure(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.keyEquivalent = ""
    }
    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat, inset: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true }
        return stack
    }
    private func separator() -> NSView {
        let view = NSView()
        Washi.surface(view, color: Washi.rule)
        view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return view
    }
    @objc private func startStopPressed() { onStartStop?() }
    private func markView(_ mark: (String, Date, String)) -> AIMarkRow {
        if let current = aiMarks[mark.0], current.title == mark.2, current.date == mark.1 { return current }
        return AIMarkRow(title: mark.2, date: mark.1)
    }
    @objc private func askPressed() { onAskAI?(nil) }
    @objc private func pausePressed() { onPauseResume?() }
    @objc private func openPressed() { onOpenMarkdown?() }
    @objc private func speakerPressed() {
        if let popover = speakerSettingsPopover, popover.isShown { popover.close(); return }
        renamePopover?.close()
        let popover = SpeakerSettingsPopover(snapshot: snapshot)
        popover.onMappingChange = { [weak self] slot, target in self?.onSpeakerMappingChange?(slot, target) }
        speakerSettingsPopover = popover
        popover.present(relativeTo: speakerButton.bounds, of: speakerButton)
    }
    private func copyWithNotice(_ action: () -> Void) {
        clearHandoffNotice()
        updateRangeLabel()
        copyRequested = true
        action()
        copyRequested = false
    }
    @objc private func copyPressed() { copyWithNotice { onCopy?(false) } }
    @objc func recopyPressed() {
        guard snapshot.canShare && snapshot.hasCopied else { return }
        copyWithNotice { onRecopy?() }
    }
    @objc func fullCopyPressed() {
        guard snapshot.canShare && (snapshot.hasCopied || !snapshot.utterances.isEmpty) else { return }
        copyWithNotice { onCopy?(true) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(recopyPressed) { return snapshot.canShare && snapshot.hasCopied }
        if menuItem.action == #selector(fullCopyPressed) { return snapshot.canShare && (snapshot.hasCopied || !snapshot.utterances.isEmpty) }
        return true
    }
    @objc private func latestPressed() {
        transcriptDocument.scroll(NSPoint(x: 0, y: max(0, transcriptDocument.frame.height - scrollView.contentSize.height)))
        latestButton.isHidden = true
    }
    @objc func scrolled() {
        latestButton.isHidden = transcriptDocument.anchor().atBottom || (snapshot.utterances.isEmpty && snapshot.tentativeText == nil)
    }
    @objc private func motionChanged() {
        if shouldReduceMotion() { rows.values.forEach { $0.stopAnimations() } }
    }
    private func handoffMenu() -> NSMenu {
        let menu = NSMenu()
        let recopy = NSMenuItem(title: "直前の範囲を再コピー", action: #selector(recopyPressed), keyEquivalent: "")
        recopy.target = self
        recopy.isEnabled = validateMenuItem(recopy)
        menu.addItem(recopy)
        let full = NSMenuItem(title: "会議の最初からコピー", action: #selector(fullCopyPressed), keyEquivalent: "")
        full.target = self
        full.isEnabled = validateMenuItem(full)
        menu.addItem(full)
        return menu
    }
    private func showRename(slot: Int, relativeTo view: NSView) {
        guard snapshot.canShare, (0..<SpeakerNames.slotCount).contains(slot) else { return }
        speakerSettingsPopover?.close()
        renamePopover?.close()
        let popover = SpeakerPopover(slot: slot, names: snapshot.names, speakers: snapshot.speakers, avatars: avatars)
        popover.onRename = { [weak self] name in self?.onRename?(slot, name) }
        renamePopover = popover
        // 行が再分割で消えても編集は維持するため、安定したscrollViewをアンカーにする。
        popover.present(relativeTo: scrollView.convert(view.bounds, from: view), of: scrollView)
    }
}
