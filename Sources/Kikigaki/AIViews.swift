import AppKit
import KikigakiCore

enum AINoticeTone {
    case normal, warning
    var color: NSColor { self == .warning ? Washi.gold : Washi.muted }
}

enum AIBadgeKind: String, CaseIterable {
    case unread = "未読", confirmation = "確認待ち", waiting = "返事待ち", unknown = "送達不明", failed = "失敗"
    /// 確認待ちの判定に会話全体が要る。失敗・取消で終わった返答は返答済みと数えないため。
    func matches(_ question: AIQuestion, in questions: [AIQuestion]) -> Bool {
        switch self {
        case .unread: return question.isUnread && question.result?.kind != .needsInput
        case .confirmation: return question.state == .needsInput && !AIQuestion.isAnswered(question, in: questions)
        case .waiting: return question.isAwaitingResult && question.state != .deliveryUnknown
        case .unknown: return question.state == .deliveryUnknown
        case .failed: return question.state == .failed
        }
    }
    /// 移動先の行ID。送達不明は送信の行の注記なので送信側、それ以外はAIの行を指す。
    func rowID(_ question: AIQuestion) -> String {
        question.request.id.uuidString + (self == .unknown ? "/send" : "/reply")
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
        // 金地に白は3.25:1しかない。塗りの色に応じて読める方の文字色を選ぶ。
        let text = filled && kind != nil ? (kind == .confirmation ? Washi.ink : NSColor.white) : color
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: text]
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
            let matching = questions.filter { kind.matches($0, in: questions) }, button = buttons[kind]!
            button.isHidden = matching.isEmpty
            button.title = "\(kind.rawValue) \(matching.count)"; button.invalidateIntrinsicContentSize(); button.needsDisplay = true
            button.setAccessibilityLabel(button.title + "、最初の行へ移動")
            // 到着順ではなくrequest番号順の最初へ移す。同じ操作で必ず同じ行へ着く。
            let first = matching.first.map { kind.rowID($0) }
            button.callback = { [weak self] in if let first { self?.onSelect?(first) } }
        }
        isHidden = buttons.values.allSatisfy { $0.isHidden }
    }
}

struct AIViewState {
    var rangeBoundaries = AIRangeBoundaries()
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
    /// 枠ごとの接続状態と現世代。行は自分を送った枠のものを見る
    var connections: [Int: AIConnectionStatus] = [:]
    var generations: [Int: Int] = [:]
    /// 準備の入口を使えるか。台帳が読めないときだけ無効にする
    var canPrepare = true
    /// フッターの一行。「準備済み: 議事録 13:05 · 相談 13:10」。3件を超えたら畳む
    var preparedSummary = ""
    var preparedToolTip = ""
    /// 枠ごとの送信可否と進捗。確認への返答シートは親の枠のものを見る
    var canSubmits: [Int: Bool] = [:]
    var progresses: [Int: String] = [:]
    var participants: [Int: String] = [:]
    var openablePanes: Set<Int> = []
    var avatarSources: [Int: String] = [:]
    func avatarSource(for requestID: UUID) -> String? {
        guard let request = conversation?.questions.first(where: { $0.request.id == requestID })?.request else { return nil }
        return avatarSources[slot(of: request)]
    }
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
        let counts = AIBadgeKind.allCases.map { kind in
            (kind.rawValue, questions.filter { kind.matches($0, in: questions) }.count)
        }
        return counts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
    var shortcut: String {
        [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
            .filter { hotkey.modifiers.contains($0.0) }.map(\.1).joined() + hotkey.key.uppercased()
    }
}

/// フッターの操作。行の中の操作と同じ枠のピルで描き、同じ「押すもの」が
/// 2種類の見え方をしないようにする。無効な場面ではビューごと隠す。
final class AIActionButton: NSButton {
    var callback: (() -> Void)?
    init(_ title: String, size: CGFloat = 11, action: @escaping () -> Void) {
        callback = action; super.init(frame: .zero); self.title = title
        isBordered = false; font = .systemFont(ofSize: size)
        target = self; self.action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    var measuredWidth: CGFloat { intrinsicContentSize.width }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 24, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        (isEnabled ? Washi.muted : Washi.rule).setStroke(); pill.lineWidth = 1; pill.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: isEnabled ? Washi.ink : Washi.muted]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
    @objc private func pressed() { callback?() }
}
