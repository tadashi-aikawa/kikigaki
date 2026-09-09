import AppKit
import KikigakiCore

@MainActor final class AIPastMeetingsWindow: NSWindowController {
    private let store: AIRecordStore
    private let current: () -> UUID?
    private let picker = NSPopUpButton()
    private let scroll = NSScrollView()
    private let transcript = TranscriptDocument()
    private let badges = AIBadgeBar()
    private lazy var retry = AIActionButton("保存を再試行") { [weak self] in self?.store.retrySaves(); self?.update() }
    /// 行ごとに同じボタンを並べないため、接続の操作はここへ集める。
    private lazy var openPane = AIActionButton("ペインを開く") { [weak self] in
        guard let record = self?.selectedRecord else { return }
        Task { try? await record.controller.showPane() }
    }
    private var marks: [String: any AITimelineRowView] = [:]
    private var speechRows: [Int: TranscriptRow] = [:]
    private let avatars = AvatarStore()
    /// 書き起こしウィンドウと同じ可視化の既読判定を使う。
    private(set) lazy var aiRead = AIReadWatcher(window: { [weak self] in self?.window })
    private var boundsObserver: (any NSObjectProtocol)?
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    private var displayedMeeting: UUID?
    private let warning = NSTextField(wrappingLabelWithString: "")
    private var ids: [UUID] = []
    init(store: AIRecordStore, current: @escaping () -> UUID?) {
        self.store = store; self.current = current
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "前の会議のAIの返事"; window.isReleasedWhenClosed = false
        super.init(window: window)
        avatars.onChange = { [weak self] in
            guard let self else { return }
            for row in marks.values { (row as? AIReplyRow)?.updateAvatar(store: avatars) }
        }
        let actions = NSStackView(views: [openPane, retry]); actions.orientation = .horizontal; actions.spacing = 12
        let stack = NSStackView(views: [picker, warning, badges, actions, scroll]); stack.orientation = .vertical; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [picker, warning, badges, actions, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        scroll.documentView = transcript; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        transcript.autoresizingMask = [.width]; transcript.followsBottom = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        window.contentView = stack; window.backgroundColor = Washi.paper
        picker.target = self; picker.action = #selector(selected)
        badges.onSelect = { [weak self] id in
            guard let view = self?.marks[id] as? NSView else { return }
            view.scrollToVisible(view.bounds); self?.aiRead.noteVisibilityChanged()
        }
        aiRead.rows = { [weak self] in self?.transcript.rows.compactMap { $0 as? AIReplyRow } ?? [] }
        aiRead.clip = { [weak self] in self?.scroll.contentView.bounds ?? .zero }
        aiRead.isActive = { [weak self] in self?.window?.isKeyWindow == true }
        aiRead.onRead = { [weak self] id in
            guard let record = self?.selectedRecord else { return }
            try? record.controller.markRead(id)
            self?.update()
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.aiRead.noteVisibilityChanged() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private var selectedRecord: AIRecordStore.Record? {
        guard ids.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return store.records[ids[picker.indexOfSelectedItem]]
    }
    func update() {
        warning.stringValue = store.warnings.joined(separator: "\n"); warning.isHidden = store.warnings.isEmpty
        let selectedID = selectedRecord?.manifest.meetingID
        ids = store.records.keys.filter { $0 != current() }.sorted { $0.uuidString < $1.uuidString }
        picker.removeAllItems()
        picker.addItems(withTitles: ids.map { store.records[$0]!.manifest.markdownURL.deletingPathExtension().lastPathComponent })
        if let selectedID, let index = ids.firstIndex(of: selectedID) { picker.selectItem(at: index) }
        selected()
    }
    @objc private func selected() {
        guard let record = selectedRecord else {
            scroll.isHidden = true; badges.isHidden = true; retry.isHidden = true; openPane.isHidden = true
            marks = [:]; displayedMeeting = nil; aiRead.stop(); return
        }
        scroll.isHidden = false
        let changedMeeting = displayedMeeting != record.manifest.meetingID
        // 会議を切り替えたら滞在時間を捨てる。前の会議で見ていた時間を持ち越さない。
        if changedMeeting { marks = [:]; speechRows = [:]; aiRead.reset() }
        displayedMeeting = record.manifest.meetingID
        // 現在の会議と同じ形で枠ごとの状態を渡す。全体の値で塗ると、片方の宛先を
        // 作り直しただけで、もう片方の正常な返事まで「旧接続から」になる。
        let controller = record.controller
        var connections: [Int: AIConnectionStatus] = [:], generations: [Int: Int] = [:]
        var participants: [Int: String] = [:], openablePanes: Set<Int> = []
        for question in controller.conversation.questions {
            let participant = question.request.envelope.participant
            let slot = participant.profileSlot ?? controller.defaultSlot
            connections[slot] = controller.connectionStatus(slot: slot)
            generations[slot] = controller.generation(slot: slot)
            participants[slot] = participant.participantName
            if controller.connection(slot: slot) != nil { openablePanes.insert(slot) }
        }
        var state = AIViewState(conversation: controller.conversation, participant: record.manifest.config.participantName,
            warning: record.saveWarning,
            unconfirmed: Set(controller.conversation.questions.filter { controller.isReturnUnconfirmed($0) }.map { $0.request.id }),
            canSubmit: false, readOnly: true, canOpenPane: controller.connection != nil,
            saveFailed: record.saveWarning != nil, generation: controller.generation,
            defaultSlot: controller.defaultSlot, connections: connections, generations: generations,
            participants: participants, openablePanes: openablePanes)
        state.avatarSources = Dictionary(uniqueKeysWithValues: record.manifest.profiles.compactMap { profile in
            profile.avatar.map { (profile.slot, $0) }
        })
        badges.update(state)
        warning.stringValue = (store.warnings + [record.saveWarning].compactMap { $0 }).joined(separator: "\n")
        warning.isHidden = warning.stringValue.isEmpty
        retry.isHidden = !state.saveFailed
        openPane.isHidden = !state.canOpenPane
        var next: [String: any AITimelineRowView] = [:]
        let anchor = transcript.anchor()
        let meeting = record.archive?.original
        let utterances = record.saveResult?.utterances ?? meeting?.utterances ?? []
        let timeline = meeting?.timeline ?? MeetingTimeline(startedAt: Date(timeIntervalSince1970: 0))
        let items = AITimeline.items(conversation: state.conversation, utterances: utterances,
                                    timeline: timeline,
                                    generation: { state.generation(for: $0) },
                                    connection: { state.connection(for: $0) },
                                    unconfirmed: state.unconfirmed)
        let aiRows = items.map { item -> any DocumentRow in
            let row: any AITimelineRowView
            if let existing = marks[item.rowID] { existing.update(item, state: state); row = existing }
            else {
                switch item.kind {
                case .sendLine: row = AISendLineRow(item: item, state: state)
                case .sendRow: row = AITypedSendRow(item: item, state: state)
                case .reply, .failure: row = AIReplyRow(item: item, state: state)
                }
            }
            if let reply = row as? AIReplyRow {
                reply.updateAvatar(store: avatars)
                reply.onRead = { [weak self, weak record] in
                    try? record?.controller.markRead(item.requestID)
                    self?.update()
                }
                reply.onResize = { [weak self, weak reply] in
                    guard let self, let reply else { return }
                    let y = scroll.contentView.bounds.minY
                    transcript.reflow(anchor: .init(candidates: [(reply, reply.frame.minY - y)], y: y, atBottom: false))
                    // 引用の開閉で行が押し出されても可視域のboundsは変わらないので、ここで直接見る。
                    aiRead.noteVisibilityChanged()
                }
            }
            next[item.rowID] = row; return row
        }
        marks = next
        var rows: [any DocumentRow] = []
        var utteranceRows: [NSView] = []
        var attached: [Int: [any DocumentRow]] = [:]
        for (item, row) in zip(items, aiRows) { attached[item.slot, default: []].append(row) }
        rows.append(contentsOf: attached[-1, default: []])
        for (index, utterance) in utterances.enumerated() {
            let row = speechRows[index] ?? TranscriptRow()
            speechRows[index] = row
            row.update(utterance, names: meeting?.names ?? SpeakerNames(), timeline: timeline)
            rows.append(row)
            rows.append(contentsOf: attached[index, default: []])
            utteranceRows.append(rows.last!)
        }
        transcript.setRows(rows, anchor: changedMeeting ? .init(candidates: [], y: 0, atBottom: false) : anchor)
        speechRows = speechRows.filter { utterances.indices.contains($0.key) }
        let automaticSlot = record.manifest.automaticSlot ?? controller.conversation.questions.last(where: { $0.request.trigger == .scheduled })
            .map { $0.request.envelope.participant.profileSlot ?? controller.defaultSlot }
        transcript.setRangeBoundaries(controller.rangeBoundaries(slot: automaticSlot, utterances: utterances), utteranceRows: utteranceRows)
        aiRead.noteVisibilityChanged()
        aiRead.refresh()
    }
}
