import AppKit
import KikigakiCore

struct AIViewState {
    var conversation: AIConversation?
    var hotkey = ResolvedAIConfig.defaultHotkey
    var participant = "迅雷"
    var connection: AIConnectionStatus = .unknown
    var warning: String?
    var progress: String?
    var unconfirmed: Set<UUID> = []
    var canSubmit = true
    var submissionID: UUID?
    var draft = ""
    var readOnly = false
    var canOpenPane = true
    var canRecreate = false
    var saveFailed = false
    var generation = 1
    var summary: String {
        let questions = conversation?.questions ?? []
        var parts: [String] = []
        if let first = questions.first, let last = questions.last {
            parts.append(first.request.number == last.request.number ? "Q\(first.request.number)" : "Q\(first.request.number)〜Q\(last.request.number)")
        }
        if let progress { parts.append(progress) }
        let confirming = questions.filter { $0.state == .needsInput && $0.answeredByRequestID == nil }.count
        let unread = questions.filter { $0.isUnread && $0.result?.kind != .needsInput }.count
        if unread > 0 { parts.append("未読\(unread)件") }
        if confirming > 0 { parts.append(confirming == 1 ? "確認待ち" : "確認待ち\(confirming)件") }
        if questions.contains(where: \.isAwaitingResult) {
            switch connection {
            case .blocked: parts.append("ペインで確認待ち")
            case .disconnected: parts.append("接続が切れています")
            case .unknown: parts.append("接続を確認中")
            default: parts.append(unconfirmed.isEmpty ? "回答待ち" : "返送未確認")
            }
        } else if questions.contains(where: { $0.state == .prepared }) { parts.append("送信準備中") }
        else if questions.contains(where: { $0.state == .failed }) { parts.append("失敗あり") }
        else if questions.allSatisfy({ $0.state == .cancelled }), !questions.isEmpty { parts.append("取消済み") }
        if let warning { parts.append(warning) }
        if parts.isEmpty { return "まだ質問はありません" }
        if parts.count == 1, !questions.isEmpty { parts.append("既読") }
        return parts.joined(separator: " · ")
    }
    var shortcut: String {
        [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
            .filter { hotkey.modifiers.contains($0.0) }.map(\.1).joined() + hotkey.key.uppercased()
    }
}

final class AIMarkRow: NSView, DocumentRow {
    let title: String
    let date: Date
    init(title: String, date: Date) { self.title = title; self.date = date; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    func height(for width: CGFloat) -> CGFloat { 28 }
    override func draw(_ dirtyRect: NSRect) {
        Washi.muted.setFill(); NSRect(x: 56, y: 7, width: 1, height: 14).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Washi.muted]
        (title as NSString).draw(in: NSRect(x: 68, y: 7, width: max(0, bounds.width - 166), height: 16), withAttributes: attributes)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm:ss"
        (formatter.string(from: date) as NSString).draw(at: NSPoint(x: bounds.width - 80, y: 7), withAttributes: attributes)
    }
}

final class AIActionButton: NSButton {
    var callback: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        callback = action; super.init(frame: .zero); self.title = title
        isBordered = false; font = .systemFont(ofSize: 11); contentTintColor = Washi.ink
        alignment = .left
        target = self; self.action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { callback?() }
}

/// テキストとビューを保持し、後着acceptや既読操作だけで本文の選択を消さない。
private final class AIAnswerCard: NSView, DocumentRow {
    var readOnly = false
    var canOpenPane = true
    var generation = 1
    var onRead: (() -> Void)?
    var onReply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPane: (() -> Void)?
    var onResize: (() -> Void)?
    private var question: AIQuestion
    private let heading = Washi.label(size: 11, color: Washi.muted)
    private let time = Washi.label(size: 11, color: Washi.muted)
    private let body = NSTextField(wrappingLabelWithString: "")
    private var expanded = false
    private lazy var more = AIActionButton("全文を読む ▾") { [weak self] in
        guard let self else { return }; expanded.toggle(); onResize?(); if expanded { onRead?() }
    }
    private lazy var read = AIActionButton("既読にする") { [weak self] in self?.onRead?() }
    private lazy var reply = AIActionButton("返答する") { [weak self] in self?.onReply?() }
    private lazy var cancel = AIActionButton("取消") { [weak self] in self?.onCancel?() }
    private lazy var pane = AIActionButton("ペインを開く") { [weak self] in self?.onPane?() }
    private var measuredBody: CGFloat = 0
    private var needsMore = false
    private var confirming: Bool { question.state == .needsInput && question.answeredByRequestID == nil }
    override var isFlipped: Bool { true }
    init(_ question: AIQuestion) {
        self.question = question; super.init(frame: .zero)
        for view in [heading, time, body, more, read, reply, cancel, pane] { addSubview(view) }
        heading.lineBreakMode = .byTruncatingTail; heading.maximumNumberOfLines = 1
        body.isSelectable = true; update(question)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: AIQuestion) {
        question = value
        var notes: [String] = []
        if value.result != nil, value.cancelledAt != nil { notes.append("取消後の回答") }
        if value.result != nil, value.request.envelope.participant.sessionGeneration < generation { notes.append("旧接続からの回答") }
        if value.answeredByRequestID != nil { notes.append("返答済み") }
        heading.stringValue = (["Q\(value.request.number)"] + notes + [value.request.displayQuestion.replacingOccurrences(of: "\n", with: " ")]).joined(separator: "  ")
        heading.toolTip = heading.stringValue
        let format = DateFormatter(); format.dateFormat = "HH:mm:ss"
        time.stringValue = (value.resultReceivedAt ?? value.sendAttemptedAt).map { format.string(from: $0) } ?? ""
        let text: String
        if let result = value.result { text = (confirming ? "? " : "") + (result.body ?? "") }
        else if value.state == .cancelled { text = "取り消しました" }
        else if let failure = value.failure { text = failure }
        else if value.sendAttemptedAt == nil { text = "送信準備中です" }
        else { text = "送信済み · 回答を待っています" }
        if body.stringValue != text { body.stringValue = text }
        body.font = .systemFont(ofSize: value.result == nil ? 12 : 15)
        body.textColor = value.result == nil ? Washi.tentative : Washi.ink
        needsDisplay = true; needsLayout = true
    }
    func height(for width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let height = (body.stringValue as NSString).boundingRect(with: NSSize(width: max(40, width - 34), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: body.font!, .paragraphStyle: paragraph]).height
        // 行数と実際の折返しから判定し、120字以下でも隠れる本文への導線を残す。
        needsMore = height > 55 || body.stringValue.count > 120
        measuredBody = expanded ? ceil(height) + 4 : min(58, ceil(height) + 4)
        return max(100, 65 + measuredBody) + 8
    }
    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 14, y: 10, width: max(0, bounds.width - 108), height: 17)
        time.frame = NSRect(x: bounds.width - 78, y: 10, width: 70, height: 17)
        body.maximumNumberOfLines = expanded ? 0 : 3
        body.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        body.frame = NSRect(x: 14, y: 35, width: max(0, bounds.width - 28), height: measuredBody)
        let y = bounds.height - 33
        more.isHidden = !needsMore || question.result == nil
        more.title = expanded ? "閉じる ▴" : "全文を読む ▾"
        read.isHidden = !question.isUnread
        cancel.isHidden = readOnly || question.result != nil || question.state == .cancelled || question.state == .failed
        reply.isHidden = readOnly || !confirming
        pane.isHidden = !canOpenPane
        for view in [more, read, cancel] { view.frame = NSRect(x: 12, y: y, width: 102, height: 20) }
        if !more.isHidden { read.frame.origin.x = 245 }
        pane.frame = NSRect(x: 125, y: y, width: 110, height: 20)
        reply.frame = NSRect(x: bounds.width - 95, y: y, width: 83, height: 20)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1); let card = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 8), xRadius: 6, yRadius: 6)
        Washi.shade.setFill(); card.fill()
        if question.result == nil && question.state != .cancelled && question.state != .failed {
            Washi.muted.setStroke(); card.setLineDash([3, 3], count: 2, phase: 0); card.lineWidth = 0.7; card.stroke()
        } else if confirming || question.isUnread {
            (confirming ? Washi.color(0xC4801F) : Washi.red).setFill()
            NSRect(x: 0, y: 6, width: 3, height: max(0, bounds.height - 20)).fill()
        }
    }
}

@MainActor
final class AIPanel: NSStackView {
    var onReply: ((UUID) -> Void)?
    var onRead: ((UUID) -> Void)?
    var onPane: (() -> Void)?
    var onCancel: ((UUID) -> Void)?
    var onReconnect: (() -> Void)?
    var onRetrySave: (() -> Void)?
    var onWillToggle: (() -> Void)?
    var onDidToggle: (() -> Void)?
    private let toggle = NSButton(title: "", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let document = TranscriptDocument()
    private lazy var reconnect = AIActionButton("AIセッションを作り直す") { [weak self] in self?.onReconnect?() }
    private lazy var retrySave = AIActionButton("保存を再試行") { [weak self] in self?.onRetrySave?() }
    private var cards: [UUID: AIAnswerCard] = [:]
    private var expanded = false
    private var state = AIViewState()
    private var preferredHeight: NSLayoutConstraint?
    init() {
        super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 4
        edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        toggle.isBordered = false; toggle.alignment = .left; toggle.font = .systemFont(ofSize: 12, weight: .medium)
        toggle.target = self; toggle.action = #selector(toggled)
        for view in [toggle, scroll] { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true }
        toggle.heightAnchor.constraint(equalToConstant: 24).isActive = true
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = document
        document.autoresizingMask = [.width]; document.followsBottom = false
        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        let preferred = scroll.heightAnchor.constraint(equalToConstant: 140); preferred.priority = .defaultHigh; preferred.isActive = true
        preferredHeight = preferred
        scroll.isHidden = true
        addArrangedSubview(reconnect); reconnect.isHidden = true
        addArrangedSubview(retrySave); retrySave.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: AIViewState, newMeeting: Bool) {
        let changedMeeting = newMeeting || state.conversation?.meetingID != value.conversation?.meetingID
        if changedMeeting { expanded = false; cards = [:] }
        state = value; updateHeading()
        reconnect.isHidden = !value.canRecreate
        retrySave.isHidden = !value.saveFailed
        let anchor = document.anchor()
        var next: [UUID: AIAnswerCard] = [:]
        let ordered = (value.conversation?.questions ?? []).map { question -> any DocumentRow in
            let id = question.request.id
            let card = cards[id] ?? AIAnswerCard(question)
            card.readOnly = value.readOnly; card.canOpenPane = value.canOpenPane
            card.generation = value.generation
            card.update(question)
            card.onReply = { [weak self] in self?.onReply?(id) }; card.onRead = { [weak self] in self?.onRead?(id) }
            card.onCancel = { [weak self] in self?.onCancel?(id) }; card.onPane = { [weak self] in self?.onPane?() }
            card.onResize = { [weak self] in guard let self else { return }; fitHeight(); document.reflow(anchor: document.anchor()) }
            next[id] = card; return card
        }
        cards = next; document.setRows(ordered, anchor: changedMeeting ? .init(candidates: [], y: 0, atBottom: false) : anchor)
        fitHeight()
    }
    private func fitHeight() {
        let width = max(100, bounds.width - 32)
        preferredHeight?.constant = min(140, document.rows.reduce(16) { $0 + $1.height(for: width) })
    }
    private func updateHeading() { toggle.title = "\(expanded ? "▾" : "▸") AIとのやりとり   " + state.summary; toggle.toolTip = state.summary; scroll.isHidden = !expanded }
    @objc private func toggled() {
        onWillToggle?(); expanded.toggle(); updateHeading(); fitHeight()
        onDidToggle?(); document.reflow(anchor: document.anchor())
    }
}
