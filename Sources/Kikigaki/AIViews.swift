import AppKit
import KikigakiCore

enum AINoticeTone {
    case normal, warning
    var color: NSColor { self == .warning ? Washi.gold : Washi.muted }
}

enum AIBadgeKind: String, CaseIterable {
    case unread = "未読", confirmation = "確認待ち", waiting = "返事待ち", unknown = "送達不明", failed = "失敗"
    func matches(_ question: AIQuestion) -> Bool {
        switch self {
        case .unread: return question.isUnread && question.result?.kind != .needsInput
        case .confirmation: return question.state == .needsInput && question.answeredByRequestID == nil
        case .waiting: return question.isAwaitingResult && question.state != .deliveryUnknown
        case .unknown: return question.state == .deliveryUnknown
        case .failed: return question.state == .failed
        }
    }
    func markID(_ question: AIQuestion) -> String {
        question.request.id.uuidString + ((self == .unread || self == .confirmation || (self == .failed && question.result != nil)) ? "/result" : "/send")
    }
}

final class AIBadgeButton: NSButton {
    let kind: AIBadgeKind?
    var callback: (() -> Void)?
    init(_ title: String, kind: AIBadgeKind? = nil, action: @escaping () -> Void) {
        self.kind = kind; callback = action
        super.init(frame: .zero); self.title = title
        isBordered = false; font = .systemFont(ofSize: 11, weight: .bold)
        target = self; self.action = #selector(pressed)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 16, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = kind == .confirmation ? Washi.color(0xC4801F) : kind == .unread || kind == .failed ? Washi.red : Washi.muted
        let filled = kind == .unread || kind == .confirmation || kind == nil
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 6, yRadius: 6)
        if filled { (kind == nil ? Washi.rule : color).setFill(); pill.fill() }
        else { color.setStroke(); pill.lineWidth = 1; pill.stroke() }
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: filled && kind != nil ? NSColor.white : color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    @objc private func pressed() { callback?() }
}

final class AIBadgeBar: NSStackView {
    var onSelect: ((String) -> Void)?
    private var buttons: [AIBadgeKind: AIBadgeButton] = [:]
    init() {
        super.init(frame: .zero); orientation = .horizontal; alignment = .centerY; spacing = 6
        for kind in AIBadgeKind.allCases {
            let button = AIBadgeButton(kind.rawValue, kind: kind, action: {})
            buttons[kind] = button; addArrangedSubview(button); button.isHidden = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ state: AIViewState?) {
        let questions = state?.conversation?.questions ?? []
        for kind in AIBadgeKind.allCases {
            let matching = questions.filter(kind.matches), button = buttons[kind]!
            button.isHidden = matching.isEmpty
            button.title = "\(kind.rawValue) \(matching.count)"; button.invalidateIntrinsicContentSize(); button.needsDisplay = true
            button.setAccessibilityLabel(button.title + "、最初の印へ移動")
            let firstMark = AIInlineMark.ordered(state?.conversation).first { kind.matches($0.question) && $0.id == kind.markID($0.question) }
            button.callback = { [weak self] in if let firstMark { self?.onSelect?(firstMark.id) } }
        }
        isHidden = buttons.values.allSatisfy { $0.isHidden }
    }
}

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
    /// 会議で使えるプロファイル。宛先ポップアップの並び
    var profiles: [(slot: Int, name: String)] = []
    var selectedSlot = 1
    /// プロファイル未指定の旧requestが属する枠
    var defaultSlot = 1
    /// 枠ごとの接続状態と現世代。印は自分を送った枠のものを見る
    var connections: [Int: AIConnectionStatus] = [:]
    var generations: [Int: Int] = [:]
    /// 枠ごとの送信可否と進捗。確認への返答シートは親の枠のものを見る
    var canSubmits: [Int: Bool] = [:]
    var progresses: [Int: String] = [:]
    var participants: [Int: String] = [:]
    var openablePanes: Set<Int> = []
    func canSubmit(slot: Int) -> Bool { canSubmits[slot] ?? canSubmit }
    func progress(slot: Int) -> String? { progresses[slot] ?? (slot == selectedSlot ? progress : nil) }
    func participant(slot: Int) -> String { participants[slot] ?? participant }
    func canOpenPane(slot: Int) -> Bool { participants[slot] == nil ? canOpenPane : openablePanes.contains(slot) }
    func slot(of request: AIRequest) -> Int { request.envelope.participant.profileSlot ?? defaultSlot }
    func connection(for request: AIRequest) -> AIConnectionStatus { connections[slot(of: request)] ?? connection }
    func generation(for request: AIRequest) -> Int { generations[slot(of: request)] ?? generation }
    var noticeTone: AINoticeTone { warning == nil ? .normal : .warning }
    var badges: String {
        let questions = conversation?.questions ?? []
        let counts = AIBadgeKind.allCases.map { kind in (kind.rawValue, questions.filter(kind.matches).count) }
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
    var parentNumber: Int? = nil
    var id: String { question.request.id.uuidString + (kind == .question ? "/send" : "/result") }
    var date: Date {
        kind == .question ? question.sendAttemptedAt ?? question.request.envelope.participant.capturedAt
            : question.resultReceivedAt ?? question.request.envelope.participant.capturedAt
    }
    var title: String {
        let prefix = "#\(question.request.number) " + question.request.envelope.participant.participantName
        if kind == .question {
            let label = parentNumber.map { "#\(question.request.number) #\($0)への返答" } ?? prefix + "へ"
            return label + question.request.automaticLabel + (question.state == .deliveryUnknown ? " · 送達不明" : "")
        }
        return prefix + (question.result?.kind == .needsInput ? "の確認" : question.result?.kind == .failed ? "の失敗報告" : "から") + question.request.automaticLabel
    }
    var excerpt: String {
        if kind == .result { return question.result?.body?.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "" }
        if question.request.trigger == .scheduled { return "対象: \(question.request.envelope.readLineCount)発言" }
        return parentNumber != nil || question.request.envelope.participant.questionSource == .typed
            ? question.request.displayQuestion.components(separatedBy: .newlines).joined(separator: " ") : ""
    }
    static func ordered(_ conversation: AIConversation?) -> [Self] {
        (conversation?.questions ?? []).flatMap { question -> [Self] in
            let parent = conversation?.questions.first { $0.request.id == question.request.envelope.participant.inReplyToRequestID }?.request.number
            var marks = [Self(question: question, kind: .question, parentNumber: parent)]
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
    private let markdownBody = MarkdownBodyView()
    private let confirmationMark = Washi.label("?", size: 15, color: Washi.muted)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let questionText = NSTextField(wrappingLabelWithString: "")
    private lazy var toggle = AIActionButton("") { [weak self] in self?.toggleExpanded() }
    private lazy var reply = AIActionButton("返答する") { [weak self] in self?.onReply?() }
    private lazy var cancel = AIActionButton("取消") { [weak self] in self?.onCancel?() }
    private lazy var pane = AIActionButton("ペインを開く") { [weak self] in self?.onPane?() }
    private var measuredBody: CGFloat = 0
    private var measuredDetail: CGFloat = 0
    private var measuredQuestion: CGFloat = 0
    private var confirming: Bool { mark.question.state == .needsInput && mark.question.answeredByRequestID == nil }
    var accent: Accent {
        guard mark.kind == .result else { return .muted }
        if mark.question.result?.kind == .needsInput { return confirming && mark.question.isUnread ? .confirmation : .muted }
        return mark.question.isUnread ? .unread : .muted
    }
    var accentColor: NSColor {
        switch accent {
        case .muted: return Washi.muted
        case .unread: return Washi.red
        case .confirmation: return Washi.color(0xC4801F)
        }
    }
    var statusPill: String? {
        switch accent {
        case .unread: return "未読"
        case .confirmation: return "確認待ち"
        case .muted: return nil
        }
    }
    private var pillWidth: CGFloat {
        guard let statusPill else { return 0 }
        return ceil((statusPill as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]).width) + 12
    }
    override var isFlipped: Bool { true }
    init(mark: AIInlineMark, state: AIViewState) {
        self.mark = mark; self.state = state; super.init(frame: .zero)
        for view in [toggle, questionText, body, markdownBody, confirmationMark, detail, reply, cancel, pane] { addSubview(view) }
        toggle.cell?.lineBreakMode = .byTruncatingTail
        questionText.isSelectable = true; questionText.maximumNumberOfLines = 0
        questionText.lineBreakMode = .byWordWrapping
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
        let originalQuestion = "送信文: " + question.request.displayQuestion
        if questionText.stringValue != originalQuestion {
            questionText.attributedStringValue = NSAttributedString(string: originalQuestion, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Washi.muted, .paragraphStyle: paragraph
            ])
        }
        if mark.kind == .result {
            markdownBody.update(question.result?.body ?? "")
        } else if body.stringValue != question.request.displayQuestion {
            body.attributedStringValue = NSAttributedString(string: question.request.displayQuestion, attributes: [
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
            case .answered: status = "返事済み"
            case .submitted, .accepted:
                // 接続状態はこの質問を送った枠のものを見る。別の宛先の切断を混ぜない。
                let connection = state.connection(for: question.request)
                if connection == .blocked { status = "返事待ち · ペインで確認してください" }
                else if connection == .disconnected { status = "返事待ち · 接続が切れています" }
                else if state.unconfirmed.contains(question.request.id) { status = "返事待ち · 返送未確認" }
                else { status = "送信済み · 返事を待っています" }
            }
            notes.append(status)
        } else {
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
            notes.append("到着: " + formatter.string(from: date))
            if question.cancelledAt != nil { notes.append("取消後の返事") }
            if question.request.envelope.participant.sessionGeneration < state.generation(for: question.request) {
                notes.append("旧接続からの返事")
            }
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
        let excerpt = mark.excerpt.isEmpty ? "" : " · " + mark.excerpt
        let heading = (expanded ? "▾ " : "▸ ") + title
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let label = NSMutableAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: accent == .muted ? .regular : .bold),
            .foregroundColor: accentColor, .paragraphStyle: paragraph
        ])
        label.append(NSAttributedString(string: excerpt, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Washi.muted, .paragraphStyle: paragraph
        ]))
        toggle.contentTintColor = nil
        toggle.attributedTitle = label
        toggle.setAccessibilityLabel(title + (statusPill.map { "、" + $0 } ?? "") + (expanded ? "、折りたたむ" : "、展開する"))
        toggle.toolTip = title + excerpt
        questionText.isHidden = !expanded || mark.kind != .result
        body.isHidden = !expanded || mark.kind == .result
        markdownBody.isHidden = !expanded || mark.kind != .result
        confirmationMark.isHidden = !expanded || mark.kind != .result || mark.question.result?.kind != .needsInput
        detail.isHidden = !expanded
        reply.isHidden = !expanded || mark.kind != .result || !confirming || state.readOnly
        cancel.isHidden = !expanded || mark.kind != .question || !mark.question.isAwaitingResult || state.readOnly
        pane.isHidden = !expanded || !state.canOpenPane
        needsLayout = true; needsDisplay = true
    }
    func height(for width: CGFloat) -> CGFloat {
        guard expanded else { return 28 }
        let bounds = NSRect(x: 0, y: 0, width: max(44, width - 90), height: .greatestFiniteMagnitude)
        measuredBody = mark.kind == .result ? markdownBody.height(for: bounds.width)
            : ceil(body.cell?.cellSize(forBounds: bounds).height ?? 0)
        measuredDetail = ceil(detail.cell?.cellSize(forBounds: bounds).height ?? 0)
        measuredQuestion = mark.kind == .result ? ceil(questionText.cell?.cellSize(forBounds: bounds).height ?? 0) + 10 : 0
        let actions = [reply, cancel, pane].contains { !$0.isHidden } ? 30.0 : 0
        return 36 + measuredQuestion + measuredBody + 10 + measuredDetail + actions + 12
    }
    override func layout() {
        super.layout()
        toggle.frame = NSRect(x: 64, y: 2, width: max(0, bounds.width - 158 - (statusPill == nil ? 0 : pillWidth + 8)), height: 24)
        questionText.frame = NSRect(x: 68, y: 36, width: max(44, bounds.width - 90), height: max(0, measuredQuestion - 10))
        body.frame = NSRect(x: 68, y: 36 + measuredQuestion, width: max(44, bounds.width - 90), height: measuredBody)
        markdownBody.frame = body.frame
        confirmationMark.frame = NSRect(x: 60, y: body.frame.minY + 2, width: 10, height: 20)
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
        if accent != .muted {
            accentColor.withAlphaComponent(0.11).setFill(); bounds.fill()
        }
        accentColor.setFill()
        NSRect(x: 56, y: 7, width: 1, height: expanded ? max(14, bounds.height - 19) : 14).fill()
        if let statusPill {
            let pill = NSRect(x: bounds.width - 88 - pillWidth, y: 3, width: pillWidth, height: 22)
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            (statusPill as NSString).draw(at: NSPoint(x: pill.minX + 6, y: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white
            ])
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm:ss"
        (formatter.string(from: date) as NSString).draw(at: NSPoint(x: bounds.width - 80, y: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Washi.muted
        ])
    }
}
