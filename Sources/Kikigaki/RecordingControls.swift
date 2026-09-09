import AppKit
import QuartzCore
import KikigakiCore

/// 操作・メニュー・キーボードフォーカスはNSButtonに任せ、地と文字色だけを揃える。
final class WashiActionButton: HoverButton {
    override var drawsHoverBackground: Bool { false }
    enum Emphasis { case primary, accentOutline, neutralOutline, secondary }
    var emphasis: Emphasis = .secondary { didSet { refreshStyle() } }

    func refreshStyle() {
        let foreground: NSColor = !isEnabled ? Washi.muted
            : emphasis == .primary ? Washi.white
            : emphasis == .accentOutline ? Washi.red : Washi.ink
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: foreground
        ])
        contentTintColor = foreground
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if !isEnabled {
            if emphasis == .primary {
                Washi.rule.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        } else if emphasis == .primary {
            (isHighlighted || isHovered ? Washi.brightRed : Washi.red).setFill()
            path.fill()
        } else {
            if isHighlighted || isHovered { Washi.rule.withAlphaComponent(0.45).setFill(); path.fill() }
            if emphasis != .secondary {
                (emphasis == .accentOutline ? Washi.red : Washi.muted).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        super.draw(dirtyRect)
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
