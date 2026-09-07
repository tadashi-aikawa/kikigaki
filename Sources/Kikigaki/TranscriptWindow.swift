import AppKit
import KikigakiCore

@MainActor
final class TranscriptWindowController: NSWindowController, NSSearchFieldDelegate, NSMenuItemValidation {
    var onRename: ((Int, String) -> Void)?
    var onSubmitTyped: ((String) -> Bool)?
    let typedEntry = TypedEntryField()
    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onCopy: ((Bool) -> Void)?
    var onRecopy: (() -> Void)?
    var onOpenMarkdown: (() -> Void)?
    var onSpeakerMappingChange: ((Int, Int?) -> Void)?
    var onAskAI: ((UUID?) -> Void)?
    var onScheduleAI: (() -> Void)?
    var onStopScheduleAI: (() -> Void)?
    private lazy var scheduleAI = AIActionButton("自動送信…") { [weak self] in self?.onScheduleAI?() }
    private lazy var stopScheduleAI = AIActionButton("自動送信を停止") { [weak self] in self?.onStopScheduleAI?() }
    private let scheduleNotice = Washi.label(size: 11, color: Washi.muted)
    private let scheduleRow = NSStackView()
    var onReadAI: ((UUID) -> Void)?
    var onOpenAIPane: (() -> Void)?
    var onCancelAI: ((UUID) -> Void)?
    var onRecreateAI: (() -> Void)?
    var onRetryAISave: (() -> Void)?
    var onShowPreviousAI: (() -> Void)?
    private lazy var previousAIButton = AIBadgeButton("前の会議に返事あり") { [weak self] in self?.onShowPreviousAI?() }
    private let aiBadges = AIBadgeBar()
    private let aiNotice = Washi.label(size: 11, color: Washi.muted)
    private lazy var reconnectAI = AIActionButton("AIセッションを作り直す") { [weak self] in self?.onRecreateAI?() }
    private lazy var retryAISave = AIActionButton("保存を再試行") { [weak self] in self?.onRetryAISave?() }
    private let aiStatusRow = NSStackView()
    private let askButton = WashiActionButton(title: "AIへ…", target: nil, action: nil)
    private var aiMarks: [String: AIMarkRow] = [:]
    private let speakerButton = SpeakerCountButton(title: "話者…", target: nil, action: nil)
    private var speakerSettingsPopover: SpeakerSettingsPopover?
    private let startStopButton = WashiActionButton()
    private var startStopWidth: NSLayoutConstraint?
    private let pauseButton = WashiActionButton()
    private let openButton = NSButton()
    private let copyButton = WashiActionButton(title: "会話をコピー", target: nil, action: nil)
    private let latestButton = NSButton(title: "最新の発言へ ↓", target: nil, action: nil)
    private var transcriptBottom: NSLayoutConstraint?
    private let statusChip = RecordingStatusChip()
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
    struct RowKey: Hashable { let kind: Utterance.Kind; let start: Double }
    struct RowID: Hashable { let kind: Utterance.Kind; let start: Double; let occurrence: Int }
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
        typedEntry.update(enabled: value.canSubmitTyped,
                          resetDraft: value.state == .preparing && previous.state != .preparing)
        previousAIButton.isHidden = value.previousAIUnread == 0 && value.aiRecoveryWarning == nil
        previousAIButton.title = value.aiRecoveryWarning == nil ? "前の会議に返事あり" : "AIの返事の回収を確認"
        previousAIButton.toolTip = value.aiRecoveryWarning
        transcriptBottom?.constant = value.ai == nil ? 0 : -34
        aiBadges.update(value.ai)
        aiNotice.stringValue = [value.ai?.progress, value.ai?.warning].compactMap { $0 }.joined(separator: " · ")
        aiNotice.isHidden = aiNotice.stringValue.isEmpty
        aiNotice.toolTip = aiNotice.stringValue
        aiNotice.textColor = value.ai?.noticeTone.color ?? Washi.muted
        reconnectAI.isHidden = value.ai?.canRecreate != true
        retryAISave.isHidden = value.ai?.saveFailed != true
        aiStatusRow.isHidden = aiNotice.isHidden && reconnectAI.isHidden && retryAISave.isHidden
        askButton.isHidden = value.ai == nil
        scheduleRow.isHidden = value.ai == nil
        scheduleAI.isHidden = value.aiSchedule.active
        scheduleAI.isEnabled = value.state == .recording || value.state == .paused
        scheduleAI.toolTip = scheduleAI.isEnabled ? "繰り返し送る依頼と間隔を設定します" : "録音中・一時停止中に開始できます"
        stopScheduleAI.toolTip = "自動送信と保留中の最後の1回を取りやめます"
        stopScheduleAI.isHidden = !value.aiSchedule.active
        stopScheduleAI.setAccessibilityLabel("自動送信を停止")
        scheduleNotice.stringValue = value.aiSchedule.text
        scheduleNotice.toolTip = value.aiSchedule.toolTip
        scheduleNotice.textColor = value.aiSchedule.tone.color
        if let ai = value.ai {
            askButton.title = "AIへ…"
            askButton.toolTip = "AIへ依頼する (" + ai.shortcut + ")"
            askButton.isEnabled = value.canShare
            askButton.emphasis = .primary
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
        let startTitle = value.state == .idle && value.markdownURL != nil ? "新しい録音"
            : value.state.canStart ? value.state.startStopTitle : "停止"
        symbol(startStopButton, name: value.state.canStart ? "record.circle" : "stop.fill", title: startTitle, showTitle: true)
        startStopButton.isEnabled = value.state.canStart || value.state.canStop
        startStopWidth?.constant = value.state.canStart ? 112 : 72
        // 前の会議を共有できる画面では、フッターへ主操作を譲る。
        startStopButton.emphasis = value.state.canStart && !value.canShare ? .primary : .neutralOutline
        symbol(pauseButton, name: value.state == .paused ? "play.fill" : "pause.fill", title: value.state.pauseResumeTitle, showTitle: true)
        pauseButton.isEnabled = value.state.canPauseOrResume
        pauseButton.refreshStyle()
        pauseButton.isHidden = value.state == .idle
        openButton.isHidden = !(value.state == .idle && value.saved)
        statusChip.update(value, reduceMotion: shouldReduceMotion())
        var message = value.message ?? ""
        if value.saved, message.hasPrefix("保存:") {
            message = message.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        }
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        messageLabel.textColor = value.state == .idle && !value.saved && !message.isEmpty ? Washi.red : Washi.muted
        speakerButton.update(snapshot: value)
        speakerSettingsPopover?.update(snapshot: value)
        copyButton.title = value.hasCopied ? "続きをコピー" : "会話をコピー"
        copyButton.isEnabled = value.canShare && value.handoffPreview != nil
        copyButton.toolTip = value.hasCopied && value.canShare && value.handoffPreview == nil
            ? "前回コピーから変更なし"
            : "会話ファイルへの参照と、今回読む範囲をクリップボードにコピー"
        copyButton.emphasis = value.ai == nil ? .primary : .accentOutline
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
                rangeLabel.stringValue = correction + snapshot.contextStartClock(preview)
                    + " 〜 " + end + " " + snapshot.contextEndClock
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
        let allMarks = AIInlineMark.ordered(snapshot.ai?.conversation)
        var attached: [Int: [AIInlineMark]] = [:]
        let marks = allMarks.filter { mark in
            if mark.kind == .question, let index = mark.question.request.voiceAnchorIndex(in: snapshot.utterances) {
                attached[index, default: []].append(mark); return false
            }
            return true
        }
        var markIndex = 0
        let animated = sameMeeting && !shouldReduceMotion()
        var next: [RowID: TranscriptRow] = [:]
        var ordered: [any DocumentRow] = []
        var occurrences: [RowKey: Int] = [:]
        var inserted: [TranscriptRow] = []
        var changed: [TranscriptRow] = []
        for (index, utterance) in snapshot.utterances.enumerated() {
            while markIndex < marks.count, marks[markIndex].date < TranscriptRenderer.date(for: utterance, timeline: snapshot.timeline) {
                let mark = marks[markIndex]
                let view = markView(mark)
                aiMarks[mark.id] = view; ordered.append(view); markIndex += 1
            }
            if snapshot.hasCopied, snapshot.handoffPreview?.startLine == index + 1 { ordered.append(boundary) }
            let key = RowKey(kind: utterance.kind, start: utterance.start)
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let id = RowID(kind: utterance.kind, start: utterance.start, occurrence: occurrence)
            let row = rows[id] ?? TranscriptRow()
            if rows[id] == nil { inserted.append(row) }
            if row.update(utterance, names: snapshot.names, timeline: snapshot.timeline,
                          speakerPending: snapshot.pendingSpeakerRows.contains(index)) { changed.append(row) }
            row.updateAvatar(speakers: snapshot.speakers, store: avatars, editable: snapshot.canShare)
            row.onRename = { [weak self] slot, view in self?.showRename(slot: slot, relativeTo: view) }
            next[id] = row
            ordered.append(row)
            for mark in attached[index, default: []] {
                let view = markView(mark); aiMarks[mark.id] = view; ordered.append(view)
            }
        }
        while markIndex < marks.count {
            let mark = marks[markIndex]
            let view = markView(mark)
            aiMarks[mark.id] = view; ordered.append(view); markIndex += 1
        }
        if let tentative = snapshot.tentativeText {
            tentativeRow.updateTentative(tentative)
            ordered.append(tentativeRow)
        }
        rows = next
        let markIDs = Set(allMarks.map(\.id))
        aiMarks = aiMarks.filter { markIDs.contains($0.key) }
        transcriptDocument.setRows(ordered, anchor: anchor)
        for row in inserted {
            row.appear(animated: animated && snapshot.canSubmitTyped)
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
        askButton.isHidden = true
        askButton.setContentHuggingPriority(.required, for: .horizontal)
        speakerButton.setAccessibilityLabel("話者の統合先")
        for button in [startStopButton, pauseButton, askButton, copyButton] {
            button.isBordered = false
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        startStopWidth = startStopButton.widthAnchor.constraint(equalToConstant: 112)
        startStopWidth?.isActive = true
        pauseButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        openButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        openButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        for button in [askButton, copyButton] {
            button.widthAnchor.constraint(equalToConstant: 168).isActive = true
        }
        symbol(openButton, name: "doc.plaintext", title: "Markdownを開く")
        latestButton.isHidden = true
        latestButton.controlSize = .small
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.lineBreakMode = .byTruncatingMiddle
        rangeLabel.maximumNumberOfLines = 1
        rangeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let logoRule = NSView()
        Washi.surface(logoRule, color: Washi.rule)
        logoRule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        logoRule.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let controls = row([Washi.logoView(size: 26), logoRule, statusChip, speakerButton, NSView(), pauseButton, startStopButton, openButton], spacing: 8)
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
        let bottom = scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        transcriptBottom = bottom
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: body.topAnchor), bottom,
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            emptyView.centerXAnchor.constraint(equalTo: body.centerXAnchor), emptyView.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            latestButton.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            latestButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        let title = Washi.label("AIへ渡す会話", size: 13, weight: .semibold)
        aiBadges.onSelect = { [weak self] id in
            guard let self, let view = aiMarks[id] else { return }
            view.scrollToVisible(view.bounds); scrolled()
        }
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footerTitle = row([title, aiBadges, previousAIButton, NSView(), rangeLabel], spacing: 8)
        aiStatusRow.orientation = .horizontal; aiStatusRow.alignment = .centerY; aiStatusRow.spacing = 12
        aiNotice.lineBreakMode = .byTruncatingTail
        aiNotice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [aiNotice, reconnectAI, retryAISave] { aiStatusRow.addArrangedSubview(view) }
        aiStatusRow.isHidden = true
        let leftSpace = NSView(), rightSpace = NSView()
        let footerButtons = row([leftSpace, askButton, copyButton, rightSpace], spacing: 12)
        leftSpace.widthAnchor.constraint(equalTo: rightSpace.widthAnchor).isActive = true
        scheduleRow.orientation = .horizontal; scheduleRow.spacing = 12
        scheduleNotice.lineBreakMode = .byTruncatingTail
        scheduleNotice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [scheduleAI, scheduleNotice, stopScheduleAI] { scheduleRow.addArrangedSubview(view) }
        let footer = column([footerTitle, aiStatusRow, scheduleRow, footerButtons], spacing: 8, inset: 16)
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
        typedEntry.onSubmit = { [weak self] text in
            guard let self, onSubmitTyped?(text) == true else { return false }
            latestPressed()
            return true
        }
        let entryArea = column([typedEntry], spacing: 0, inset: 12)
        Washi.surface(entryArea, color: Washi.paper)
        return column([header, searchBar, separator(), body, entryArea, separator(), footer], spacing: 0, inset: 0)
    }

    override func cancelOperation(_ sender: Any?) {
        if searchOpen { closeSearch(sender) } else { super.cancelOperation(sender) }
    }
    private func symbol(_ button: NSButton, name: String, title: String, showTitle: Bool = false) {
        // Apple CoreGlyphsのname_availability.plistとNSImage APIで存在を確認した名称。
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = showTitle ? .imageLeading : .imageOnly
        button.imageHugsTitle = showTitle
        button.title = showTitle ? title : ""
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
    private func markView(_ mark: AIInlineMark) -> AIMarkRow {
        let state = snapshot.ai ?? AIViewState()
        let view = aiMarks[mark.id] ?? AIMarkRow(mark: mark, state: state)
        view.update(mark, state: state)
        let id = mark.question.request.id
        view.onRead = { [weak self] in self?.onReadAI?(id) }
        view.onReply = { [weak self] in self?.onAskAI?(id) }
        view.onCancel = { [weak self] in self?.onCancelAI?(id) }
        view.onPane = { [weak self] in self?.onOpenAIPane?() }
        view.onToggle = { [weak self, weak view] in
            guard let self, let view else { return }
            let y = scrollView.contentView.bounds.minY
            // 開いた行の見出しをその場に保つ。末尾追従で全文の末尾へ飛ばさない。
            transcriptDocument.reflow(anchor: .init(candidates: [(view, view.frame.minY - y)], y: y, atBottom: false))
            scrolled()
        }
        return view
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
        statusChip.update(snapshot, reduceMotion: shouldReduceMotion())
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
