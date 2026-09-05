import AppKit
import QuartzCore
import KikigakiCore

/// 和紙の帳面。配色はここだけに定義する。
private enum Washi {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let paper = color(0xF5EAD9)
    static let shade = color(0xEDE0CD)
    static let rule = color(0xD5C6B1)
    static let ink = color(0x221F1C)
    static let muted = color(0x6B6157)
    static let tentative = color(0x4A443D)
    static let red = color(0xAA1405)
    static let brightRed = color(0xCF321F)
    static let slots = [red, color(0xC4801F), color(0x514A43), color(0x3E706C)]
    static func speakerColor(for slot: Int?) -> NSColor {
        guard let slot, slot >= 0 else { return muted }
        // パレットはエンジンの枡数とは独立。5枡目以降の色はここへ足せる。
        // 未定義の枡も、黙って不明話者の色にせず既存の色を循環させる。
        return slots[slot % slots.count]
    }
    static let logo: NSImage? = {
        if let url = Bundle.main.url(forResource: "kikigaki", withExtension: "icns") { return NSImage(contentsOf: url) }
        // swift run用。配布アプリはmake-app.sh同梱の同じロゴを使う。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: root.appendingPathComponent("Resources/kikigaki.png"))
    }()
    static func logoView(size: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = logo
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("KIKIGAKI")
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }
    static func surface(_ view: NSView, color: NSColor = shade) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }
    static func label(_ text: String = "", size: CGFloat = 12, color: NSColor = ink,
                      weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
}

/// NSButtonの操作・フォーカス・アクセシビリティを残して主操作の地だけ描く。
private final class CopyButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        (isEnabled ? (isHighlighted ? Washi.brightRed : Washi.red) : Washi.rule).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}

private final class RecordingMark: NSView {
    var paused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (paused ? Washi.muted : Washi.red).setFill()
        if paused {
            NSRect(x: 0, y: 0, width: 3, height: 9).fill()
            NSRect(x: 6, y: 0, width: 3, height: 9).fill()
        } else { NSBezierPath(ovalIn: bounds).fill() }
    }
}

/// 段3で画像とクリック領域を追加するため、本文から独立させる。
private final class AvatarView: NSView {
    override var isFlipped: Bool { true }
    var initial = "?"
    var slot: Int?
    var tentative = false
    override func draw(_ dirtyRect: NSRect) {
        if tentative {
            Washi.muted.setStroke()
            let dashed = NSBezierPath(ovalIn: NSRect(x: 0.875, y: 0.875, width: 22.25, height: 22.25))
            dashed.lineWidth = 1.75
            dashed.setLineDash([3, 2], count: 2, phase: 0)
            dashed.stroke()
            return
        }
        let color = Washi.speakerColor(for: slot)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 3, y: 18))
        tail.line(to: NSPoint(x: 1, y: 25))
        tail.line(to: NSPoint(x: 8, y: 22))
        tail.close()
        tail.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: slot.map { $0 >= 0 && $0 % Washi.slots.count == 1 } == true ? Washi.ink : Washi.paper]
        let size = (initial as NSString).size(withAttributes: attributes)
        (initial as NSString).draw(at: NSPoint(x: 12 - size.width / 2, y: 12 - size.height / 2), withAttributes: attributes)
    }
}

private protocol DocumentRow: NSView { func height(for width: CGFloat) -> CGFloat }

private final class TranscriptRow: NSView, DocumentRow {
    override var isFlipped: Bool { true }
    private let shade = NSView()
    private let flash = NSView()
    private let avatar = AvatarView()
    private let nameLabel = Washi.label(size: 12, weight: .semibold)
    private let timeLabel = Washi.label(color: Washi.muted)
    private let hint = Washi.label("コピーには含めません", size: 11, color: Washi.muted)
    private let body = NSTextField(wrappingLabelWithString: "")
    private var utterance: Utterance?
    private var displayedName = ""
    private var displayedTimeline: MeetingTimeline?
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    private let tentative: Bool

    init(tentative: Bool = false) {
        self.tentative = tentative
        super.init(frame: .zero)
        wantsLayer = true
        for view in [shade, flash] {
            Washi.surface(view)
            view.layer?.cornerRadius = 5
            addSubview(view)
        }
        shade.isHidden = !tentative
        flash.layer?.opacity = 0
        avatar.tentative = tentative
        body.font = .systemFont(ofSize: 15)
        body.isSelectable = true
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = tentative ? Washi.muted : Washi.ink
        if tentative { nameLabel.font = .systemFont(ofSize: 12) }
        hint.isHidden = !tentative
        for view in [avatar, nameLabel, timeLabel, hint, body] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 本文・話者変更だけを点灯対象とする。時刻の再描画では点灯しない。
    @discardableResult
    func update(_ value: Utterance, names: SpeakerNames, timeline: MeetingTimeline) -> Bool {
        let name = names.name(for: value.speaker)
        guard utterance != value || displayedName != name || displayedTimeline != timeline else { return false }
        let changed = utterance != nil && (utterance?.text != value.text || utterance?.speaker != value.speaker || displayedName != name)
        utterance = value
        displayedName = name
        displayedTimeline = timeline
        nameLabel.stringValue = name
        timeLabel.stringValue = timeline.clock(at: value.start)
        timeLabel.toolTip = TranscriptRenderer.clock(value.start)
        avatar.slot = value.speaker
        avatar.initial = value.speaker.map { names.customName(for: $0) == nil ? SpeakerNames.letter(for: $0) : String(name.prefix(1)) } ?? "?"
        avatar.setAccessibilityLabel(name)
        avatar.needsDisplay = true
        setBody(value.text)
        return changed
    }
    func updateTentative(_ text: String) {
        // 同じビューを保ち、確定行のフェードや点灯は適用しない。
        nameLabel.stringValue = "聞き取り中…"
        timeLabel.stringValue = ""
        setBody(text)
    }
    private func setBody(_ text: String) {
        guard body.stringValue != text else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        body.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: tentative ? Washi.tentative : Washi.ink,
            .paragraphStyle: paragraph
        ])
        measuredWidth = -1
    }
    func height(for width: CGFloat) -> CGFloat {
        if measuredWidth != width {
            // NSTextFieldの内側余白まで含めて測る。文字列だけのboundingRectでは
            // 折り返し境界の数pt差で最終行が切れるため、描画するセル自身に問い合わせる。
            let size = body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(44, width - 74), height: .greatestFiniteMagnitude)) ?? .zero
            measuredHeight = max(20, ceil(size.height)) + 36
            measuredWidth = width
        }
        return measuredHeight
    }
    override func layout() {
        super.layout()
        shade.frame = NSRect(x: 12, y: 2, width: max(0, bounds.width - 24), height: bounds.height - 4)
        flash.frame = shade.frame
        avatar.frame = NSRect(x: 20, y: 8, width: 25, height: 26)
        let nameWidth = min(nameLabel.intrinsicContentSize.width, max(70, bounds.width - 220))
        nameLabel.frame = NSRect(x: 54, y: 8, width: nameWidth, height: 18)
        timeLabel.frame = NSRect(x: 54 + nameWidth + 12, y: 8, width: 62, height: 18)
        hint.frame = NSRect(x: bounds.width - 150, y: 8, width: 130, height: 18)
        body.frame = NSRect(x: 54, y: 31, width: max(44, bounds.width - 74), height: max(20, bounds.height - 36))
    }
    func appear(animated: Bool) {
        guard animated else { stopAnimations(); return }
        animateOpacity(layer, from: 0, to: 1, duration: 0.25)
    }
    func highlight(animated: Bool) {
        guard animated else { stopAnimations(); return }
        animateOpacity(flash.layer, from: 1, to: 0, duration: 1.25)
    }
    private func animateOpacity(_ layer: CALayer?, from: Float, to: Float, duration: TimeInterval) {
        guard let layer else { return }
        // 新規ビューを追加した同じ描画周期でも開始値を失わないよう、明示的なfrom/toを使う。
        layer.removeAnimation(forKey: "transcriptOpacity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = to
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "transcriptOpacity")
    }
    func stopAnimations() {
        layer?.removeAllAnimations()
        flash.layer?.removeAllAnimations()
        layer?.opacity = 1
        flash.layer?.opacity = 0
    }
}

private final class CopyBoundary: NSView, DocumentRow {
    override var isFlipped: Bool { true }
    func height(for width: CGFloat) -> CGFloat { 32 }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Washi.muted]
        let text = "次にコピーする範囲" as NSString
        let size = text.size(withAttributes: attributes)
        let x = (bounds.width - size.width) / 2
        Washi.rule.setFill()
        NSRect(x: 56, y: 15, width: max(0, x - 68), height: 0.5).fill()
        NSRect(x: x + size.width + 12, y: 15, width: max(0, bounds.width - x - size.width - 32), height: 0.5).fill()
        text.draw(at: NSPoint(x: x, y: 7), withAttributes: attributes)
    }
}

/// 行ビューを再利用する。再配置は高さの加算だけで、本文の計測は変更行だけに限る。
private final class TranscriptDocument: NSView {
    override var isFlipped: Bool { true }
    var rows: [any DocumentRow] = []
    private var layingOut = false
    struct Anchor {
        let candidates: [(NSView, CGFloat)]
        let y: CGFloat
        let atBottom: Bool
    }
    func anchor() -> Anchor {
        let clip = enclosingScrollView?.contentView.bounds ?? .zero
        let candidates = rows.filter { $0.frame.maxY > clip.minY }.map { ($0 as NSView, $0.frame.minY - clip.minY) }
        return Anchor(candidates: candidates, y: clip.minY, atBottom: clip.maxY >= frame.height - 24)
    }
    func setRows(_ rows: [any DocumentRow], anchor: Anchor) {
        let keep = Set(rows.map { ObjectIdentifier($0) })
        for view in subviews where !keep.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for row in rows where row.superview !== self { addSubview(row) }
        self.rows = rows
        reflow(anchor: anchor)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        let before = anchor()
        super.setFrameSize(newSize)
        if oldWidth != newSize.width && !layingOut { reflow(anchor: before) }
    }
    func reflow(anchor: Anchor) {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        guard let scroll = enclosingScrollView else { return }
        let width = scroll.contentSize.width
        var y: CGFloat = 8
        for row in rows {
            let height = row.height(for: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            row.needsLayout = true
            y += height
        }
        setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, y + 8)))
        let surviving = anchor.candidates.first { $0.0.superview === self }
        let target = anchor.atBottom ? frame.height - scroll.contentSize.height
            : surviving.map { $0.0.frame.minY - $0.1 } ?? anchor.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(target, frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
final class TranscriptWindowController: NSWindowController {
    var onRename: ((SpeakerNames) -> Void)?
    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onCopy: ((Bool) -> Void)?
    var onRecopy: (() -> Void)?
    var onOpenMarkdown: (() -> Void)?
    private let startStopButton = NSButton()
    private let pauseButton = NSButton()
    private let openButton = NSButton()
    // 段3までは一括改名を維持。右上はほかの操作と同じアイコンにする。
    private let namesButton = NSButton()
    private let copyButton = CopyButton(title: "会話をコピー", target: nil, action: nil)
    private let moreButton = NSButton(title: "別の範囲をコピー ▾", target: nil, action: nil)
    private let latestButton = NSButton(title: "最新の発言へ ↓", target: nil, action: nil)
    private let statusDot = RecordingMark()
    private let statusLabel = Washi.label(size: 13, weight: .semibold)
    private let elapsedLabel = Washi.label(color: Washi.muted)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let rangeLabel = Washi.label(color: Washi.muted)
    private let handoffLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyView = NSStackView()
    private let emptyLabel = Washi.label(size: 13, color: Washi.muted)
    private let scrollView = NSScrollView()
    private let transcriptDocument = TranscriptDocument()
    private let boundary = CopyBoundary()
    private let tentativeRow = TranscriptRow(tentative: true)
    private var snapshot = SessionSnapshot()
    private var namesSheet: SpeakerNamesSheet?
    // 開始時刻が重複しても落とさず、同時刻の出現順で別ビューとして扱う。
    private struct RowID: Hashable { let start: Double; let occurrence: Int }
    private var rows: [RowID: TranscriptRow] = [:]
    private let shouldReduceMotion: () -> Bool

    init(shouldReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.shouldReduceMotion = shouldReduceMotion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 578),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "KIKIGAKI"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Washi.shade
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 460)
        window.center()
        window.setFrameAutosaveName("KikigakiTranscript")
        super.init(window: window)
        window.contentView = buildContent()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func show() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    func apply(_ value: SessionSnapshot) {
        let previous = snapshot
        snapshot = value
        if value.state == .preparing { namesSheet?.cancel() }
        let startTitle = value.state == .idle && value.markdownURL != nil ? "新しい録音" : value.state.startStopTitle
        symbol(startStopButton, name: value.state.canStart ? "record.circle" : "stop.fill", title: startTitle)
        startStopButton.isEnabled = value.state.canStart || value.state.canStop
        symbol(pauseButton, name: value.state == .paused ? "play.fill" : "pause.fill", title: value.state.pauseResumeTitle)
        pauseButton.isEnabled = value.state.canPauseOrResume
        pauseButton.isHidden = value.state == .idle && value.markdownURL != nil
        openButton.isHidden = !(value.state == .idle && value.saved)
        namesButton.isEnabled = value.canShare
        statusLabel.stringValue = value.state == .idle && value.saved ? "保存済み" : value.state.statusLabel
        statusDot.isHidden = value.state != .recording && value.state != .paused
        statusDot.paused = value.state == .paused
        elapsedLabel.stringValue = TranscriptRenderer.clock(value.elapsed)
        var message = value.message ?? ""
        if value.saved, message.hasPrefix("保存:") {
            message = message.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        }
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        messageLabel.textColor = value.state == .idle && !value.saved && !message.isEmpty ? Washi.red : Washi.muted
        copyButton.title = value.hasCopied ? "前回コピー以降をコピー" : "会話をコピー"
        copyButton.isEnabled = value.canShare && value.handoffPreview != nil
        copyButton.attributedTitle = NSAttributedString(string: copyButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: copyButton.isEnabled ? NSColor.white : Washi.muted
        ])
        moreButton.isEnabled = value.canShare && (value.hasCopied || !value.utterances.isEmpty)
        if let preview = value.handoffPreview {
            let end = value.state == .idle ? "終了" : "現在"
            let correction = preview.includesCorrections ? "訂正を含む · " : ""
            rangeLabel.stringValue = correction + value.timeline.clock(at: preview.startTime)
                + " 〜 " + end + " " + value.timeline.clock(at: value.elapsed)
        } else { rangeLabel.stringValue = value.hasCopied ? "前回コピーから変更なし" : "発言を待っています" }
        rangeLabel.toolTip = rangeLabel.stringValue
        handoffLabel.stringValue = value.handoffMessage ?? ""
        handoffLabel.isHidden = handoffLabel.stringValue.isEmpty
        handoffLabel.textColor = value.handoffFailed ? Washi.red : Washi.muted
        emptyView.isHidden = !value.utterances.isEmpty || value.tentativeText != nil
        emptyLabel.stringValue = value.state == .idle ? "録音を開始すると、会話がここに表示されます。" : "発言を待っています…"
        updateRows(previous: previous)
    }

    private func updateRows(previous: SessionSnapshot) {
        var anchor = transcriptDocument.anchor()
        let sameMeeting = previous.timeline.startedAt == snapshot.timeline.startedAt
        if !sameMeeting { rows.removeAll(); anchor = .init(candidates: [], y: 0, atBottom: true) }
        let animated = sameMeeting && !shouldReduceMotion()
        var next: [RowID: TranscriptRow] = [:]
        var ordered: [any DocumentRow] = []
        var occurrences: [Double: Int] = [:]
        var inserted: [TranscriptRow] = []
        var changed: [TranscriptRow] = []
        for (index, utterance) in snapshot.utterances.enumerated() {
            if snapshot.hasCopied, snapshot.handoffPreview?.startLine == index + 1 { ordered.append(boundary) }
            let occurrence = occurrences[utterance.start, default: 0]
            occurrences[utterance.start] = occurrence + 1
            let id = RowID(start: utterance.start, occurrence: occurrence)
            let row = rows[id] ?? TranscriptRow()
            if rows[id] == nil { inserted.append(row) }
            if row.update(utterance, names: snapshot.names, timeline: snapshot.timeline) { changed.append(row) }
            next[id] = row
            ordered.append(row)
        }
        if let tentative = snapshot.tentativeText {
            tentativeRow.updateTentative(tentative)
            ordered.append(tentativeRow)
        }
        rows = next
        transcriptDocument.setRows(ordered, anchor: anchor)
        for row in inserted {
            row.appear(animated: animated && snapshot.state == .recording)
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
        configure(namesButton, #selector(namesPressed))
        configure(copyButton, #selector(copyPressed))
        configure(moreButton, #selector(morePressed))
        configure(latestButton, #selector(latestPressed))
        for button in [startStopButton, pauseButton, openButton, namesButton] {
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        symbol(openButton, name: "doc.text", title: "Markdownを開く")
        symbol(namesButton, name: "person.text.rectangle", title: "話者名…")
        copyButton.isBordered = false
        copyButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        copyButton.toolTip = "会話ファイルへの参照と、今回読む範囲をクリップボードにコピー"
        latestButton.isHidden = true
        latestButton.controlSize = .small
        statusDot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 9).isActive = true
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.lineBreakMode = .byTruncatingMiddle
        rangeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handoffLabel.font = .systemFont(ofSize: 12)
        handoffLabel.maximumNumberOfLines = 2
        let logoRule = NSView()
        Washi.surface(logoRule, color: Washi.rule)
        logoRule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        logoRule.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let status = row([statusDot, statusLabel, elapsedLabel], spacing: 8)
        let controls = row([Washi.logoView(size: 26), logoRule, status, NSView(), pauseButton, startStopButton, openButton, namesButton], spacing: 12)
        let header = column([controls, messageLabel], spacing: 8, inset: 12)
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
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: body.topAnchor), scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            emptyView.centerXAnchor.constraint(equalTo: body.centerXAnchor), emptyView.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            latestButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -20),
            latestButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        let title = Washi.label("AIへ渡す会話", size: 13, weight: .semibold)
        let footerTitle = row([title, NSView(), rangeLabel], spacing: 12)
        let buttons = row([copyButton, moreButton], spacing: 12)
        copyButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let notification = NSView()
        notification.heightAnchor.constraint(equalToConstant: 30).isActive = true
        notification.addSubview(handoffLabel)
        handoffLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            handoffLabel.leadingAnchor.constraint(equalTo: notification.leadingAnchor),
            handoffLabel.trailingAnchor.constraint(equalTo: notification.trailingAnchor),
            handoffLabel.topAnchor.constraint(equalTo: notification.topAnchor)
        ])
        let footer = column([footerTitle, buttons, notification], spacing: 8, inset: 16)
        Washi.surface(footer)
        return column([header, separator(), body, separator(), footer], spacing: 0, inset: 0)
    }
    private func symbol(_ button: NSButton, name: String, title: String) {
        // Apple CoreGlyphsのname_availability.plistとNSImage APIで存在を確認した名称。
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.title = title
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
    @objc private func pausePressed() { onPauseResume?() }
    @objc private func openPressed() { onOpenMarkdown?() }
    @objc private func copyPressed() { onCopy?(false) }
    @objc private func recopyPressed() { onRecopy?() }
    @objc private func fullCopyPressed() { onCopy?(true) }
    @objc private func latestPressed() {
        transcriptDocument.scroll(NSPoint(x: 0, y: max(0, transcriptDocument.frame.height - scrollView.contentSize.height)))
        latestButton.isHidden = true
    }
    @objc private func scrolled() {
        latestButton.isHidden = transcriptDocument.anchor().atBottom || (snapshot.utterances.isEmpty && snapshot.tentativeText == nil)
    }
    @objc private func motionChanged() {
        if shouldReduceMotion() { rows.values.forEach { $0.stopAnimations() } }
    }
    @objc private func morePressed() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let recopy = NSMenuItem(title: "直前の範囲を再コピー", action: #selector(recopyPressed), keyEquivalent: "")
        recopy.target = self
        recopy.isEnabled = snapshot.hasCopied
        menu.addItem(recopy)
        let full = NSMenuItem(title: "会議の最初からコピー", action: #selector(fullCopyPressed), keyEquivalent: "")
        full.target = self
        full.isEnabled = snapshot.hasCopied || !snapshot.utterances.isEmpty
        menu.addItem(full)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }
    @objc private func namesPressed() {
        guard namesSheet == nil, let window else { return }
        let sheet = SpeakerNamesSheet(names: snapshot.names)
        namesSheet = sheet
        sheet.present(on: window) { [weak self] names in
            self?.namesSheet = nil
            if let names { self?.onRename?(names) }
        }
    }
}

/// 段3のクリック改名へ移すまでは、既存の一括改名を維持する。
@MainActor
final class SpeakerNamesSheet: NSObject {
    let window: NSWindow
    private var fields: [NSTextField] = []
    private var completion: ((SpeakerNames?) -> Void)?
    init(names: SpeakerNames) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 165 + CGFloat(SpeakerNames.slotCount) * 30),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "話者名を編集"
        super.init()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(Washi.label("会話全体に反映します。停止後は保存も更新します。", color: Washi.muted))
        for slot in 0..<SpeakerNames.slotCount {
            let label = Washi.label(SpeakerNames.letter(for: slot))
            label.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let field = NSTextField(string: names.customName(for: slot) ?? "")
            field.placeholderString = SpeakerNames.defaultName(for: slot)
            field.setAccessibilityLabel("話者" + SpeakerNames.letter(for: slot) + "の名前")
            fields.append(field)
            let row = NSStackView(views: [label, field])
            row.spacing = 12
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "反映する", target: self, action: #selector(applyPressed))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
        ])
        window.contentView = content
    }
    func present(on parent: NSWindow, completion: @escaping (SpeakerNames?) -> Void) {
        self.completion = completion
        parent.beginSheet(window) { [weak self] response in
            guard let self else { return }
            var names = SpeakerNames()
            for (i, field) in self.fields.enumerated() { names.set(field.stringValue, for: i) }
            self.completion?(response == .OK ? names : nil)
            self.completion = nil
        }
        window.makeFirstResponder(fields.first)
    }
    func cancel() { window.sheetParent?.endSheet(window, returnCode: .cancel) }
    @objc private func cancelPressed() { cancel() }
    @objc private func applyPressed() { window.makeFirstResponder(nil); window.sheetParent?.endSheet(window, returnCode: .OK) }
}
