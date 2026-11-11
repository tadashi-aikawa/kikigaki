import AppKit
import KikigakiCore

/// フッターの画面の操作に渡す状態。録音中と一時停止中で、画面を撮れる会議だけ持つ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「録音中の切り替え」
struct ScreenControlState: Equatable {
    /// フッターに出す状態。撮影を始められた時点で替わる。
    var display: ScreenTarget<ScreenDisplay>.Display
    /// 最後に選んだ対象。メニューの印はこちらに付ける。nilは「撮らない」。
    var selected: ScreenDisplay?
    var paused: Bool

    var title: String {
        switch display {
        case .off: return "撮らない"
        case let .on(display), let .failed(display): return display.name
        }
    }

    enum Tone { case recording, muted, failed }
    /// 撮っている間だけ墨で出す。撮らない・一時停止中は薄墨、撮れなくなったら朱。
    var tone: Tone {
        switch display {
        case .off: return .muted
        case .on: return paused ? .muted : .recording
        case .failed: return .failed
        }
    }

    /// 読み上げとツールチップ。見た目で分かる色の違いを言葉で補う。
    var summary: String {
        switch display {
        case .off: return "画面の記録: 撮らない"
        case let .on(display): return "画面の記録: \(display.name)" + (paused ? "、一時停止中" : "")
        case let .failed(display): return "画面の記録: \(display.name)、記録できません"
        }
    }
}

/// フッターのピンの隣に置く、画面の記録の状態と対象。押すとメニューを開く。
/// 操作部なので文字の倍率は掛けない。狭い幅では名前を末尾から省き、アイコンと▼は残す。
final class ScreenTargetButton: HoverButton {
    static let maximumWidth: CGFloat = 150
    static let height: CGFloat = 32
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let iconSize = NSSize(width: 18, height: 16.2)
    private static let caretGap: CGFloat = 4
    var nameFont: NSFont { .systemFont(ofSize: 13) }
    private var caretFont: NSFont { .systemFont(ofSize: 7) }

    var callback: (() -> Void)?
    private(set) var control: ScreenControlState?
    /// メニューを開いている間は、押した背景を残す。
    var menuOpen = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(pressed)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth).isActive = true
        // 狭い幅では宛先ボタンより先に縮まない。名前を省いてアイコンと▼を残す幅までは譲る。
        setContentCompressionResistancePriority(.init(260), for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    @objc private func pressed() { callback?() }

    func update(_ control: ScreenControlState?) {
        guard control != self.control else { return }
        let resized = control?.title != self.control?.title
        self.control = control
        isHidden = control == nil
        let summary = control?.summary ?? ""
        if toolTip != summary { toolTip = summary }
        setAccessibilityLabel(summary)
        if resized { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    private var caret: NSString { "▼" }
    private var caretWidth: CGFloat { ceil(caret.size(withAttributes: [.font: caretFont]).width) }
    private var nameWidth: CGFloat {
        ceil(((control?.title ?? "") as NSString).size(withAttributes: [.font: nameFont]).width)
    }
    /// アイコンと▼だけを残す幅。これより狭くはしない。
    static var minimumWidth: CGFloat { padding * 2 + iconSize.width + gap + 24 }

    override var intrinsicContentSize: NSSize {
        let width = Self.padding * 2 + Self.iconSize.width + Self.gap + nameWidth + Self.caretGap + caretWidth
        return NSSize(width: min(Self.maximumWidth, width), height: Self.height)
    }

    var foreground: NSColor {
        switch control?.tone {
        case .recording: return Washi.ink
        case .failed: return Washi.red
        case .muted, nil: return Washi.muted
        }
    }

    /// 名前を描く枠。末尾から省く。
    var nameFrame: NSRect {
        let x = Self.padding + Self.iconSize.width + Self.gap
        let end = bounds.width - Self.padding - caretWidth - Self.caretGap
        return NSRect(x: x, y: bounds.midY - 8, width: max(0, min(nameWidth, end - x)), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        if menuOpen {
            Washi.muted.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        } else {
            drawHoverBackground()
        }
        guard let control else { return }
        let color = foreground
        drawIcon(in: NSRect(x: Self.padding, y: bounds.midY - Self.iconSize.height / 2,
                            width: Self.iconSize.width, height: Self.iconSize.height),
                 color: color, slashed: control.display == .off)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (control.title as NSString).draw(in: nameFrame, withAttributes: [.font: nameFont, .foregroundColor: color, .paragraphStyle: paragraph])
        let name = nameFrame
        caret.draw(at: NSPoint(x: name.maxX + Self.caretGap, y: bounds.midY - 5),
                   withAttributes: [.font: caretFont, .foregroundColor: Washi.muted])
    }

    /// 画面のアイコン。撮らないときは斜線を引く。斜線の両脇は背景の色で抜き、枠の線と重ねて読めるようにする。
    private func drawIcon(in rect: NSRect, color: NSColor, slashed: Bool) {
        // 20×18の格子で描き、枠へ縮める。上下はAppKitの座標に合わせて反転する。
        let scale = rect.width / 20
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * scale, y: rect.maxY - y * scale) }
        color.setStroke()
        let frame = NSBezierPath(roundedRect: NSRect(x: rect.minX + 1.25 * scale, y: rect.maxY - 12.75 * scale,
                                                     width: 17.5 * scale, height: 11.5 * scale), xRadius: 2 * scale, yRadius: 2 * scale)
        frame.lineWidth = 1.5 * scale; frame.stroke()
        let stand = NSBezierPath()
        stand.move(to: point(8.5, 13)); stand.line(to: point(8.5, 16))
        stand.move(to: point(11.5, 13)); stand.line(to: point(11.5, 16))
        stand.move(to: point(6.5, 16.5)); stand.line(to: point(13.5, 16.5))
        stand.lineWidth = 1.5 * scale; stand.lineCapStyle = .round; stand.stroke()
        guard slashed else { return }
        let slash = NSBezierPath()
        slash.move(to: point(3, 16.5)); slash.line(to: point(17.5, 1.5))
        slash.lineCapStyle = .round
        (menuOpen ? Washi.rule : Washi.shade).setStroke()
        slash.lineWidth = 4 * scale; slash.stroke()
        color.setStroke()
        slash.lineWidth = 1.5 * scale; slash.stroke()
    }
}
