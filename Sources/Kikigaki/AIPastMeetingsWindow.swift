import AppKit

@MainActor final class AIPastMeetingsWindow: NSWindowController {
    private let store: AIRecordStore
    private let current: () -> UUID?
    private let picker = NSPopUpButton()
    private let panel = AIPanel()
    private var ids: [UUID] = []
    init(store: AIRecordStore, current: @escaping () -> UUID?) {
        self.store = store; self.current = current
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 280), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "前の会議のAI回答"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView(views: [picker, panel]); stack.orientation = .vertical; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [picker, panel] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        window.contentView = stack; window.backgroundColor = Washi.paper
        picker.target = self; picker.action = #selector(selected)
        panel.onRead = { [weak self] id in
            guard let self, let record = selectedRecord else { return }
            try? record.controller.markRead(id)
        }
        panel.onPane = { [weak self] in
            guard let self, let record = selectedRecord else { return }
            Task { try? await record.controller.showPane() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private var selectedRecord: AIRecordStore.Record? {
        guard ids.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return store.records[ids[picker.indexOfSelectedItem]]
    }
    func update() {
        let selectedID = selectedRecord?.manifest.meetingID
        ids = store.records.keys.filter { $0 != current() }.sorted { $0.uuidString < $1.uuidString }
        picker.removeAllItems()
        picker.addItems(withTitles: ids.map { store.records[$0]!.manifest.markdownURL.deletingPathExtension().lastPathComponent })
        if let selectedID, let index = ids.firstIndex(of: selectedID) { picker.selectItem(at: index) }
        selected()
    }
    @objc private func selected() {
        guard let record = selectedRecord else { panel.isHidden = true; return }
        panel.isHidden = false
        panel.update(AIViewState(conversation: record.controller.conversation, participant: record.manifest.config.participantName,
            warning: record.saveWarning, canSubmit: false), newMeeting: false)
    }
}
