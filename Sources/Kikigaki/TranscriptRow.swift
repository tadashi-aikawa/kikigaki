import AppKit
import QuartzCore
import KikigakiCore

/// 画像もイニシャルも同じ吹き出し形にする。
final class AvatarView: NSView {
    override var isFlipped: Bool { true }
    var initial = "?"
    var slot: Int?
    var tentative = false
    var typed = false
    /// 話者枡の代わりに使う色。AI参加者だけが指定する。
    var accent: Washi.SpeakerColor?
    /// typedのとき、鉛筆の代わりに描く記号。
    var glyph: NSImage?
    private let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: "手入力")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Washi.paper]))
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
        let color = accent ?? Washi.speakerColor(for: slot)
        (typed ? Washi.ink : color.background).setFill()
        let shape = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 24, height: 24))
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 3, y: 18))
        tail.line(to: NSPoint(x: 8, y: 22))
        tail.line(to: NSPoint(x: 1, y: 25))
        tail.close()
        if !typed { shape.append(tail) }
        shape.windingRule = .nonZero
        shape.fill()
        if typed {
            (glyph ?? pencil)?.draw(in: NSRect(x: 5, y: 5, width: 14, height: 14), from: .zero,
                                    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
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

final class SpeakerButton: HoverButton {}

final class TranscriptRow: NSView, DocumentRow {
    override var isFlipped: Bool { true }
    private let shade = NSView()
    private let flash = NSView()
    private let avatar = AvatarView()
    private let nameLabel = Washi.label(size: 12, weight: .semibold)
    private let timeLabel = Washi.label(color: Washi.muted)
    private let hint = Washi.label("コピーには含めません", size: 11, color: Washi.muted)
    private let body = NSTextField(wrappingLabelWithString: "")
    private let typedBody = TypedEntryBody()
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
    private var speakerPending = false

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
        if !tentative { Washi.surface(shade, color: Washi.shade.withAlphaComponent(0.45)) }
        flash.layer?.opacity = 0
        avatar.tentative = tentative
        body.font = .systemFont(ofSize: 15)
        body.isSelectable = true
        body.allowsEditingTextAttributes = true
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = tentative ? Washi.muted : Washi.ink
        nameLabel.lineBreakMode = .byTruncatingTail
        if tentative { nameLabel.font = .systemFont(ofSize: 12) }
        hint.isHidden = !tentative
        hint.alignment = .right
        typedBody.isHidden = true
        for view in [avatar, nameLabel, timeLabel, hint, body, typedBody] { addSubview(view) }
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
        let source = utterance?.kind == .typed || utterance?.speaker == nil ? nil : speakers.first { $0.name == displayedName }?.avatar
        avatar.image = store.image(for: source)
        speakerButton.isHidden = tentative || utterance?.kind == .typed || utterance?.speaker == nil
        speakerButton.isEnabled = editable
        speakerButton.toolTip = "\(displayedName)の名前を変更"
        speakerButton.setAccessibilityLabel(speakerButton.toolTip)
    }

    /// 本文・話者変更だけを点灯対象とする。時刻や話者固定待ちの変化では点灯しない。
    @discardableResult
    func update(_ value: Utterance, names: SpeakerNames, timeline: MeetingTimeline, speakerPending: Bool = false) -> Bool {
        let speakerPending = value.kind == .voice && speakerPending
        if !tentative && self.speakerPending != speakerPending {
            self.speakerPending = speakerPending
            shade.isHidden = !speakerPending
            hint.stringValue = "話者未確定"
            hint.toolTip = "文字起こしは確定していますが、話者の割り当てはまだ固定していません。"
            hint.isHidden = !speakerPending
            needsLayout = true
        }
        let name = names.displayName(for: value)
        guard utterance != value || displayedName != name || displayedTimeline != timeline else { return false }
        let changed = utterance != nil && (utterance?.text != value.text || utterance?.speaker != value.speaker || displayedName != name)
        utterance = value
        displayedName = name
        displayedTimeline = timeline
        searchStyle = nil
        nameLabel.stringValue = name
        timeLabel.stringValue = TranscriptRenderer.clock(for: value, timeline: timeline)
        timeLabel.toolTip = value.kind == .typed
            ? "会話の位置 \(TranscriptRenderer.elapsed(value.start)) · 投稿 \(TranscriptRenderer.clock(for: value, timeline: timeline, seconds: true))"
            : TranscriptRenderer.elapsed(value.start)
        avatar.slot = value.speaker
        avatar.typed = value.kind == .typed
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
        let style = SearchStyle(name: nameLabel.stringValue, text: utterance?.text ?? body.stringValue, nameRanges: nameRanges,
                                textRanges: textRanges, currentName: currentName, currentText: currentText)
        guard searchStyle != style else { return }
        searchStyle = style
        func highlighted(_ source: NSAttributedString, _ ranges: [NSRange], _ current: NSRange?) -> NSAttributedString {
            let value = NSMutableAttributedString(attributedString: source)
            value.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: value.length))
            for range in ranges { value.addAttribute(.backgroundColor, value: Washi.searchMatch, range: range) }
            if let current { value.addAttribute(.backgroundColor, value: Washi.searchCurrent, range: current) }
            return value
        }
        nameLabel.attributedStringValue = highlighted(nameLabel.attributedStringValue, nameRanges, currentName)
        if utterance?.kind == .typed {
            let selection = typedBody.selectedRanges
            typedBody.textStorage?.setAttributedString(highlighted(typedBody.attributedString(), textRanges, currentText))
            typedBody.selectedRanges = selection
        } else { body.attributedStringValue = highlighted(body.attributedStringValue, textRanges, currentText) }
    }
    private func setBody(_ text: String) {
        let typed = utterance?.kind == .typed
        guard (typed ? typedBody.string : body.stringValue) != text else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: tentative ? Washi.tentative : Washi.ink,
            .paragraphStyle: paragraph
        ])
        if utterance?.kind == .typed, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(location: 0, length: attributed.length)) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                attributed.addAttributes([.link: url, .foregroundColor: Washi.red,
                                          .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            }
        }
        typedBody.isHidden = !typed; body.isHidden = typed
        if typed {
            if typedBody.string != text { typedBody.textStorage?.setAttributedString(attributed) }
        } else { body.attributedStringValue = attributed }
        measuredWidth = -1
    }
    func height(for width: CGFloat) -> CGFloat {
        if measuredWidth != width {
            // NSTextFieldの内側余白まで含めて測る。文字列だけのboundingRectでは
            // 折り返し境界の数pt差で最終行が切れるため、描画するセル自身に問い合わせる。
            let size = body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(44, width - 74), height: .greatestFiniteMagnitude)) ?? .zero
            measuredHeight = max(20, typedBody.isHidden ? ceil(size.height) : typedBody.height(for: max(44, width - 74))) + 36
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
        let nameWidth = min(ceil(nameLabel.intrinsicContentSize.width) + 4,
                            max(70, bounds.width - (hint.isHidden ? 220 : 300)))
        nameLabel.frame = NSRect(x: 54, y: 8, width: nameWidth, height: 18)
        speakerButton.frame = NSRect(x: 18, y: 5, width: nameWidth + 40, height: 29)
        timeLabel.frame = NSRect(x: 54 + nameWidth + 12, y: 8, width: 62, height: 18)
        hint.frame = NSRect(x: bounds.width - 150, y: 8, width: 130, height: 18)
        body.frame = NSRect(x: 54, y: 31, width: max(44, bounds.width - 74), height: max(20, bounds.height - 36))
        typedBody.frame = body.frame
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
