import AppKit
import KikigakiCore

/// AIの送信と返事を、人の発話と同じ行の形で並べる。畳んだ印は使わない。
/// 位置と表示値は `AITimeline.items` が決め、ここは描き方だけを持つ。
@MainActor protocol AITimelineRowView: DocumentRow {
    var item: AITimeline.Item { get }
    func update(_ item: AITimeline.Item, state: AIViewState)
}

enum AIRowMetrics {
    static let bodyX: CGFloat = 54
    static let avatar = NSRect(x: 20, y: 8, width: 25, height: 26)
    static func bodyWidth(_ width: CGFloat) -> CGFloat { max(44, width - 90) }
    /// 人の発話と同じ秒の粒度で出す。1本の時間軸に2つの桁数を混ぜない。
    static let clock = formatter("HH:mm:ss")
    static let clockWithSeconds = formatter("HH:mm:ss")
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
    static func measure(_ field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(44, width), height: .greatestFiniteMagnitude)).height ?? 0)
    }
}

/// 未読・確認待ち・返事待ちの印。押して既読にできるのは未読だけで、
/// 他は状態表示なので操作を持たせない。無効でも面は足さず、色だけを抜く。
final class AIStatusPill: HoverButton {
    enum Style: Equatable { case unread, confirmation, waiting }
    private(set) var style: Style = .waiting
    private var configured = false
    var callback: (() -> Void)?
    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        font = .systemFont(ofSize: 11, weight: .bold)
        target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ style: Style) {
        guard self.style != style || !configured else { return }
        configured = true
        self.style = style
        title = style == .unread ? "未読" : style == .confirmation ? "要返答" : "返事待ち"
        isEnabled = style == .unread
        toolTip = style == .unread ? "押すと既読にします" : nil
        setAccessibilityLabel(title + (style == .unread ? "、押すと既読にします" : ""))
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 16, height: 20)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = style == .unread ? (isHovered ? Washi.brightRed : Washi.red) : style == .confirmation ? Washi.red : Washi.muted
        let filled = style != .waiting
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        if filled { color.setFill(); pill.fill() }
        else { color.setStroke(); pill.lineWidth = 1; pill.stroke() }
        // 朱の塗りには白文字、輪郭だけの状態には同色の文字を使う。
        let attributes: [NSAttributedString.Key: Any] = [.font: font!,
            .foregroundColor: filled ? NSColor.white : color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
    @objc private func pressed() { callback?() }
}

/// 「AI」「自動」の印。塗りは足さず枠だけで、状態のピルとは別の大きさにする。
final class AITagPill: NSView {
    override var isFlipped: Bool { true }
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    private var font: NSFont { .systemFont(ofSize: 10) }
    var measuredWidth: CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12 }
    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Washi.rule.setStroke(); pill.lineWidth = 1; pill.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Washi.muted]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}

/// 返事行の本文の下へ置く、頼んだモデルと作業場所の1行。
/// 「どのモデルへ・どの強さで」と「どこで動いているものへ」は意味が違うので、中黒で1本に繋がず、
/// 塊ごとにアイコンを付けて12pt離す。折り返さないので、幅が足りなければ
/// 作業場所の塊 → エフォート の順に落とす。
final class AIModelFooter: NSView {
    /// 本文の下へ足す段の高さ。11ptの文字とアイコンが収まる最小。
    static let height: CGFloat = 18
    /// 2つの塊の間。中黒より広く、別のものだと一目で読めるだけ空ける。
    static let gap: CGFloat = 12
    private static let font = NSFont.systemFont(ofSize: 11)
    private static let iconGap: CGFloat = 4
    private static let modelGlyph = glyph("cpu")
    private static let placeGlyph = glyph("folder")
    private var stages: [AIModelLabel.Stage] = []
    /// 今の幅で選んだ段。どれも収まらなければnilで、何も描かない。
    private(set) var stage: AIModelLabel.Stage?
    var displayText: String { stage?.text ?? "" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 全部入りの表記は行そのものの読み上げが持つ。フッターを別の要素として二度読ませない。
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ label: AIModelLabel?) {
        let stages = label?.stages ?? []
        guard self.stages != stages else { return }
        self.stages = stages
        // 幅で落とした塊も、tooltipからは全部入りで読める。
        toolTip = label.map(\.text)
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refresh()
    }

    /// 幅へ収まる最も広い段を選ぶ。同じ幅なら同じ段に落ち着くので、描き直しは循環しない。
    private func refresh() {
        let selected = AIModelLabel.fit(stages, available: Double(bounds.width)) { Double(AIModelFooter.width(of: $0)) }
        guard selected != stage else { return }
        stage = selected
        needsDisplay = true
    }

    static func width(of stage: AIModelLabel.Stage) -> CGFloat {
        modelWidth(stage.model) + (stage.directory.map { gap + placeWidth($0) } ?? 0)
    }
    /// 前の塊の幅。アイコン + 4pt + 文字。後ろの塊はアイコンが違うので別に測る。
    static func modelWidth(_ text: String) -> CGFloat { cluster(modelGlyph, text) }
    static func placeWidth(_ text: String) -> CGFloat { cluster(placeGlyph, text) }
    private static func glyph(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Washi.muted])))
    }
    private static func cluster(_ glyph: NSImage?, _ text: String) -> CGFloat {
        iconWidth(glyph) + iconGap + ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    private static func iconWidth(_ glyph: NSImage?) -> CGFloat { ceil(glyph?.size.width ?? 11) }

    override func draw(_ dirtyRect: NSRect) {
        guard let stage else { return }
        let x = draw(AIModelFooter.modelGlyph, stage.model, x: 0)
        if let directory = stage.directory {
            _ = draw(AIModelFooter.placeGlyph, directory, x: x + AIModelFooter.gap)
        }
    }
    private func draw(_ glyph: NSImage?, _ text: String, x: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: AIModelFooter.font, .foregroundColor: Washi.muted]
        if let glyph {
            glyph.draw(in: NSRect(x: x, y: (bounds.height - glyph.size.height) / 2,
                                  width: glyph.size.width, height: glyph.size.height))
        }
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: x + AIModelFooter.iconWidth(glyph) + AIModelFooter.iconGap,
                                            y: (bounds.height - size.height) / 2), withAttributes: attributes)
        return x + AIModelFooter.cluster(glyph, text)
    }
}

/// 返事の上へ添える送信文の引用。既定は1行で末尾を省略し、押すと全文へ伸びる。
final class AIQuoteButton: HoverButton {
    private(set) var expanded = false
    var text = ""
    var onToggle: (() -> Void)?
    init() {
        super.init(frame: .zero)
        isBordered = false
        target = self; action = #selector(pressed)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        refresh()
    }
    private func refresh() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        paragraph.lineSpacing = expanded ? 3 : 0
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Washi.muted, .paragraphStyle: paragraph
        ])
        cell?.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        (cell as? NSButtonCell)?.wraps = expanded
        toolTip = text
        setAccessibilityLabel("送信文 " + text + (expanded ? "、畳む" : "、全文を表示する"))
        needsDisplay = true
    }
    /// 幅は字下げ後の実幅で渡す。罫は行側が本文の左端へ別に描く。
    func height(for width: CGFloat) -> CGFloat {
        guard expanded else { return 18 }
        let bounds = NSRect(x: 0, y: 0, width: max(44, width), height: .greatestFiniteMagnitude)
        return max(18, ceil(cell?.cellSize(forBounds: bounds).height ?? 18))
    }
    @objc private func pressed() {
        expanded.toggle()
        refresh()
        onToggle?()
    }
}

/// 声からの送信と自動送信の細い1行。発話の直下か日時順に置く。
final class AISendLineRow: NSView, AITimelineRowView {
    override var isFlipped: Bool { true }
    private(set) var item: AITimeline.Item
    private let label = Washi.label(size: 11, color: Washi.muted)
    /// 送達不明は返事の行を作らないので、取消はこの行に置く。
    private lazy var cancelAction = AIActionButton("取消", size: 11) { [weak self] in self?.onCancel?() }
    var onCancel: (() -> Void)?
    var displayText: String { label.stringValue }
    init(item: AITimeline.Item, state: AIViewState) {
        self.item = item
        super.init(frame: .zero)
        addSubview(label); addSubview(cancelAction)
        label.lineBreakMode = .byTruncatingTail
        update(item, state: state)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ item: AITimeline.Item, state: AIViewState) {
        self.item = item
        let verb = item.automatic ? "へ自動送信" : "へ送信"
        var parts = ["└ " + item.participantName + verb] + item.notes
        if let date = item.date { parts.append(AIRowMetrics.clock.string(from: date)) }
        label.stringValue = parts.joined(separator: " · ")
        // この地色では薄めた11ptが2.6:1まで落ちる。自動の区別は語に任せて色は薄めない。
        label.textColor = Washi.muted
        let range = item.timeRange.map { "\($0.start)〜\($0.end)" }
        let seconds = item.date.map { AIRowMetrics.clockWithSeconds.string(from: $0) }
        label.toolTip = ([label.stringValue, seconds, range, item.question.isEmpty ? nil : item.question]
            .compactMap { $0 }).joined(separator: "\n")
        label.setAccessibilityLabel(label.stringValue)
        cancelAction.isHidden = !item.canCancel || state.readOnly
        needsLayout = true
    }
    /// 取消は同じ行の右端へ置く。段を足すと、結果が届いて取消が消えたときに行が縮み、
    /// 末尾を読んでいる利用者の画面が動く。
    func height(for width: CGFloat) -> CGFloat { 26 }
    override func layout() {
        super.layout()
        let width = cancelAction.isHidden ? 0 : cancelAction.measuredWidth
        cancelAction.frame = NSRect(x: bounds.width - 20 - width, y: 1, width: width, height: 24)
        let right = cancelAction.isHidden ? bounds.width - 20 : cancelAction.frame.minX - 8
        label.frame = NSRect(x: AIRowMetrics.bodyX, y: 4, width: max(0, right - AIRowMetrics.bodyX), height: 18)
    }
}

/// 問い欄へ入力した送信と、確認への返答。人側の行として送信文そのものを置く。
/// 「手入力」とは別の名前・記号にする。手入力は会議Markdownへ残る投稿の固定名で、
/// AIへ送っただけの文が議事録に載っていると誤解させるため。
final class AITypedSendRow: NSView, AITimelineRowView {
    override var isFlipped: Bool { true }
    private(set) var item: AITimeline.Item
    private let avatar = AvatarView()
    private let nameLabel = Washi.label("AIへ送信", size: 12, weight: .semibold)
    private let timeLabel = Washi.label(color: Washi.muted)
    private let noteLabel = Washi.label(size: 11, color: Washi.muted)
    /// 宛名はラベルであって状態ではないので、枠つきピルにしない。
    /// 枠つきピルは状態専用に残し、枠の有無をそのまま「注意が要るか」にする。
    private let address = Washi.label(size: 11, color: Washi.muted)
    private let body = NSTextField(wrappingLabelWithString: "")
    /// 送達不明は返事の行を作らないので、取消はこの行に置く。
    private lazy var cancelAction = AIActionButton("取消", size: 11) { [weak self] in self?.onCancel?() }
    var onCancel: (() -> Void)?
    private var measured: CGFloat = 0
    var displayName: String { nameLabel.stringValue }
    var addressText: String { address.stringValue }
    var noteText: String { noteLabel.stringValue }
    init(item: AITimeline.Item, state: AIViewState) {
        self.item = item
        super.init(frame: .zero)
        avatar.typed = true
        avatar.glyph = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "AIへ送信")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Washi.paper]))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        noteLabel.lineBreakMode = .byTruncatingTail
        body.isSelectable = true
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        for view in [avatar, nameLabel, timeLabel, noteLabel, address, body, cancelAction] { addSubview(view) }
        update(item, state: state)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ item: AITimeline.Item, state: AIViewState) {
        let previous = self.item
        self.item = item
        timeLabel.stringValue = item.date.map(AIRowMetrics.clock.string(from:)) ?? ""
        timeLabel.toolTip = item.date.map(AIRowMetrics.clockWithSeconds.string(from:))
        let parent = item.parentNumber.map { "#\($0)への返答" }
        noteLabel.stringValue = ([parent].compactMap { $0 } + item.notes).joined(separator: " · ")
        noteLabel.toolTip = ([noteLabel.stringValue, item.timeRange.map { "\($0.start)〜\($0.end)" }]
            .compactMap { $0 }).joined(separator: "\n")
        address.stringValue = item.participantName + "へ"
        avatar.setAccessibilityLabel("AIへ送信")
        // 送っていない文と取り消した文を、送った文と同じ重さで会話に残さない。面は足さず色を抜く。
        let pending = item.notes.contains { $0 == "取消" || $0 == "送信準備中" }
        if body.stringValue != item.question || previous.notes != item.notes {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
            body.attributedStringValue = NSAttributedString(string: item.question, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: pending ? Washi.muted : Washi.ink,
                .paragraphStyle: paragraph
            ])
            measured = 0
        }
        avatar.alphaValue = pending ? 0.5 : 1
        avatar.needsDisplay = true
        cancelAction.isHidden = !item.canCancel || state.readOnly
        needsLayout = true
    }
    /// 取消は見出しの行へ置く。段を足すと、結果が届いて取消が消えたときに行が縮み、
    /// 末尾を読んでいる利用者の画面が動く。
    func height(for width: CGFloat) -> CGFloat {
        measured = AIRowMetrics.measure(body, width: AIRowMetrics.bodyWidth(width))
        return max(20, measured) + 36
    }
    override func layout() {
        super.layout()
        avatar.frame = AIRowMetrics.avatar
        let nameWidth = ceil(nameLabel.intrinsicContentSize.width) + 4
        nameLabel.frame = NSRect(x: AIRowMetrics.bodyX, y: 8, width: nameWidth, height: 18)
        timeLabel.frame = NSRect(x: AIRowMetrics.bodyX + nameWidth + 12, y: 8,
                                width: ceil(timeLabel.intrinsicContentSize.width) + 4, height: 18)
        let addressWidth = ceil(address.intrinsicContentSize.width) + 2
        address.frame = NSRect(x: bounds.width - 20 - addressWidth, y: 9, width: addressWidth, height: 16)
        let width = cancelAction.isHidden ? 0 : cancelAction.measuredWidth
        cancelAction.frame = NSRect(x: address.frame.minX - 8 - width, y: 5, width: width, height: 24)
        let noteX = timeLabel.frame.maxX + 8
        let noteRight = cancelAction.isHidden ? address.frame.minX : cancelAction.frame.minX
        noteLabel.frame = NSRect(x: noteX, y: 9, width: max(0, noteRight - noteX - 8), height: 16)
        body.frame = NSRect(x: AIRowMetrics.bodyX, y: 31, width: AIRowMetrics.bodyWidth(bounds.width), height: max(20, bounds.height - 36))
    }
}

/// AIの行。返事待ち・返事・確認質問・失敗を同じ行IDで扱い、到着で生まれ直さない。
final class AIReplyRow: NSView, AITimelineRowView {
    override var isFlipped: Bool { true }
    private(set) var item: AITimeline.Item
    private var state: AIViewState
    var onRead: (() -> Void)?
    var onReply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onResize: (() -> Void)?
    private let avatar = AvatarView()
    private let nameLabel = Washi.label(size: 12, weight: .semibold)
    private let chip = AITagPill()
    private let timeLabel = Washi.label(color: Washi.muted)
    /// 「[cpu] gpt-6-astra · high 　 [folder] minutes」。本文の下の1行なので名前行を押さない。
    private let footer = AIModelFooter()
    private var model: AIModelLabel?
    private var measuredFooter: CGFloat = 0
    private let durationLabel = Washi.label(size: 11, color: Washi.muted)
    private let pill = AIStatusPill()
    private let quote = AIQuoteButton()
    /// 引用の左罫。ボタンの内側へ描くと文字に隠れるので、本文の左端へ別のビューで置く。
    private let quoteRule = NSView()
    private let markdownBody = MarkdownBodyView()
    let progressView = AIProgressView()
    /// 返答到着の点灯。全段を見せてから本文へ入れ替えるまでの猶予
    static let arrivalDuration: TimeInterval = 1.5
    private var arrivalTimer: Timer?
    private var lastProgress: AIProgress?
    private var lastStatus: AIProgress.Status?
    private(set) var isShowingArrival = false
    private let confirmationMark = Washi.label("?", size: 15, color: Washi.muted)
    private let notes = NSTextField(wrappingLabelWithString: "")
    /// 本文15・名前12の間に段を増やさないよう12ptに揃える。
    private let failureLabel = Washi.label(size: 12, weight: .semibold)
    private lazy var replyAction = AIActionButton("返答する", size: 12) { [weak self] in self?.onReply?() }
    private lazy var cancelAction = AIActionButton("取消", size: 12) { [weak self] in self?.onCancel?() }
    private lazy var retryAction = AIActionButton("再送", size: 12) { [weak self] in self?.onRetry?() }
    private var measuredQuote: CGFloat = 0
    private var measuredBody: CGFloat = 0
    private var measuredNotes: CGFloat = 0
    var chipText: String { chip.text }
    var chipVisible: Bool { !chip.isHidden }
    var timeText: String { timeLabel.isHidden ? "" : timeLabel.stringValue }
    var modelText: String { footer.isHidden ? "" : footer.displayText }
    var modelFooter: AIModelFooter { footer }
    var durationText: String { durationLabel.isHidden ? "" : durationLabel.stringValue }
    var noteText: String { notes.isHidden ? "" : notes.stringValue }
    var failureText: String { failureLabel.stringValue }
    var quoteButton: AIQuoteButton { quote }
    func updateAvatar(store: AvatarStore) {
        avatar.image = store.image(for: state.avatarSource(for: item.requestID))
    }
    var statusPill: AIStatusPill { pill }

    /// 進行表示はこの入口だけから更新する。返答到着の見せ方を行が決めるため。
    /// 返事待ちから結果へ変わった瞬間だけ全段を点灯し、1.5秒後に本文へ入れ替える。
    /// 到着済みの行を開き直したときは点灯しない。動きを減らす設定では即入れ替える。
    func updateProgress(_ progress: AIProgress?, reduceMotion: Bool, now: Date = Date()) {
        let previous = lastStatus
        lastStatus = progress?.status
        lastProgress = progress
        if !reduceMotion, !isShowingArrival, let previous, previous != .answered, previous != .needsInput,
           progress?.arrival() != nil {
            isShowingArrival = true
            arrivalTimer?.invalidate()
            arrivalTimer = Timer.scheduledTimer(withTimeInterval: Self.arrivalDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.endArrival() }
            }
        }
        progressView.update(isShowingArrival ? progress?.arrival() : progress, reduceMotion: reduceMotion, now: now)
        if isShowingArrival { updateVisibility(); needsLayout = true }
    }

    private func endArrival() {
        arrivalTimer?.invalidate(); arrivalTimer = nil
        guard isShowingArrival else { return }
        isShowingArrival = false
        progressView.update(lastProgress, reduceMotion: true)
        updateVisibility(); needsLayout = true
        onResize?()
    }

    /// 表示中の会議が変わる・行が消えるときは点灯を持ち越さない。
    func stopArrival() { endArrival() }
    deinit { arrivalTimer?.invalidate() }

    private func markReadIfNeeded() {
        // 通常返答に既読操作を要求しない。保存済み状態もクリックで書き換えない。
    }

    var isFailure: Bool { if case .failure = item.kind { return true }; return false }
    /// モデルが返した失敗報告。送信そのものができなかった失敗と区別し、本文を全部見せる。
    var isReturnedFailure: Bool { if case let .failure(_, returned) = item.kind { return returned }; return false }
    /// 返答到着の点灯中も、本文へ入れ替えるまでは返事待ちと同じ見た目を保つ。
    var isWaiting: Bool { item.kind == .reply(.waiting) || isShowingArrival }
    /// 要返答と失敗だけを朱で強調し、通常返答に未読の強調を置かない。
    var accent: NSColor? {
        if isFailure { return Washi.red }
        // 確認質問の帯は返答するまで残す。
        if item.kind == .reply(.needsInput) { return item.needsAnswer ? Washi.red : nil }
        return nil
    }
    var pillStyle: AIStatusPill.Style? {
        if isWaiting { return nil }
        if item.kind == .reply(.needsInput) { return item.needsAnswer ? .confirmation : nil }
        // 通常返答と失敗には未読の操作を置かない。
        return nil
    }

    init(item: AITimeline.Item, state: AIViewState) {
        self.item = item; self.state = state
        super.init(frame: .zero)
        avatar.accent = Washi.ai
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationLabel.lineBreakMode = .byTruncatingTail
        notes.isSelectable = true; notes.maximumNumberOfLines = 0; notes.lineBreakMode = .byWordWrapping
        failureLabel.lineBreakMode = .byTruncatingTail
        Washi.surface(quoteRule, color: Washi.rule)
        pill.callback = { [weak self] in self?.markReadIfNeeded() }
        markdownBody.onClick = { [weak self] in self?.markReadIfNeeded() }
        quote.onToggle = { [weak self] in self?.onResize?() }
        for view in [avatar, nameLabel, chip, timeLabel, durationLabel, pill, quoteRule, quote, markdownBody,
                     progressView, footer, confirmationMark, notes, failureLabel, replyAction, cancelAction,
                     retryAction] { addSubview(view) }
        update(item, state: state)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ item: AITimeline.Item, state: AIViewState) {
        let widthChanged = self.item.body != item.body || self.item.question != item.question
        self.item = item; self.state = state
        nameLabel.stringValue = item.participantName
        nameLabel.textColor = isWaiting ? Washi.muted : Washi.ink
        // 名前行から表記を外しても、全部入りは名前のtooltipから読める。
        nameLabel.toolTip = state.modelLabel(for: item.requestID)?.text
        // 返事待ちでも宛先は確定済み。画像の取得中・失敗時もAIのイニシャルを使う。
        avatar.tentative = false
        avatar.initial = String(item.participantName.prefix(1))
        avatar.setAccessibilityLabel(item.participantName)
        avatar.needsDisplay = true
        chip.text = item.automatic ? "自動" : "AI"
        // 表記の中身は会議開始時に固定した値。幅に応じてどの塊を出すかはフッターが決める。
        model = state.modelLabel(for: item.requestID)
        footer.update(model)
        timeLabel.stringValue = item.date.map(AIRowMetrics.clock.string(from:)) ?? ""
        timeLabel.toolTip = item.date.map(AIRowMetrics.clockWithSeconds.string(from:))
        durationLabel.stringValue = item.durationSeconds.map {
            "· 所要 \($0 / 60):\($0 % 60 < 10 ? "0" : "")\($0 % 60)"
        } ?? ""
        durationLabel.toolTip = durationLabel.stringValue.isEmpty ? nil : durationLabel.stringValue
        // 返答したあとも本文が問いであることの印は残す。状態ではないので色だけ落とす。
        confirmationMark.textColor = item.needsAnswer ? Washi.muted : Washi.rule
        if let style = pillStyle { pill.update(style) }
        markdownBody.update(item.body)
        quote.update(item.question)
        if case let .failure(reason, returned) = item.kind {
            // 帯は1行なので、取消後・旧接続などの注記も同じ行へ連ねる。
            // 返送された失敗は「送信できなかった」ではないので言い方を分け、本文は下へ全部出す。
            let heading = returned ? item.participantName + "から失敗の報告" : item.participantName + "へ送信できませんでした"
            failureLabel.stringValue = ([heading, reason] + item.notes).joined(separator: " · ")
            failureLabel.textColor = Washi.red
            failureLabel.toolTip = ([failureLabel.stringValue, returned ? item.body : nil].compactMap { $0 }).joined(separator: "\n")
        }
        // 注記はCoreが作る。返事待ちの接続状態は進行文へ一本化する。
        let text = item.notes.joined(separator: " · ")
        if notes.stringValue != text {
            notes.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Washi.muted
            ])
        }
        updateVisibility()
        if widthChanged { measuredBody = 0 }
        needsDisplay = true; needsLayout = true
    }

    private func updateVisibility() {
        let failure = isFailure
        failureLabel.isHidden = !failure
        retryAction.isHidden = !failure || state.readOnly
        for view in [avatar, nameLabel] { view.isHidden = failure }
        // 失敗の帯にも確定時刻を出す。返事待ちは到着していないので時刻も種別も出さない。
        timeLabel.isHidden = isWaiting
        durationLabel.isHidden = failure || isWaiting || item.durationSeconds == nil
        // 返事待ちでも宛先は確定しているので、進行文とバーの下へ同じ表記を出す。
        // 失敗の帯は見出しだけの1行なので、段を足さずに帯のまま残す。
        footer.isHidden = failure || model == nil
        chip.isHidden = failure || isWaiting
        pill.isHidden = pillStyle == nil
        quote.isHidden = failure || item.question.isEmpty
        quoteRule.isHidden = quote.isHidden
        // 返送された失敗の本文は画面から読めるようにする。保存にだけ残る状態にしない。
        markdownBody.isHidden = (failure && !isReturnedFailure) || isWaiting
        progressView.isHidden = failure || !isWaiting
        progressView.updateVisibility()
        confirmationMark.isHidden = failure || item.kind != .reply(.needsInput)
        notes.isHidden = failure || notes.stringValue.isEmpty
        // 点灯の1.5秒は操作を出さない。取り消せない依頼の取消も、本文のない返答導線も置かない。
        replyAction.isHidden = failure || !item.needsAnswer || state.readOnly || isShowingArrival
        cancelAction.isHidden = failure || !isWaiting || state.readOnly || isShowingArrival
        // 幅で落とした塊に関係なく、読み上げには全部入りの表記を渡す。
        let spoken = model.map { "、" + $0.text } ?? ""
        setAccessibilityLabel(failure ? failureLabel.stringValue + spoken
            : item.participantName + "、" + (isWaiting ? "返事待ち" : chip.text) + spoken + (pillStyle == .unread ? "、未読" : ""))
    }

    /// 測る前に表示と同じ幅の枠を与える。幅0のまま測るとTextKitが器の寸法を誤り、
    /// 表やコードを含む返事の高さが一度だけ跳ね上がったまま計測値に残る。
    private func measureMarkdown(_ width: CGFloat) -> CGFloat {
        if markdownBody.frame.width != width {
            markdownBody.setFrameSize(NSSize(width: width, height: markdownBody.frame.height))
        }
        return markdownBody.height(for: width)
    }

    func height(for width: CGFloat) -> CGFloat {
        if isFailure {
            guard isReturnedFailure else { return 34 }
            measuredBody = measureMarkdown(AIRowMetrics.bodyWidth(width))
            return 34 + measuredBody + 8
        }
        let bodyWidth = AIRowMetrics.bodyWidth(width)
        measuredQuote = item.question.isEmpty ? 0 : quote.height(for: bodyWidth - 12) + 8
        measuredBody = isWaiting ? 42 : measureMarkdown(bodyWidth)
        measuredNotes = notes.isHidden ? 0 : AIRowMetrics.measure(notes, width: bodyWidth) + 6
        // 表記を出す行は1段ぶん高くなる。段の有無は幅ではなくプロファイルで決まるので、
        // 幅を狭めても行の高さは動かない。
        measuredFooter = footer.isHidden ? 0 : AIModelFooter.height
        // 取消は進行文と同じ行の右端へ寄せる。バーの8ptと段名の14ptを確保する。
        let actions = replyAction.isHidden ? 0.0 : 30
        return 31 + measuredQuote + max(20, measuredBody) + measuredFooter + measuredNotes + actions + 9
    }

    override func layout() {
        super.layout()
        if isFailure {
            // 読み取り専用では「再送」を出さないので、その幅を空けたままにしない。
            let retryWidth = retryAction.isHidden ? 0 : retryAction.measuredWidth
            retryAction.frame = NSRect(x: bounds.width - 20 - retryWidth, y: 5, width: retryWidth, height: 24)
            let right = retryAction.isHidden ? bounds.width - 20 : retryAction.frame.minX - 8
            let timeWidth = ceil(timeLabel.intrinsicContentSize.width) + 4
            timeLabel.frame = NSRect(x: right - timeWidth, y: 6, width: timeWidth, height: 18)
            // 返送された失敗は未読になるので、押して既読にできる印を帯の中へ置く。
            let pillWidth = pill.isHidden ? 0 : ceil(pill.intrinsicContentSize.width)
            pill.frame = NSRect(x: timeLabel.frame.minX - 8 - pillWidth, y: 5, width: pillWidth, height: 20)
            let end = pill.isHidden ? timeLabel.frame.minX : pill.frame.minX
            failureLabel.frame = NSRect(x: AIRowMetrics.bodyX, y: 7, width: max(0, end - AIRowMetrics.bodyX - 8), height: 18)
            if isReturnedFailure {
                markdownBody.frame = NSRect(x: AIRowMetrics.bodyX, y: 34, width: AIRowMetrics.bodyWidth(bounds.width),
                                            height: max(20, measuredBody))
            }
            return
        }
        avatar.frame = AIRowMetrics.avatar
        let nameWidth = ceil(nameLabel.intrinsicContentSize.width) + 4
        nameLabel.frame = NSRect(x: AIRowMetrics.bodyX, y: 8, width: nameWidth, height: 18)
        let chipWidth = chip.isHidden ? 0 : chip.measuredWidth
        chip.frame = NSRect(x: nameLabel.frame.maxX + 8, y: 9, width: chipWidth, height: 16)
        // 名前 → チップ → 時刻 → 所要。モデル表記は本文の下へ移したので名前行を押さない。
        timeLabel.frame = NSRect(x: nameLabel.frame.maxX + (chip.isHidden ? 12 : chipWidth + 16), y: 8,
                                width: ceil(timeLabel.intrinsicContentSize.width) + 4, height: 18)
        let pillWidth = ceil(pill.intrinsicContentSize.width)
        pill.frame = NSRect(x: bounds.width - 20 - pillWidth, y: 8, width: pillWidth, height: 20)
        let durationRight = pill.isHidden ? bounds.width - 20 : pill.frame.minX - 8
        durationLabel.frame = NSRect(x: timeLabel.frame.maxX + 6, y: 9,
            width: max(0, min(ceil(durationLabel.intrinsicContentSize.width) + 4,
                             durationRight - timeLabel.frame.maxX - 6)), height: 16)
        let bodyWidth = AIRowMetrics.bodyWidth(bounds.width)
        // 引用は本文より12pt字下げし、空いた左へ罫を置く。従属関係を字下げと罫の両方で示す。
        quote.frame = NSRect(x: AIRowMetrics.bodyX + 12, y: 31, width: bodyWidth - 12, height: max(0, measuredQuote - 8))
        quoteRule.frame = NSRect(x: AIRowMetrics.bodyX, y: 32, width: 2, height: max(0, measuredQuote - 10))
        let bodyY = 31 + measuredQuote
        markdownBody.frame = NSRect(x: AIRowMetrics.bodyX, y: bodyY, width: bodyWidth, height: max(20, measuredBody))
        let progressRight = cancelAction.isHidden ? bounds.width - 20 : bounds.width - 20 - cancelAction.measuredWidth - 8
        progressView.frame = NSRect(x: AIRowMetrics.bodyX, y: bodyY,
                                   width: max(0, progressRight - AIRowMetrics.bodyX), height: 44)
        confirmationMark.frame = NSRect(x: AIRowMetrics.bodyX - 14, y: bodyY + 2, width: 12, height: 20)
        // 返事待ちでは進行文とバーの下。回答・確認質問では本文の下。どちらも本文の左端へ揃える。
        let contentBottom = isWaiting ? progressView.frame.maxY : markdownBody.frame.maxY
        footer.frame = NSRect(x: AIRowMetrics.bodyX, y: contentBottom, width: bodyWidth, height: AIModelFooter.height)
        notes.frame = NSRect(x: AIRowMetrics.bodyX, y: contentBottom + measuredFooter + 6,
                             width: bodyWidth, height: max(0, measuredNotes - 6))
        if !cancelAction.isHidden {
            let width = cancelAction.measuredWidth
            cancelAction.frame = NSRect(x: bounds.width - 20 - width, y: bodyY - 2, width: width, height: 24)
        }
        if !replyAction.isHidden {
            replyAction.frame = NSRect(x: AIRowMetrics.bodyX, y: contentBottom + measuredFooter + measuredNotes + 4,
                                       width: replyAction.measuredWidth, height: 24)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let accent else { return }
        let band = bounds.insetBy(dx: 12, dy: 2)
        accent.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: band, xRadius: 5, yRadius: 5).fill()
        accent.setFill()
        NSRect(x: band.minX, y: band.minY, width: 3, height: band.height).fill()
    }
}
