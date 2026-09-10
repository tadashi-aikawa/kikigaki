import AppKit
import KikigakiCore

@MainActor
final class TranscriptWindowController: NSWindowController, NSSearchFieldDelegate, NSMenuItemValidation, NSWindowDelegate {
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
    var onFireScheduleAI: (() -> Void)?
    let compactFooter = AICompactFooter()
    private let recordingRange = Washi.label(size: 11, color: Washi.muted)
    var onPrepareAI: (() -> Void)?
    var onReadAI: ((UUID) -> Void)?
    var onOpenAIPane: (() -> Void)?
    var onCancelAI: ((UUID) -> Void)?
    /// 失敗した依頼を送り直す。元requestを渡し、送信文・宛先・親・作業許可を戻したシートを開く。
    var onResendAI: ((UUID) -> Void)?
    var onRecreateAI: (() -> Void)?
    var onRetryAISave: (() -> Void)?
    var onShowPreviousAI: (() -> Void)?
    private var aiRows: [String: any AITimelineRowView] = [:]
    private let speakerButton = SpeakerCountButton(title: "話者…", target: nil, action: nil)
    private var speakerSettingsPopover: SpeakerSettingsPopover?
    private let startStopButton = WashiActionButton()
    private var startStopWidth: NSLayoutConstraint?
    private var pauseWidth: NSLayoutConstraint?
    private var headerControls: NSStackView?
    private var minutesHeader: NSView?
    private let pauseButton = WashiActionButton()
    private let openButton = HoverButton()
    private let minutesButton = HoverButton(title: "議事録", target: nil, action: nil)
    private(set) var minutesSplit: MinutesSplitView!
    private var minutesStore: MinutesStore?
    var onMinutesVisibility: ((Bool) -> Void)?
    var onSelectMinutes: ((String?) throws -> Void)?
    private var waitingMinutesPath: String?
    private let latestButton = HoverButton(title: "最新の発言へ ↓", target: nil, action: nil)
    private var transcriptBottom: NSLayoutConstraint?
    private let statusChip = RecordingStatusChip()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
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
    let searchPrevious = HoverButton(title: "↑", target: nil, action: nil)
    let searchNext = HoverButton(title: "↓", target: nil, action: nil)
    var searchOpen = false
    var searchHits: [SearchHit] = []
    var currentHit: Int?
    // 開始時刻が重複しても落とさず、同時刻の出現順で別ビューとして扱う。
    struct RowKey: Hashable { let kind: Utterance.Kind; let start: Double }
    struct RowID: Hashable { let kind: Utterance.Kind; let start: Double; let occurrence: Int }
    var rows: [RowID: TranscriptRow] = [:]

    init(shouldReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }, minutesDefaults: UserDefaults = .standard) {
        self.shouldReduceMotion = shouldReduceMotion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 578),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "KIKIGAKI"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Washi.shade
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 460)
        window.center()
        window.setFrameAutosaveName("KikigakiTranscript")
        super.init(window: window)
        window.delegate = self
        minutesSplit = MinutesSplitView(left: buildContent(), defaults: minutesDefaults)
        window.contentView = minutesSplit
        if let minutesHeader {
            minutesSplit.preview.headerBar.heightAnchor.constraint(equalTo: minutesHeader.heightAnchor).isActive = true
        }
        minutesSplit.onLayout = { [weak self] in
            guard let self else { return }; self.updateHeader(width: self.minutesSplit.left.frame.width)
        }
        minutesSplit.onVisibility = { [weak self] _ in self?.refreshMinutes() }
        minutesSplit.preview.onSelect = { [weak self] path in try self?.onSelectMinutes?(path) }
        minutesSplit.restore()
        updateHeader(width: minutesSplit.left.frame.width)
        avatars.onChange = { [weak self] in
            guard let self else { return }
            for row in rows.values { row.updateAvatar(speakers: snapshot.speakers, store: avatars, editable: snapshot.canShare) }
            for row in aiRows.values { (row as? AIReplyRow)?.updateAvatar(store: avatars) }
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
    func show() { window?.makeKeyAndOrderFront(nil); refreshMinutes(); NSApp.activate(ignoringOtherApps: true) }

    func connectMinutes(_ store: MinutesStore?, waitingPath: String? = nil) {
        if minutesStore !== store {
            minutesSplit.preview.resetContext()
            minutesStore?.isVisible = false; minutesStore?.onPreviewChange = nil
            minutesStore = store
            store?.onPreviewChange = { [weak self] in self?.refreshMinutes() }
        }
        waitingMinutesPath = waitingPath; refreshMinutes()
    }
    private func refreshMinutes() {
        guard let minutesSplit else { return }
        let visible = minutesSplit.isPreviewVisible
        minutesStore?.isVisible = visible && window?.isVisible == true
        minutesSplit.preview.update(path: minutesStore?.state.minutesPath ?? (minutesStore == nil ? waitingMinutesPath : nil),
            source: minutesStore?.state.targetSource, active: visible && window?.isVisible == true, warning: minutesStore?.warning)
        minutesButton.toolTip = visible ? "議事録を隠す" : "議事録を表示"
        minutesButton.setAccessibilityLabel(minutesButton.toolTip)
        minutesButton.setAccessibilityValue(visible ? "ON" : "OFF")
        compactFooter.minutesNotice.isHidden = minutesStore?.hasUnseenMinutes != true
        onMinutesVisibility?(visible)
    }
    @objc func toggleMinutes() { minutesSplit.setVisible(!minutesSplit.isPreviewVisible) }
    func windowWillClose(_ notification: Notification) { minutesSplit.preview.stop(); minutesStore?.isVisible = false }
    func windowDidChangeScreen(_ notification: Notification) { minutesSplit.fitWindow() }
    func windowDidExitFullScreen(_ notification: Notification) { minutesSplit.fitWindow() }
    func windowDidEndLiveResize(_ notification: Notification) { minutesSplit.fitWindow() }
    func windowDidDeminiaturize(_ notification: Notification) { refreshMinutes() }

    func apply(_ value: SessionSnapshot) {
        let previous = snapshot
        snapshot = value
        compactFooter.update(value, reduceMotion: shouldReduceMotion())
        recordingRange.stringValue = value.markdownURL == nil ? "" : value.timeline.clock(at: 0) + "〜"
            + (value.state == .idle ? value.timeline.clock(at: value.elapsed) : "")
        typedEntry.update(enabled: value.canSubmitTyped,
                          resetDraft: value.state == .preparing && previous.state != .preparing)
        transcriptBottom?.constant = value.ai == nil ? 0 : -34
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
        startStopButton.isEnabled = value.state.canStart || value.state.canStop
        pauseButton.isEnabled = value.state.canPauseOrResume
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
        updateHeader(width: minutesSplit.left.frame.width)
        speakerSettingsPopover?.update(snapshot: value)
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // リサイズ前に固定幅を外す。事後だけだとAuto Layoutが旧ボタン幅で縮小を阻む。
        updateHeader(width: minutesSplit.isPreviewVisible ? min(minutesSplit.left.frame.width, frameSize.width - MinutesLayout.minimumRight - minutesSplit.dividerThickness) : frameSize.width)
        return frameSize
    }

    func windowDidResize(_ notification: Notification) {
        updateHeader(width: minutesSplit.left.frame.width)
    }

    private func updateHeader(width: CGFloat) {
        let compact = width < 600
        minutesButton.title = compact ? "" : "議事録"
        let value = snapshot
        // 前の会議を共有できる画面ではフッターへ主操作を譲る。リサイズ時も状態だけで決める。
        startStopButton.emphasis = value.state.canStart
            ? (value.canShare ? .neutralOutline : .primary) : .accentOutline
        pauseButton.emphasis = .goldOutline
        let title = value.state == .idle && value.markdownURL != nil ? "新しい録音"
            : value.state.canStart ? value.state.startStopTitle : "停止"
        symbol(startStopButton, name: value.state.canStart ? "record.circle" : "stop.fill",
               title: title, showTitle: !compact)
        symbol(pauseButton, name: value.state == .paused ? "play.fill" : "pause.fill",
               title: value.state.pauseResumeTitle, showTitle: !compact)
        // 最長ラベルでも左右に14pt以上を残し、開始/停止・一時停止/再開で幅を変えない。
        startStopWidth?.constant = compact ? 34 : 120
        pauseWidth?.constant = compact ? 34 : 120
        headerControls?.spacing = compact ? 6 : 8
        // 経過時間が長くてもボタンを押し出さない。省略時の実時刻はホバーでも読める。
        recordingRange.setContentCompressionResistancePriority(compact ? .defaultLow : .required, for: .horizontal)
        recordingRange.toolTip = recordingRange.stringValue
        startStopButton.refreshStyle(); pauseButton.refreshStyle()
    }
    private func updateRangeLabel() {
        compactFooter.more.toolTip = handoffNotice?.text ?? "その他の操作"
        if let notice = handoffNotice {
            messageLabel.stringValue = notice.text
            messageLabel.textColor = notice.failed ? Washi.red : Washi.muted
            messageLabel.isHidden = false
        } else {
            var message = snapshot.message ?? ""
            if snapshot.saved, message.hasPrefix("保存:") {
                message = message.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
            }
            messageLabel.stringValue = message
            messageLabel.textColor = snapshot.state == .idle && !snapshot.saved && !message.isEmpty ? Washi.red : Washi.muted
            messageLabel.isHidden = messageLabel.stringValue.isEmpty
        }
    }

    private func updateRows(previous: SessionSnapshot) {
        var anchor = transcriptDocument.anchor()
        let sameMeeting = previous.timeline.startedAt == snapshot.timeline.startedAt
        if !sameMeeting { rows.removeAll(); aiRows.removeAll(); anchor = .init(candidates: [], y: 0, atBottom: true) }
        // AIの追加・状態変化も発話と同じ追従規則にする。上へスクロール中はanchor、
        // 検索中はfollowsBottomが末尾移動を抑え、読んでいる位置を保つ。
        // 位置はCoreの純関数が決める。AIはUtteranceにしないので併合結果へは混ぜない。
        // 世代と接続はその行を送った宛先のものを引く。選択中の宛先には依存させない。
        let ai = snapshot.ai
        let items = AITimeline.items(conversation: ai?.conversation, utterances: snapshot.utterances,
                                     timeline: snapshot.timeline,
                                     generation: { ai?.generation(for: $0) ?? 1 },
                                     endedAt: snapshot.state == .idle ? snapshot.timeline.date(at: snapshot.elapsed) : nil,
                                     connection: { ai?.connection(for: $0) ?? .unknown },
                                     unconfirmed: ai?.unconfirmed ?? [])
        var attached: [Int: [AITimeline.Item]] = [:]
        for item in items { attached[item.slot, default: []].append(item) }
        let animated = sameMeeting && !shouldReduceMotion()
        var next: [RowID: TranscriptRow] = [:]
        var ordered: [any DocumentRow] = []
        var rangeRows: [NSView] = []
        var occurrences: [RowKey: Int] = [:]
        var inserted: [TranscriptRow] = []
        var changed: [TranscriptRow] = []
        for item in attached[-1, default: []] { ordered.append(aiRowView(item)) }
        for (index, utterance) in snapshot.utterances.enumerated() {
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
            for item in attached[index, default: []] { ordered.append(aiRowView(item)) }
            rangeRows.append(ordered.last!)
        }
        if let tentative = snapshot.tentativeText {
            tentativeRow.updateTentative(tentative)
            ordered.append(tentativeRow)
        }
        rows = next
        let rowIDs = Set(items.map(\.rowID))
        aiRows = aiRows.filter { rowIDs.contains($0.key) }
        transcriptDocument.setRows(ordered, anchor: anchor)
        transcriptDocument.setRangeBoundaries(ai?.rangeBoundaries ?? AIRangeBoundaries(),
            utteranceRows: rangeRows)
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
        configure(latestButton, #selector(latestPressed))
        configure(speakerButton, #selector(speakerPressed))
        speakerButton.setAccessibilityLabel("話者の統合先")
        for button in [startStopButton, pauseButton] {
            button.isBordered = false
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        startStopWidth = startStopButton.widthAnchor.constraint(equalToConstant: 120)
        startStopWidth?.isActive = true
        pauseWidth = pauseButton.widthAnchor.constraint(equalToConstant: 120)
        pauseWidth?.isActive = true
        openButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        openButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        symbol(openButton, name: "doc.plaintext", title: "Markdownを開く")
        latestButton.isHidden = true
        latestButton.controlSize = .small
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3
        recordingRange.setContentCompressionResistancePriority(.required, for: .horizontal)
        recordingRange.lineBreakMode = .byTruncatingMiddle
        minutesButton.target = self; minutesButton.action = #selector(toggleMinutes)
        minutesButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "議事録")
        minutesButton.imagePosition = .imageLeading
        minutesButton.isBordered = false; minutesButton.contentTintColor = Washi.muted
        minutesButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let controls = row([Washi.logoView(size: 26), statusChip, recordingRange, speakerButton, NSView(), pauseButton, startStopButton, openButton, minutesButton], spacing: 8)
        headerControls = controls
        let header = column([controls, messageLabel], spacing: 8, inset: 12)
        minutesHeader = header
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
        compactFooter.onSelect = { [weak self] id in
            guard let self, let view: NSView = aiRows[id] else { return }
            view.scrollToVisible(view.bounds); scrolled()
        }
        compactFooter.robot.callback = { [weak self] in self?.showRobotMenu() }
        compactFooter.more.callback = { [weak self] in self?.showFooterMenu() }
        compactFooter.minutesNotice.target = self; compactFooter.minutesNotice.action = #selector(toggleMinutes)
        let footer = compactFooter
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
        let close = HoverButton(title: "完了", target: self, action: #selector(closeSearch(_:)))
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
    /// 行IDごとにビューを再利用する。送信の形はrequestで固定なので、
    /// 到着で変わりうるのはAIの行だけ。同じ行を状態更新するので高さが跳ねない。
    private func aiRowView(_ item: AITimeline.Item) -> any DocumentRow {
        let state = snapshot.ai ?? AIViewState()
        let view: any AITimelineRowView
        if let existing = aiRows[item.rowID] { existing.update(item, state: state); view = existing }
        else {
            switch item.kind {
            case .sendLine: view = AISendLineRow(item: item, state: state)
            case .sendRow: view = AITypedSendRow(item: item, state: state)
            case .reply, .failure: view = AIReplyRow(item: item, state: state)
            }
        }
        let id = item.requestID
        // 送達不明の送信行にも取消を置く。返事の行を作らないので、他に取り消す場所がない。
        (view as? AISendLineRow)?.onCancel = { [weak self] in self?.onCancelAI?(id) }
        (view as? AITypedSendRow)?.onCancel = { [weak self] in self?.onCancelAI?(id) }
        if let reply = view as? AIReplyRow {
            reply.updateAvatar(store: avatars)
            reply.onRead = { [weak self] in self?.onReadAI?(id) }
            reply.onReply = { [weak self] in self?.onAskAI?(id) }
            reply.onCancel = { [weak self] in self?.onCancelAI?(id) }
            reply.onRetry = { [weak self] in self?.onResendAI?(id) }
            reply.onResize = { [weak self, weak reply] in
                guard let self, let reply else { return }
                let y = scrollView.contentView.bounds.minY
                // 引用を伸ばした行の上端をその場に保つ。末尾追従で全文の末尾へ飛ばさない。
                transcriptDocument.reflow(anchor: .init(candidates: [(reply, reply.frame.minY - y)], y: y, atBottom: false))
                scrolled()
            }
        }
        aiRows[item.rowID] = view
        return view
    }

    @objc private func askPressed() { onAskAI?(nil) }
    func footerMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        add("会話をコピー", #selector(copyPressed), enabled: snapshot.canShare && snapshot.handoffPreview != nil)
        menu.items.last?.toolTip = snapshot.handoffMessage
        if snapshot.hasCopied {
            add("直前の範囲を再コピー", #selector(recopyPressed), enabled: snapshot.canShare)
            add("会議の最初からコピー", #selector(fullCopyPressed), enabled: snapshot.canShare)
        }
        if snapshot.aiSchedule.active {
            add("今すぐ送る", #selector(fireAutomaticPressed),
                enabled: canFireAutomatic)
        }
        add("AIセッションを準備…", #selector(preparePressed), enabled: snapshot.ai?.canPrepare == true)
        menu.items.last?.toolTip = snapshot.ai?.preparedToolTip
        add("ペインを開く", #selector(panePressed), enabled: snapshot.ai?.canOpenPane == true)
        add("AIセッションを作り直す", #selector(recreatePressed), enabled: snapshot.ai?.canRecreate == true)
        add("保存を再試行", #selector(retrySavePressed), enabled: snapshot.ai?.saveFailed == true)
        if snapshot.previousAIUnread > 0 || snapshot.aiRecoveryWarning != nil { add("前の会議に返事あり", #selector(previousPressed)) }
        return menu
    }
    private func showFooterMenu() {
        let menu = footerMenu()
        menu.popUp(positioning: nil, at: footerMenuPosition(menu), in: compactFooter.more)
    }
    func footerMenuPosition(_ menu: NSMenu) -> NSPoint {
        NSPoint(x: compactFooter.more.bounds.maxX - menu.size.width,
                y: compactFooter.more.bounds.maxY + menu.size.height + 6)
    }
    private var canFireAutomatic: Bool {
        snapshot.aiSchedule.active && snapshot.aiSchedule.nextFire != nil && snapshot.aiSchedule.canFireNow
            && snapshot.ai?.isPreparing != true
            && snapshot.ai?.conversation?.questions.contains { $0.isAwaitingResult } != true
    }
    func robotMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        if snapshot.aiSchedule.active {
            add("今すぐ送る", #selector(fireAutomaticPressed), enabled: canFireAutomatic)
            add("自動実行解除", #selector(stopAutomaticPressed), enabled: snapshot.ai != nil)
        } else {
            add("自動実行…", #selector(configureAutomaticPressed),
                enabled: snapshot.ai != nil && (snapshot.state == .recording || snapshot.state == .paused))
        }
        add("手動実行…", #selector(askPressed), enabled: snapshot.ai != nil && snapshot.canShare)
        return menu
    }
    func robotMenuPosition(_ menu: NSMenu) -> NSPoint {
        NSPoint(x: 0, y: compactFooter.robot.bounds.maxY + menu.size.height + 6)
    }
    private func showRobotMenu() {
        let menu = robotMenu()
        menu.popUp(positioning: nil, at: robotMenuPosition(menu), in: compactFooter.robot)
    }
    @objc private func configureAutomaticPressed() { onScheduleAI?() }
    @objc private func stopAutomaticPressed() { onStopScheduleAI?() }
    @objc private func fireAutomaticPressed() {
        guard canFireAutomatic else { return }
        onFireScheduleAI?()
    }
    @objc private func preparePressed() { onPrepareAI?() }
    @objc private func panePressed() { onOpenAIPane?() }
    @objc private func recreatePressed() { onRecreateAI?() }
    @objc private func retrySavePressed() { onRetryAISave?() }
    @objc private func previousPressed() { onShowPreviousAI?() }
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
        if menuItem.action == #selector(toggleMinutes) {
            menuItem.title = minutesSplit.isPreviewVisible ? "議事録を隠す" : "議事録を表示"
            menuItem.state = minutesSplit.isPreviewVisible ? .on : .off
            return true
        }
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
        compactFooter.update(snapshot, reduceMotion: shouldReduceMotion())
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
