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
    private var displayedMeeting: UUID?
    private let warning = NSTextField(wrappingLabelWithString: "")
    private var ids: [UUID] = []
    init(store: AIRecordStore, current: @escaping () -> UUID?) {
        self.store = store; self.current = current
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "前の会議のAIの返事"; window.isReleasedWhenClosed = false
        super.init(window: window)
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
            guard let view = self?.marks[id] as? NSView else { return }; view.scrollToVisible(view.bounds)
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
            marks = [:]; displayedMeeting = nil; return
        }
        scroll.isHidden = false
        let changedMeeting = displayedMeeting != record.manifest.meetingID
        if changedMeeting { marks = [:] }
        displayedMeeting = record.manifest.meetingID
        let state = AIViewState(conversation: record.controller.conversation, participant: record.manifest.config.participantName,
            warning: record.saveWarning, canSubmit: false, readOnly: true, canOpenPane: record.controller.connection != nil,
            saveFailed: record.saveWarning != nil, generation: record.controller.generation)
        badges.update(state)
        warning.stringValue = (store.warnings + [record.saveWarning].compactMap { $0 }).joined(separator: "\n")
        warning.isHidden = warning.stringValue.isEmpty
        retry.isHidden = !state.saveFailed
        openPane.isHidden = !state.canOpenPane
        var next: [String: any AITimelineRowView] = [:]
        let anchor = transcript.anchor()
        // 旧会議は発話を持たないので、声の送信もアンカーを解決できず日時順の細い1行になる。
        let rows = AITimeline.items(conversation: state.conversation, utterances: [],
                                    timeline: MeetingTimeline(startedAt: Date(timeIntervalSince1970: 0)),
                                    generation: state.generation, connection: state.connection,
                                    unconfirmed: state.unconfirmed).map { item -> any DocumentRow in
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
                reply.onRead = { [weak self, weak record] in
                    try? record?.controller.markRead(item.requestID)
                    self?.update()
                }
                reply.onResize = { [weak self, weak reply] in
                    guard let self, let reply else { return }
                    let y = scroll.contentView.bounds.minY
                    transcript.reflow(anchor: .init(candidates: [(reply, reply.frame.minY - y)], y: y, atBottom: false))
                }
            }
            next[item.rowID] = row; return row
        }
        marks = next
        transcript.setRows(rows, anchor: changedMeeting ? .init(candidates: [], y: 0, atBottom: false) : anchor)
    }
}
