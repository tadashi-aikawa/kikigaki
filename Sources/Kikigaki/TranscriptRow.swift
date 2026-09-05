import AppKit
import QuartzCore
import KikigakiCore

/// 画像もイニシャルも同じ吹き出し形にする。
final class AvatarView: NSView {
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

final class SpeakerButton: NSButton {
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

final class TranscriptRow: NSView, DocumentRow {
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
