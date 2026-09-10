import AppKit
import QuartzCore
import KikigakiCore

/// 操作・メニュー・キーボードフォーカスはNSButtonに任せ、地と文字色・内側余白を揃える。
final class WashiActionButton: HoverButton {
    override var drawsHoverBackground: Bool { false }
    // 自前の輪郭はboundsに描くため、標準ベゼルのalignment余白で34×32ptを膨らませない。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    enum Emphasis { case primary, accentOutline, goldOutline, neutralOutline, secondary }
    var emphasis: Emphasis = .secondary {
        didSet {
            guard emphasis != oldValue else { return }
            refreshStyle()
        }
    }
    private var appliedForeground: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = RecordingActionCell(textCell: "")
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var foreground: NSColor {
        let active = isHighlighted || isHovered
        return !isEnabled ? Washi.muted
            : emphasis == .primary ? Washi.white
            : emphasis == .accentOutline ? (active ? Washi.activeRedInk : Washi.red)
            : emphasis == .goldOutline ? (active ? Washi.activeGoldInk : Washi.goldInk) : Washi.ink
    }

    func refreshStyle() {
        let foreground = foreground
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: foreground
        ])
        contentTintColor = foreground
        appliedForeground = foreground
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // ホバー・押下の再描画にも追随する。色が変わるときだけ装飾を更新し、再描画を連鎖させない。
        if appliedForeground != foreground { refreshStyle() }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        let outline = emphasis == .primary || emphasis == .accentOutline ? Washi.red
            : emphasis == .goldOutline ? Washi.goldInk : Washi.muted
        if isEnabled {
            if emphasis == .primary {
                (isHighlighted ? Washi.pressedRed
                    : isHovered ? Washi.brightRed : Washi.red).setFill()
                path.fill()
            } else if isHighlighted || isHovered {
                outline.withAlphaComponent(isHighlighted ? 0.22 : 0.14).setFill()
                path.fill()
            }
        }
        // 無効時も操作の器は残し、面を足さず輪郭だけを罫色へ落とす。
        if emphasis != .secondary && !(emphasis == .primary && isEnabled) {
            (isEnabled ? outline : Washi.rule).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        super.draw(dirtyRect)
    }
}

/// 標準セルのimageHugsTitleは間隔を指定できないため、図と文字を8pt離した組で中央に置く。
/// 図の枠を16ptに揃え、文字を隠した34pt幅でも同じ中心を使う。
private final class RecordingActionCell: NSButtonCell {
    private var imageWidth: CGFloat { image == nil ? 0 : 16 }
    private var contentGap: CGFloat { imageWidth > 0 && labelSize.width > 0 ? 8 : 0 }
    private var labelSize: NSSize {
        imagePosition == .imageOnly ? .zero
            : NSSize(width: ceil(attributedTitle.size().width), height: ceil(attributedTitle.size().height))
    }
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        let totalWidth = imageWidth + contentGap + labelSize.width
        return NSRect(x: rect.midX - totalWidth / 2, y: rect.midY - 8, width: imageWidth, height: 16)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let size = labelSize
        return NSRect(x: imageRect(forBounds: rect).maxX + contentGap,
                      y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let image else { super.drawInterior(withFrame: cellFrame, in: controlView); return }
        drawImage(image, withFrame: imageRect(forBounds: cellFrame), in: controlView)
        if imagePosition != .imageOnly {
            _ = drawTitle(attributedTitle, withFrame: titleRect(forBounds: cellFrame), in: controlView)
        }
    }
}

/// 状態と経過時間を同じ地に置く。明滅は録音の点だけで、文字の読みやすさを保つ。
final class RecordingStatusChip: NSStackView {
    private let mark = Washi.label("●", size: 12)
    private let label = Washi.label(size: 13, weight: .semibold)
    private let elapsed = Washi.label(size: 12)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 7
        edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        wantsLayer = true
        layer?.cornerRadius = 6
        mark.wantsLayer = true
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        for view in [mark, label, elapsed] {
            view.setAccessibilityElement(false)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            addArrangedSubview(view)
        }
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ value: SessionSnapshot, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let recording = value.state == .recording
        let paused = value.state == .paused
        let outlined = value.state == .preparing || value.state == .finishing
        let foreground = recording ? Washi.white : paused ? Washi.ink : Washi.muted
        layer?.backgroundColor = (recording ? Washi.red : paused ? Washi.gold : .clear).cgColor
        layer?.borderColor = Washi.muted.cgColor
        layer?.borderWidth = outlined ? 1 : 0
        mark.stringValue = paused ? "‖" : "●"
        mark.isHidden = !recording && !paused
        label.stringValue = value.state == .idle && value.saved ? "保存済み"
            : value.state.statusLabel
        elapsed.stringValue = TranscriptRenderer.elapsed(value.elapsed)
        for view in [mark, label, elapsed] { view.textColor = foreground }
        // 毎秒届く経過時間でだけ明暗を切り替え、連続的な再合成を発生させない。
        // 同じ秒に音声更新が複数届いても位相は変えない。
        let opacity: Float = recording && !reduceMotion && Int(max(0, value.elapsed)) % 2 == 1 ? 0.45 : 1
        if mark.layer?.opacity != opacity { mark.layer?.opacity = opacity }
        setAccessibilityLabel([label.stringValue, elapsed.stringValue].joined(separator: " "))
    }
}
