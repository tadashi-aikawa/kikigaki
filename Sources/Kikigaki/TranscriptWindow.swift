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
    static let searchMatch = color(0xE09C3C).withAlphaComponent(0.25)
    static let searchCurrent = color(0xE09C3C).withAlphaComponent(0.6)
    struct SpeakerColor { let background: NSColor; let foreground: NSColor }
    static let slots = [SpeakerColor(background: red, foreground: paper),
                        SpeakerColor(background: color(0xC4801F), foreground: ink),
                        SpeakerColor(background: color(0x514A43), foreground: paper),
                        SpeakerColor(background: color(0x3E706C), foreground: paper)]
    static func speakerColor(for slot: Int?) -> SpeakerColor {
        guard let slot, slot >= 0 else { return SpeakerColor(background: muted, foreground: paper) }
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
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 32, height: size.height)
    }
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

/// 画像もイニシャルも同じ吹き出し形にする。
private final class AvatarView: NSView {
    override var isFlipped: Bool { true }
    var initial = "?"
    var slot: Int?
    var tentative = false
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.scale(by: min(bounds.width / 25, bounds.height / 26))
        transform.concat()
        if tentative {
            Washi.muted.setStroke()
            let dashed = NSBezierPath(ovalIn: NSRect(x: 0.875, y: 0.875, width: 22.25, height: 22.25))
            dashed.lineWidth = 1.75
            dashed.setLineDash([3, 2], count: 2, phase: 0)
            dashed.stroke()
            return
        }
        let color = Washi.speakerColor(for: slot)
        color.background.setFill()
        let shape = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 24, height: 24))
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 3, y: 18))
        tail.line(to: NSPoint(x: 8, y: 22))
        tail.line(to: NSPoint(x: 1, y: 25))
        tail.close()
        shape.append(tail)
        shape.windingRule = .nonZero
        shape.fill()
        if let image {
            shape.addClip()
            let scale = max(25 / image.size.width, 26 / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (25 - size.width) / 2, y: (26 - size.height) / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color.foreground]
        let size = (initial as NSString).size(withAttributes: attributes)
        (initial as NSString).draw(at: NSPoint(x: 12 - size.width / 2, y: 12 - size.height / 2), withAttributes: attributes)
    }
}

private final class SpeakerButton: NSButton {
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            Washi.rule.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
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
    private let speakerButton = SpeakerButton()
    var onRename: ((Int, NSView) -> Void)?
    private var utterance: Utterance?
    private var displayedName = ""
    private var displayedTimeline: MeetingTimeline?
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    private var searchStyle: SearchStyle?
    private struct SearchStyle: Equatable {
        let name: String; let text: String
        let nameRanges: [NSRange]; let textRanges: [NSRange]
        let currentName: NSRange?; let currentText: NSRange?
    }
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
        nameLabel.lineBreakMode = .byTruncatingTail
        if tentative { nameLabel.font = .systemFont(ofSize: 12) }
        hint.isHidden = !tentative
        for view in [avatar, nameLabel, timeLabel, hint, body] { addSubview(view) }
        speakerButton.isBordered = false
        speakerButton.title = ""
        speakerButton.target = self
        speakerButton.action = #selector(renamePressed)
        speakerButton.isHidden = true
        addSubview(speakerButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func renamePressed() {
        if let slot = utterance?.speaker { onRename?(slot, speakerButton) }
    }
    func updateAvatar(speakers: [KikigakiConfig.Speaker], store: AvatarStore, editable: Bool) {
        let source = utterance?.speaker == nil ? nil : speakers.first { $0.name == displayedName }?.avatar
        avatar.image = store.image(for: source)
        speakerButton.isHidden = tentative || utterance?.speaker == nil
        speakerButton.isEnabled = editable
        speakerButton.toolTip = "\(displayedName)の名前を変更"
        speakerButton.setAccessibilityLabel(speakerButton.toolTip)
    }

    /// 本文・話者変更だけを点灯対象とする。時刻の再描画では点灯しない。
    @discardableResult
    func update(_ value: Utterance, names: SpeakerNames, timeline: MeetingTimeline) -> Bool {
        let name = names.name(for: value.speaker)
        guard utterance != value || displayedName != name || displayedTimeline != timeline else { return false }
        let changed = utterance != nil && (utterance?.text != value.text || utterance?.speaker != value.speaker || displayedName != name)
        utterance = value
        displayedName = name
        displayedTimeline = timeline
        searchStyle = nil
        nameLabel.stringValue = name
        timeLabel.stringValue = timeline.clock(at: value.start)
        timeLabel.toolTip = TranscriptRenderer.elapsed(value.start)
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
    func markSearch(nameRanges: [NSRange], textRanges: [NSRange], currentName: NSRange?, currentText: NSRange?) {
        let style = SearchStyle(name: nameLabel.stringValue, text: body.stringValue, nameRanges: nameRanges,
                                textRanges: textRanges, currentName: currentName, currentText: currentText)
        guard searchStyle != style else { return }
        searchStyle = style
        for (label, ranges, current) in [(nameLabel, nameRanges, currentName), (body, textRanges, currentText)] {
            let value = NSMutableAttributedString(attributedString: label.attributedStringValue)
            value.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: value.length))
            for range in ranges { value.addAttribute(.backgroundColor, value: Washi.searchMatch, range: range) }
            if let current { value.addAttribute(.backgroundColor, value: Washi.searchCurrent, range: current) }
            label.attributedStringValue = value
        }
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
        // 太字の字形が計測幅の右端へ届くため、端数の丸めと描画の余白を確保する。
        let nameWidth = min(ceil(nameLabel.intrinsicContentSize.width) + 4, max(70, bounds.width - 220))
        nameLabel.frame = NSRect(x: 54, y: 8, width: nameWidth, height: 18)
        speakerButton.frame = NSRect(x: 18, y: 5, width: nameWidth + 40, height: 29)
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
    var followsBottom = true
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
        let target = anchor.atBottom && followsBottom ? frame.height - scroll.contentSize.height
            : surviving.map { $0.0.frame.minY - $0.1 } ?? anchor.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(target, frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
final class TranscriptWindowController: NSWindowController, NSSearchFieldDelegate, NSMenuItemValidation {
    var onRename: ((Int, String) -> Void)?
    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onCopy: ((Bool) -> Void)?
    var onRecopy: (() -> Void)?
    var onOpenMarkdown: (() -> Void)?
    private let startStopButton = NSButton()
    private let pauseButton = NSButton()
    private let openButton = NSButton()
    private let copyButton = CopyButton(title: "会話をコピー", target: nil, action: nil)
    private let latestButton = NSButton(title: "最新の発言へ ↓", target: nil, action: nil)
    private let statusDot = RecordingMark()
    private let statusLabel = Washi.label(size: 13, weight: .semibold)
    private let elapsedLabel = Washi.label(color: Washi.muted)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let rangeLabel = Washi.label(color: Washi.muted)
    private var handoffNotice: (text: String, failed: Bool)?
    private var noticeDismissal: DispatchWorkItem?
    private var copyRequested = false
    private let emptyView = NSStackView()
    private let emptyLabel = Washi.label(size: 13, color: Washi.muted)
    private let scrollView = NSScrollView()
    private let transcriptDocument = TranscriptDocument()
    private let boundary = CopyBoundary()
    private let tentativeRow = TranscriptRow(tentative: true)
    private var snapshot = SessionSnapshot()
    private let avatars = AvatarStore()
    private var renamePopover: SpeakerPopover?
    private let searchField = NSSearchField()
    private let searchCount = Washi.label(color: Washi.muted)
    private let searchBar = NSStackView()
    private let searchPrevious = NSButton(title: "↑", target: nil, action: nil)
    private let searchNext = NSButton(title: "↓", target: nil, action: nil)
    private var searchOpen = false
    private struct SearchHit: Equatable {
        let row: RowID
        let rowIndex: Int
        let inName: Bool
        let range: NSRange
    }
    private var searchHits: [SearchHit] = []
    private var currentHit: Int?
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
        avatars.onChange = { [weak self] in
            guard let self else { return }
            for row in rows.values { row.updateAvatar(speakers: snapshot.speakers, store: avatars, editable: snapshot.canShare) }
            renamePopover?.refreshAvatars()
        }
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
        if previous.state != value.state || previous.timeline.startedAt != value.timeline.startedAt { clearHandoffNotice() }
        if copyRequested || previous.handoffMessage != value.handoffMessage || previous.handoffFailed != value.handoffFailed {
            clearHandoffNotice()
            if let text = value.handoffMessage, !text.isEmpty {
                handoffNotice = (text, value.handoffFailed)
                if !value.handoffFailed {
                    let dismissal = DispatchWorkItem { [weak self] in
                        self?.handoffNotice = nil
                        self?.updateRangeLabel()
                    }
                    noticeDismissal = dismissal
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissal)
                }
            }
        }
        if value.state == .preparing || previous.timeline.startedAt != value.timeline.startedAt { renamePopover?.close() }
        let startTitle = value.state == .idle && value.markdownURL != nil ? "新しい録音" : value.state.startStopTitle
        symbol(startStopButton, name: value.state.canStart ? "record.circle" : "stop.fill", title: startTitle)
        startStopButton.isEnabled = value.state.canStart || value.state.canStop
        symbol(pauseButton, name: value.state == .paused ? "play.fill" : "pause.fill", title: value.state.pauseResumeTitle)
        pauseButton.isEnabled = value.state.canPauseOrResume
        pauseButton.isHidden = value.state == .idle && value.markdownURL != nil
        openButton.isHidden = !(value.state == .idle && value.saved)
        statusLabel.stringValue = value.state == .idle && value.saved ? "保存済み" : value.state.statusLabel
        statusDot.isHidden = value.state != .recording && value.state != .paused
        statusDot.paused = value.state == .paused
        elapsedLabel.stringValue = TranscriptRenderer.elapsed(value.elapsed)
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
        copyButton.menu = handoffMenu()
        updateRangeLabel()
        emptyView.isHidden = !value.utterances.isEmpty || value.tentativeText != nil
        emptyLabel.stringValue = value.state == .idle ? "録音を開始すると、会話がここに表示されます。" : "発言を待っています…"
        updateRows(previous: previous)
        refreshSearch(reset: previous.timeline.startedAt != value.timeline.startedAt, reveal: false)
    }

    private func clearHandoffNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        handoffNotice = nil
    }
    private func updateRangeLabel() {
        if let notice = handoffNotice {
            rangeLabel.stringValue = notice.text
            rangeLabel.textColor = notice.failed ? Washi.red : Washi.muted
        } else {
            rangeLabel.textColor = Washi.muted
            if let preview = snapshot.handoffPreview {
                let end = snapshot.state == .idle ? "終了" : "現在"
                let correction = preview.includesCorrections ? "訂正を含む · " : ""
                rangeLabel.stringValue = correction + snapshot.timeline.clock(at: preview.startTime)
                    + " 〜 " + end + " " + snapshot.timeline.clock(at: snapshot.elapsed)
            } else { rangeLabel.stringValue = snapshot.hasCopied ? "前回コピーから変更なし" : "発言を待っています" }
        }
        rangeLabel.toolTip = rangeLabel.stringValue
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
            row.updateAvatar(speakers: snapshot.speakers, store: avatars, editable: snapshot.canShare)
            row.onRename = { [weak self] slot, view in self?.showRename(slot: slot, relativeTo: view) }
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
        configure(copyButton, #selector(copyPressed))
        configure(latestButton, #selector(latestPressed))
        for button in [startStopButton, pauseButton, openButton] {
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        symbol(openButton, name: "doc.plaintext", title: "Markdownを開く")
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
        let logoRule = NSView()
        Washi.surface(logoRule, color: Washi.rule)
        logoRule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        logoRule.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let status = row([statusDot, statusLabel, elapsedLabel], spacing: 8)
        let controls = row([Washi.logoView(size: 26), logoRule, status, NSView(), pauseButton, startStopButton, openButton], spacing: 12)
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
        copyButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = column([footerTitle, copyButton], spacing: 8, inset: 16)
        Washi.surface(footer)
        searchField.placeholderString = "会話を検索"
        searchField.setAccessibilityLabel("会話を検索")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchCount.widthAnchor.constraint(equalToConstant: 90).isActive = true
        configure(searchPrevious, #selector(findPrevious(_:)))
        configure(searchNext, #selector(findNext(_:)))
        searchPrevious.toolTip = "前を検索 (Shift+Return)"
        searchNext.toolTip = "次を検索 (Return)"
        searchPrevious.setAccessibilityLabel("前を検索")
        searchNext.setAccessibilityLabel("次を検索")
        let close = NSButton(title: "完了", target: self, action: #selector(closeSearch(_:)))
        close.bezelStyle = .rounded
        searchBar.orientation = .horizontal
        searchBar.alignment = .centerY
        searchBar.spacing = 8
        searchBar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        for view in [searchField, searchCount, searchPrevious, searchNext, close] { searchBar.addArrangedSubview(view) }
        Washi.surface(searchBar)
        searchBar.isHidden = true
        return column([header, searchBar, separator(), body, separator(), footer], spacing: 0, inset: 0)
    }

    @objc func showSearch(_ sender: Any?) {
        let anchor = transcriptDocument.anchor()
        searchOpen = true
        transcriptDocument.followsBottom = false
        searchBar.isHidden = false
        window?.contentView?.layoutSubtreeIfNeeded()
        transcriptDocument.reflow(anchor: anchor)
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        refreshSearch(reset: false, reveal: true)
    }
    @objc func closeSearch(_ sender: Any?) {
        guard searchOpen else { return }
        let anchor = transcriptDocument.anchor()
        searchOpen = false
        searchBar.isHidden = true
        window?.makeFirstResponder(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        transcriptDocument.followsBottom = true
        transcriptDocument.reflow(anchor: anchor)
        refreshSearch(reset: true, reveal: false)
        scrolled()
    }
    @objc func findNext(_ sender: Any?) { moveSearch(by: 1) }
    @objc func findPrevious(_ sender: Any?) { moveSearch(by: -1) }
    private func moveSearch(by direction: Int) {
        if !searchOpen { showSearch(nil); return }
        guard !searchHits.isEmpty else { return }
        currentHit = ((currentHit ?? 0) + direction + searchHits.count) % searchHits.count
        paintSearch()
        revealCurrentHit()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        refreshSearch(reset: true, reveal: true)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeSearch(nil); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertLineBreak(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            moveSearch(by: NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            return true
        }
        return false
    }
    override func cancelOperation(_ sender: Any?) {
        if searchOpen { closeSearch(sender) } else { super.cancelOperation(sender) }
    }
    private func refreshSearch(reset: Bool, reveal: Bool) {
        let previous = currentHit.flatMap { searchHits.indices.contains($0) ? searchHits[$0] : nil }
        searchHits = []
        if searchOpen, !searchField.stringValue.isEmpty {
            var occurrences: [Double: Int] = [:]
            for (index, utterance) in snapshot.utterances.enumerated() {
                let occurrence = occurrences[utterance.start, default: 0]
                occurrences[utterance.start] = occurrence + 1
                let id = RowID(start: utterance.start, occurrence: occurrence)
                for (inName, text) in [(true, snapshot.names.name(for: utterance.speaker)), (false, utterance.text)] {
                    for range in TranscriptSearch.ranges(in: text, query: searchField.stringValue) {
                        searchHits.append(SearchHit(row: id, rowIndex: index, inName: inName, range: NSRange(range, in: text)))
                    }
                }
            }
        }
        if searchHits.isEmpty { currentHit = nil }
        else if !reset, let previous {
            let sameRow = searchHits.indices.filter { searchHits[$0].row == previous.row }
            currentHit = sameRow.min { a, b in
                let left = searchHits[a], right = searchHits[b]
                if (left.inName == previous.inName) != (right.inName == previous.inName) { return left.inName == previous.inName }
                return abs(left.range.location - previous.range.location) < abs(right.range.location - previous.range.location)
            } ?? searchHits.indices.min { abs(searchHits[$0].rowIndex - previous.rowIndex) < abs(searchHits[$1].rowIndex - previous.rowIndex) }
        } else { currentHit = 0 }
        paintSearch()
        let rowDisappeared = previous.map { old in !searchHits.contains { $0.row == old.row } } ?? false
        if reveal || rowDisappeared || (previous == nil && currentHit != nil) { revealCurrentHit() }
    }
    private func paintSearch() {
        let current = currentHit.map { searchHits[$0] }
        let grouped = Dictionary(grouping: searchHits, by: \.row)
        for (id, row) in rows {
            let hits = grouped[id] ?? []
            row.markSearch(nameRanges: hits.filter(\.inName).map(\.range), textRanges: hits.filter { !$0.inName }.map(\.range),
                           currentName: current?.row == id && current?.inName == true ? current?.range : nil,
                           currentText: current?.row == id && current?.inName == false ? current?.range : nil)
        }
        searchCount.stringValue = currentHit.map { "\($0 + 1) / \(searchHits.count)" } ?? (searchField.stringValue.isEmpty ? "" : "一致なし")
        searchPrevious.isEnabled = !searchHits.isEmpty
        searchNext.isEnabled = !searchHits.isEmpty
    }
    private func revealCurrentHit() {
        guard let currentHit, let row = rows[searchHits[currentHit].row] else { return }
        let clip = scrollView.contentView.bounds
        if row.frame.minY < clip.minY || row.frame.maxY > clip.maxY {
            transcriptDocument.scroll(NSPoint(x: 0, y: max(0, min(row.frame.minY - 8, transcriptDocument.frame.height - clip.height))))
        }
        scrolled()
    }
    private func symbol(_ button: NSButton, name: String, title: String) {
        // Apple CoreGlyphsのname_availability.plistとNSImage APIで存在を確認した名称。
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.title = ""
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
    private func copyWithNotice(_ action: () -> Void) {
        clearHandoffNotice()
        updateRangeLabel()
        copyRequested = true
        action()
        copyRequested = false
    }
    @objc private func copyPressed() { copyWithNotice { onCopy?(false) } }
    @objc func recopyPressed() {
        guard snapshot.canShare && snapshot.hasCopied else { return }
        copyWithNotice { onRecopy?() }
    }
    @objc func fullCopyPressed() {
        guard snapshot.canShare && (snapshot.hasCopied || !snapshot.utterances.isEmpty) else { return }
        copyWithNotice { onCopy?(true) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(recopyPressed) { return snapshot.canShare && snapshot.hasCopied }
        if menuItem.action == #selector(fullCopyPressed) { return snapshot.canShare && (snapshot.hasCopied || !snapshot.utterances.isEmpty) }
        return true
    }
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
    private func handoffMenu() -> NSMenu {
        let menu = NSMenu()
        let recopy = NSMenuItem(title: "直前の範囲を再コピー", action: #selector(recopyPressed), keyEquivalent: "")
        recopy.target = self
        recopy.isEnabled = validateMenuItem(recopy)
        menu.addItem(recopy)
        let full = NSMenuItem(title: "会議の最初からコピー", action: #selector(fullCopyPressed), keyEquivalent: "")
        full.target = self
        full.isEnabled = validateMenuItem(full)
        menu.addItem(full)
        return menu
    }
    private func showRename(slot: Int, relativeTo view: NSView) {
        guard snapshot.canShare, (0..<SpeakerNames.slotCount).contains(slot) else { return }
        renamePopover?.close()
        let popover = SpeakerPopover(slot: slot, names: snapshot.names, speakers: snapshot.speakers, avatars: avatars)
        popover.onRename = { [weak self] name in self?.onRename?(slot, name) }
        renamePopover = popover
        // 行が再分割で消えても編集は維持するため、安定したscrollViewをアンカーにする。
        popover.present(relativeTo: scrollView.convert(view.bounds, from: view), of: scrollView)
    }
}

@MainActor
private final class SpeakerPopover: NSObject, NSTextFieldDelegate {
    private let popover = NSPopover()
    private let field = NSTextField()
    private let avatars: AvatarStore
    private var avatarRows: [(AvatarView, String?)] = []
    private let speakers: [KikigakiConfig.Speaker]
    var onRename: ((String) -> Void)?

    init(slot: Int, names: SpeakerNames, speakers: [KikigakiConfig.Speaker], avatars: AvatarStore) {
        self.avatars = avatars
        self.speakers = speakers
        super.init()
        popover.behavior = .transient
        popover.animates = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 204 + min(8, speakers.count) * 28))
        Washi.surface(content, color: Washi.paper)
        let title = Washi.label("話者\(SpeakerNames.letter(for: slot))の名前", size: 14, weight: .semibold)
        title.frame = NSRect(x: 18, y: content.bounds.height - 42, width: 260, height: 22)
        content.addSubview(title)
        let listHeight = CGFloat(min(8, speakers.count) * 28)
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 150, width: 272, height: listHeight))
        scroll.hasVerticalScroller = speakers.count > 8
        scroll.drawsBackground = false
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: speakers.count * 28))
        scroll.documentView = list
        content.addSubview(scroll)
        for (index, speaker) in speakers.enumerated() {
            let y = CGFloat((speakers.count - index - 1) * 28)
            let used = names.otherSlot(using: speaker.name, excluding: slot)
            let avatar = AvatarView(frame: NSRect(x: 4, y: y + 2, width: 22, height: 23))
            avatar.slot = used ?? slot
            avatar.initial = String(speaker.name.prefix(1))
            avatar.alphaValue = used == nil ? 1 : 0.45
            list.addSubview(avatar)
            avatarRows.append((avatar, speaker.avatar))
            let label = Washi.label(speaker.name, color: used == nil ? Washi.ink : Washi.muted)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 34, y: y + 5, width: used == nil ? 210 : 110, height: 18)
            list.addSubview(label)
            if let used {
                let hint = Washi.label("話者\(SpeakerNames.letter(for: used))で使用中", size: 10, color: Washi.muted)
                hint.frame = NSRect(x: 146, y: y + 5, width: 110, height: 18)
                list.addSubview(hint)
            }
            let button = SpeakerButton(frame: NSRect(x: 0, y: y, width: 256, height: 28))
            button.title = ""
            button.isBordered = false
            button.isEnabled = used == nil
            button.tag = index
            button.target = self
            button.action = #selector(candidatePressed(_:))
            button.setAccessibilityLabel(speaker.name + (used.map { "、話者\(SpeakerNames.letter(for: $0))で使用中" } ?? ""))
            button.toolTip = speaker.name
            list.addSubview(button)
        }
        list.scroll(NSPoint(x: 0, y: max(0, list.bounds.height - listHeight)))
        let inputLabel = Washi.label("自由に入力", color: Washi.muted)
        inputLabel.frame = NSRect(x: 18, y: 117, width: 260, height: 18)
        content.addSubview(inputLabel)
        field.frame = NSRect(x: 18, y: 82, width: 264, height: 26)
        field.stringValue = names.name(for: slot)
        field.placeholderString = SpeakerNames.defaultName(for: slot)
        field.setAccessibilityLabel("話者\(SpeakerNames.letter(for: slot))の名前")
        field.delegate = self
        content.addSubview(field)
        let reset = NSButton(title: "既定に戻す", target: self, action: #selector(resetPressed))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: 14, y: 30, width: 100, height: 26)
        content.addSubview(reset)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        refreshAvatars()
    }
    func present(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
    }
    func refreshAvatars() {
        for (view, source) in avatarRows { view.image = avatars.image(for: source) }
    }
    func close() { popover.close() }
    private func commit(_ name: String) { close(); onRename?(name) }
    @objc private func candidatePressed(_ sender: NSButton) { commit(speakers[sender.tag].name) }
    @objc private func resetPressed() { commit("") }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commit(field.stringValue); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
}
