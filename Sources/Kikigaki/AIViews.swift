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
    var badges: String {
        let questions = conversation?.questions ?? []
        let counts = [
            ("未読", questions.filter { $0.isUnread && $0.result?.kind != .needsInput }.count),
            ("確認待ち", questions.filter { $0.state == .needsInput && $0.answeredByRequestID == nil }.count),
            ("回答待ち", questions.filter { $0.isAwaitingResult && $0.state != .deliveryUnknown }.count),
            ("送達不明", questions.filter { $0.state == .deliveryUnknown }.count),
            ("失敗", questions.filter { $0.state == .failed }.count)
        ]
        return counts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
    var shortcut: String {
        [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
            .filter { hotkey.modifiers.contains($0.0) }.map(\.1).joined() + hotkey.key.uppercased()
    }
}

/// 表示上の印。同じrequestの質問と結果を別の行として保持する。
struct AIInlineMark {
    enum Kind { case question, result }
    let question: AIQuestion
    let kind: Kind
    var id: String { question.request.id.uuidString + (kind == .question ? "/send" : "/result") }
    var date: Date {
        kind == .question ? question.sendAttemptedAt ?? question.request.envelope.participant.capturedAt
            : question.resultReceivedAt ?? question.request.envelope.participant.capturedAt
    }
    var title: String {
        let prefix = "Q\(question.request.number) " + question.request.envelope.participant.participantName
        if kind == .question { return prefix + "へ質問" + (question.state == .deliveryUnknown ? "・送達不明" : "") }
        return prefix + (question.result?.kind == .needsInput ? "の確認" : question.result?.kind == .failed ? "の失敗報告" : "の回答")
    }
    static func ordered(_ conversation: AIConversation?) -> [Self] {
        (conversation?.questions ?? []).flatMap { question -> [Self] in
            var marks = [Self(question: question, kind: .question)]
            if question.resultReceivedAt != nil { marks.append(Self(question: question, kind: .result)) }
            return marks
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.kind != $1.kind { return $0.kind == .question }
            return ($0.kind == .question ? $0.question.request.number : $0.question.resultOrder ?? 0)
                < ($1.kind == .question ? $1.question.request.number : $1.question.resultOrder ?? 0)
        }
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

/// 印そのものを開く。行を再利用するので、発話追加・既読・改名の更新で展開や本文選択を失わない。
final class AIMarkRow: NSView, DocumentRow {
    enum Accent { case muted, unread, confirmation }
    private(set) var mark: AIInlineMark
    private(set) var expanded = false
    private var state: AIViewState
    var title: String { mark.title }
    var date: Date { mark.date }
    var onRead: (() -> Void)?
    var onReply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPane: (() -> Void)?
    var onToggle: (() -> Void)?
    private let body = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private lazy var toggle = AIActionButton("") { [weak self] in self?.toggleExpanded() }
    private lazy var reply = AIActionButton("返答する") { [weak self] in self?.onReply?() }
    private lazy var cancel = AIActionButton("取消") { [weak self] in self?.onCancel?() }
    private lazy var pane = AIActionButton("ペインを開く") { [weak self] in self?.onPane?() }
    private var measuredBody: CGFloat = 0
    private var measuredDetail: CGFloat = 0
    private var confirming: Bool { mark.question.state == .needsInput && mark.question.answeredByRequestID == nil }
    var accent: Accent {
        guard mark.kind == .result else { return .muted }
        if mark.question.result?.kind == .needsInput { return confirming ? .confirmation : .muted }
        return mark.question.isUnread ? .unread : .muted
    }
    var accentColor: NSColor {
        switch accent {
        case .muted: return Washi.muted
        case .unread: return Washi.red
        case .confirmation: return Washi.color(0xC4801F)
        }
    }
    override var isFlipped: Bool { true }
    init(mark: AIInlineMark, state: AIViewState) {
        self.mark = mark; self.state = state; super.init(frame: .zero)
        for view in [toggle, body, detail, reply, cancel, pane] { addSubview(view) }
        body.isSelectable = true; detail.isSelectable = true
        body.maximumNumberOfLines = 0; detail.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping; detail.lineBreakMode = .byWordWrapping
        update(mark, state: state)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ mark: AIInlineMark, state: AIViewState) {
        self.mark = mark; self.state = state
        let question = mark.question
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let text = mark.kind == .question ? question.request.displayQuestion
            : (question.result?.kind == .needsInput ? "? " : "") + (question.result?.body ?? "")
        if body.stringValue != text {
            body.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: Washi.ink, .paragraphStyle: paragraph
            ])
        }
        var notes: [String] = []
        if mark.kind == .question {
            let envelope = question.request.envelope
            let time = question.request.timeRange.map { " · \($0.start)〜\($0.end)" } ?? ""
            notes.append("対象: \(envelope.readLineCount)発言" + time
                + (envelope.participant.tentativeTail == nil ? "" : " · 暫定末尾を含む"))
            notes.append("作業許可: " + (envelope.participant.workAllowed ? "あり" : "なし"))
            let status: String
            switch question.state {
            case .prepared: status = "送信準備中"
            case .deliveryUnknown: status = "送達不明"
            case .cancelled: status = "取消"
            case .failed: status = "失敗" + ((question.failure ?? question.result?.body).map { " · " + $0 } ?? "")
            case .needsInput: status = confirming ? "確認待ち" : "返答済み"
            case .answered: status = "回答済み"
            case .submitted, .accepted:
                if state.connection == .blocked { status = "回答待ち · ペインで確認してください" }
                else if state.connection == .disconnected { status = "回答待ち · 接続が切れています" }
                else if state.unconfirmed.contains(question.request.id) { status = "回答待ち · 返送未確認" }
                else { status = "送信済み · 回答を待っています" }
            }
            notes.append(status)
        } else {
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
            notes.append("到着: " + formatter.string(from: date))
            if question.cancelledAt != nil { notes.append("取消後の回答") }
            if question.request.envelope.participant.sessionGeneration < state.generation { notes.append("旧接続からの回答") }
            if question.answeredByRequestID != nil { notes.append("返答済み") }
        }
        let details = notes.joined(separator: "\n")
        if detail.stringValue != details {
            detail.attributedStringValue = NSAttributedString(string: details, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Washi.muted, .paragraphStyle: paragraph
            ])
        }
        updateVisibility()
        needsDisplay = true; needsLayout = true
    }
    func toggleExpanded() {
        expanded.toggle()
        updateVisibility()
        // 先に行高を変え、既読保存が同期でapplyを呼んでも同じ行と展開状態を保つ。
        onToggle?()
        if expanded && mark.kind == .result && mark.question.isUnread { onRead?() }
    }
    private func updateVisibility() {
        toggle.title = (expanded ? "▾ " : "▸ ") + title
        toggle.contentTintColor = Washi.muted
        toggle.setAccessibilityLabel(title + (expanded ? "、折りたたむ" : "、展開する"))
        toggle.toolTip = title
        body.isHidden = !expanded; detail.isHidden = !expanded
        reply.isHidden = !expanded || mark.kind != .result || !confirming || state.readOnly
        cancel.isHidden = !expanded || mark.kind != .question || !mark.question.isAwaitingResult || state.readOnly
        pane.isHidden = !expanded || !state.canOpenPane
        needsLayout = true; needsDisplay = true
    }
    func height(for width: CGFloat) -> CGFloat {
        guard expanded else { return 28 }
        let bounds = NSRect(x: 0, y: 0, width: max(44, width - 90), height: .greatestFiniteMagnitude)
        measuredBody = ceil(body.cell?.cellSize(forBounds: bounds).height ?? 0)
        measuredDetail = ceil(detail.cell?.cellSize(forBounds: bounds).height ?? 0)
        let actions = [reply, cancel, pane].contains { !$0.isHidden } ? 30.0 : 0
        return 36 + measuredBody + 10 + measuredDetail + actions + 12
    }
    override func layout() {
        super.layout()
        toggle.frame = NSRect(x: 64, y: 2, width: max(0, bounds.width - 158), height: 24)
        body.frame = NSRect(x: 68, y: 36, width: max(44, bounds.width - 90), height: measuredBody)
        detail.frame = NSRect(x: 68, y: body.frame.maxY + 10, width: body.frame.width, height: measuredDetail)
        var x: CGFloat = 68
        for button in [reply, cancel, pane] where !button.isHidden {
            button.frame = NSRect(x: x, y: detail.frame.maxY + 8, width: 100, height: 22); x += 112
        }
    }
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y < 28 { toggleExpanded() }
        else { super.mouseDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        accentColor.setFill()
        NSRect(x: 56, y: 7, width: 1, height: expanded ? max(14, bounds.height - 19) : 14).fill()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm:ss"
        (formatter.string(from: date) as NSString).draw(at: NSPoint(x: bounds.width - 80, y: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Washi.muted
        ])
    }
}
