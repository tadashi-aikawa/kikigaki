import AppKit

@MainActor final class AIPastMeetingsWindow: NSWindowController {
    private let store: AIRecordStore
    private let current: () -> UUID?
    private let picker = NSPopUpButton()
    private let scroll = NSScrollView()
    private let transcript = TranscriptDocument()
    private let badges = Washi.label(size: 11, color: Washi.muted)
    private lazy var retry = AIActionButton("保存を再試行") { [weak self] in self?.store.retrySaves(); self?.update() }
    private var marks: [String: AIMarkRow] = [:]
    private var displayedMeeting: UUID?
    private let warning = NSTextField(wrappingLabelWithString: "")
    private var ids: [UUID] = []
    init(store: AIRecordStore, current: @escaping () -> UUID?) {
        self.store = store; self.current = current
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "前の会議のAI回答"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView(views: [picker, warning, badges, retry, scroll]); stack.orientation = .vertical; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [picker, warning, badges, retry, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        scroll.documentView = transcript; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        transcript.autoresizingMask = [.width]; transcript.followsBottom = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        window.contentView = stack; window.backgroundColor = Washi.paper
        picker.target = self; picker.action = #selector(selected)
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
            scroll.isHidden = true; badges.isHidden = true; retry.isHidden = true
            marks = [:]; displayedMeeting = nil; return
        }
        scroll.isHidden = false
        let changedMeeting = displayedMeeting != record.manifest.meetingID
        if changedMeeting { marks = [:] }
        displayedMeeting = record.manifest.meetingID
        let state = AIViewState(conversation: record.controller.conversation, participant: record.manifest.config.participantName,
            warning: record.saveWarning, canSubmit: false, readOnly: true, canOpenPane: record.controller.connection != nil,
            saveFailed: record.saveWarning != nil, generation: record.controller.generation)
        badges.stringValue = state.badges; badges.isHidden = state.badges.isEmpty
        warning.stringValue = (store.warnings + [record.saveWarning].compactMap { $0 }).joined(separator: "\n")
        warning.isHidden = warning.stringValue.isEmpty
        retry.isHidden = !state.saveFailed
        var next: [String: AIMarkRow] = [:]
        let anchor = transcript.anchor()
        let rows = AIInlineMark.ordered(state.conversation).map { mark -> any DocumentRow in
            let row = marks[mark.id] ?? AIMarkRow(mark: mark, state: state)
            row.update(mark, state: state)
            row.onRead = { [weak self, weak record] in
                try? record?.controller.markRead(mark.question.request.id)
                self?.update()
            }
            row.onPane = { [weak record] in Task { try? await record?.controller.showPane() } }
            row.onToggle = { [weak self, weak row] in
                guard let self, let row else { return }
                let y = scroll.contentView.bounds.minY
                transcript.reflow(anchor: .init(candidates: [(row, row.frame.minY - y)], y: y, atBottom: false))
            }
            next[mark.id] = row; return row
        }
        marks = next
        transcript.setRows(rows, anchor: changedMeeting ? .init(candidates: [], y: 0, atBottom: false) : anchor)
    }
}
