import AppKit
import KikigakiCore
import QuartzCore

/// 撮っているディスプレイの右下に出し続ける「記録中」のバッジと、切り替えた瞬間に画面の中央へ出す知らせ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「撮っている画面の印」
///
/// - KIKIGAKIのウィンドウとして出す。撮影はKIKIGAKIを除くので、保存する画像には写らない
/// - クリックは素通りさせ、キーも取らない。全画面のアプリの上にも出す
/// - 知らせは出している間だけ画面いっぱいの透明なパネルを置き、終わったら片付ける。バッジは小さいパネル1枚
/// - 操作部ではないが、参加者がみんなで読むものでもないので、文字の倍率は掛けない
@MainActor
final class ScreenIndicatorOverlay {
    /// 知らせを中央に留める時間。撮れなくなったときは長めに出す。
    static let noticeHold: TimeInterval = 1.2
    static let unavailableHold: TimeInterval = 2.0
    /// 中央からバッジへ移る時間と、消える時間。
    static let moveDuration: TimeInterval = 0.35
    static let fadeDuration: TimeInterval = 0.3

    private(set) var state: ScreenIndicator<ScreenDisplay> = .hidden
    let badgePanel = IndicatorPanel()
    let noticePanel = IndicatorPanel()
    /// いま出している知らせ。古い知らせの続きの処理は、番号が替わっていたら何もしない。
    private(set) var notice: ScreenIndicator<ScreenDisplay>.Notice?
    private var noticeNumber = 0
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeBadge() }
        }
    }

    /// 録音の状態が替わるたびに呼ぶ。fallback: 撮れなくなったディスプレイが無いときに知らせを出す画面
    func update(_ new: ScreenIndicator<ScreenDisplay>, fallback: NSScreen?) {
        guard new != state else { return }
        let notice = new.notice(from: state)
        state = new
        switch notice {
        case let .started(target)?:
            // バッジは知らせが縮んで着いたところで出す。
            hideBadge()
            show(notice!, on: Self.screen(for: target))
        case let .stopped(target)?:
            hideBadge()
            show(notice!, on: Self.screen(for: target))
        case let .unavailable(target)?:
            hideBadge()
            show(notice!, on: Self.screen(for: target) ?? fallback ?? NSScreen.main)
        case nil:
            // 撮り直しを待ち始めたら、撮り始めた知らせを片付ける。その対象はもう撮っていない。
            if case .switching = new, case .started? = self.notice { cancelNotice() }
            // 知らせを出している間は、着いたときにバッジを置く。
            if self.notice == nil { placeBadge() }
        }
    }

    /// 出している知らせを、続きの処理ごと捨てる。
    private func cancelNotice() {
        noticeNumber += 1
        notice = nil
        noticePanel.orderOut(nil)
        noticePanel.clear()
    }

    static func screen(for display: ScreenDisplay) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }
    }

    // MARK: - バッジ

    private func placeBadge() {
        guard let target = state.badge, let screen = Self.screen(for: target) else { hideBadge(); return }
        let chip = IndicatorChip(kind: .recording, size: .badge, scale: screen.backingScaleFactor)
        badgePanel.setFrame(ScreenIndicatorLayout.badgeFrame(width: chip.width, in: screen.frame), display: false)
        badgePanel.show(chip.layer, at: CGPoint(x: chip.width / 2, y: ScreenIndicatorLayout.badgeHeight / 2))
        badgePanel.alphaValue = 1
        badgePanel.orderFrontRegardless()
    }

    private func hideBadge() {
        badgePanel.orderOut(nil)
    }

    // MARK: - 知らせ

    private func show(_ notice: ScreenIndicator<ScreenDisplay>.Notice, on screen: NSScreen?) {
        noticeNumber += 1
        let number = noticeNumber
        guard let screen else { finishNotice(number); return }
        self.notice = notice
        let kind: IndicatorChip.Kind
        let hold: TimeInterval
        switch notice {
        case .started: kind = .recording; hold = Self.noticeHold
        case .stopped: kind = .stopped; hold = Self.noticeHold
        case .unavailable: kind = .unavailable; hold = Self.unavailableHold
        }
        let chip = IndicatorChip(kind: kind, size: .notice, scale: screen.backingScaleFactor)
        noticePanel.setFrame(screen.frame, display: false)
        let local = ScreenIndicatorLayout.noticeFrame(width: chip.width, in: CGRect(origin: .zero, size: screen.frame.size))
        noticePanel.show(chip.layer, at: CGPoint(x: local.midX, y: local.midY))
        // 前の知らせが消える途中なら、その薄れを止めてから出す。止めないと新しい知らせまで薄れる。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            noticePanel.animator().alphaValue = 1
        }
        noticePanel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeNumber == number else { return }
                if case .started = notice, self.state.badge != nil { self.land(chip, in: screen, number: number) }
                else { self.fadeOutNotice(number) }
            }
        }
    }

    /// 中央の知らせを右下のバッジの位置へ縮めながら移し、着いたらバッジに替える。
    /// 視差効果を減らす設定では、移さずにその場で消してバッジを出す。
    private func land(_ chip: IndicatorChip, in screen: NSScreen, number: Int) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            placeBadge()
            fadeOutNotice(number)
            return
        }
        let badgeWidth = IndicatorChip(kind: .recording, size: .badge, scale: screen.backingScaleFactor).width
        let badge = ScreenIndicatorLayout.badgeFrame(width: badgeWidth, in: CGRect(origin: .zero, size: screen.frame.size))
        let ratio = ScreenIndicatorLayout.badgeHeight / ScreenIndicatorLayout.noticeHeight
        let layer = chip.layer
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.moveDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeNumber == number else { return }
                self.placeBadge()
                self.finishNotice(number)
            }
        }
        // 知らせの右端をバッジの右端へ合わせて縮める。文言が違うので、縮みながら薄くしてバッジと入れ替える。
        layer.position = CGPoint(x: badge.maxX - chip.width * ratio / 2, y: badge.midY)
        layer.transform = CATransform3DMakeScale(ratio, ratio, 1)
        layer.opacity = 0.2
        CATransaction.commit()
    }

    private func fadeOutNotice(_ number: Int) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            noticePanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishNotice(number) }
        })
    }

    private func finishNotice(_ number: Int) {
        guard noticeNumber == number else { return }
        notice = nil
        noticePanel.orderOut(nil)
        noticePanel.clear()
        // 知らせの間に対象が替わっていたら、いまの状態のバッジを置き直す。
        placeBadge()
    }
}

/// クリックを素通りさせる透明なパネル。中身はレイヤーで描く。
final class IndicatorPanel: NSPanel {
    private let host = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // メニューバーと同じ高さの層に置き、全画面のアプリの上にも、どのデスクトップにも出す。
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // 画面共有の相手から隠す。効くかはOSと共有するアプリによる。
        sharingType = .none
        host.wantsLayer = true
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var chipLayer: CALayer? { host.layer?.sublayers?.first }

    func show(_ layer: CALayer, at position: CGPoint) {
        clear()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = position
        host.layer?.addSublayer(layer)
        CATransaction.commit()
    }

    func clear() {
        host.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }
}

/// バッジと知らせの丸い面。録音中のバッジと同じ組み方で、朱・墨・朱の輪郭の3通り。
struct IndicatorChip {
    enum Kind { case recording, stopped, unavailable }
    enum Size { case badge, notice }

    let layer: CALayer
    let width: CGFloat

    private struct Metrics {
        let height, leading, trailing, gap, font, dot, icon, border: CGFloat
    }

    private static func metrics(_ size: Size) -> Metrics {
        switch size {
        case .badge: return Metrics(height: ScreenIndicatorLayout.badgeHeight, leading: 7, trailing: 9, gap: 5, font: 11, dot: 6, icon: 0, border: 1.5)
        case .notice: return Metrics(height: ScreenIndicatorLayout.noticeHeight, leading: 25, trailing: 30, gap: 14, font: 22, dot: 14, icon: 24, border: 2)
        }
    }

    static func text(_ kind: Kind, _ size: Size) -> String {
        switch (kind, size) {
        case (.recording, .badge): return "記録中"
        case (.recording, .notice): return "画面を記録中"
        case (.stopped, _): return "画面の記録を停止"
        case (.unavailable, _): return "画面を記録できません"
        }
    }

    init(kind: Kind, size: Size, scale: CGFloat) {
        let m = Self.metrics(size)
        let background: NSColor, foreground: NSColor
        switch kind {
        case .recording: background = Washi.red; foreground = Washi.paper
        case .stopped: background = Washi.ink; foreground = Washi.paper
        case .unavailable: background = Washi.paper; foreground = Washi.red
        }
        let font = NSFont.systemFont(ofSize: m.font, weight: .semibold)
        let string = NSAttributedString(string: Self.text(kind, size), attributes: [.font: font, .foregroundColor: foreground, .kern: m.font * 0.02])
        let textSize = string.size()
        let leadWidth = kind == .recording ? m.dot : m.icon * 1.25
        let width = ceil(m.leading + leadWidth + m.gap + textSize.width + m.trailing)
        self.width = width

        let chip = CALayer()
        chip.bounds = CGRect(x: 0, y: 0, width: width, height: m.height)
        chip.cornerRadius = m.height / 2
        chip.backgroundColor = background.cgColor
        chip.contentsScale = scale
        if kind == .unavailable {
            chip.borderColor = foreground.cgColor
            chip.borderWidth = m.border
        }
        // 撮っている間のバッジは少し透かし、画面の中身を隠しすぎない。
        if kind == .recording, size == .badge { chip.opacity = 0.72 }

        if kind == .recording {
            let dot = CALayer()
            dot.frame = CGRect(x: m.leading, y: (m.height - m.dot) / 2, width: m.dot, height: m.dot)
            dot.cornerRadius = m.dot / 2
            dot.backgroundColor = foreground.cgColor
            chip.addSublayer(dot)
        } else {
            let icon = CAShapeLayer()
            let iconSize = CGSize(width: m.icon * 1.25, height: m.icon)
            icon.frame = CGRect(origin: CGPoint(x: m.leading, y: (m.height - iconSize.height) / 2), size: iconSize)
            icon.path = Self.screenIcon(slashed: kind == .stopped, size: iconSize)
            icon.strokeColor = foreground.cgColor
            icon.fillColor = nil
            icon.lineWidth = 1.6 * iconSize.width / 20
            icon.lineCap = .round
            icon.contentsScale = scale
            chip.addSublayer(icon)
            if kind == .unavailable {
                // 感嘆符の点は塗りで描く。
                let dot = CAShapeLayer()
                dot.frame = icon.frame
                let unit = iconSize.width / 20
                var flip = Self.flip(height: iconSize.height)
                dot.path = CGPath(ellipseIn: CGRect(x: (10 - 0.95) * unit, y: (10.3 - 0.95) * unit, width: 1.9 * unit, height: 1.9 * unit), transform: &flip)
                dot.fillColor = foreground.cgColor
                dot.contentsScale = scale
                chip.addSublayer(dot)
            }
        }

        let text = CATextLayer()
        text.string = string
        text.contentsScale = scale
        text.frame = CGRect(x: m.leading + leadWidth + m.gap, y: (m.height - ceil(textSize.height)) / 2,
                            width: ceil(textSize.width) + 1, height: ceil(textSize.height))
        chip.addSublayer(text)
        layer = chip
    }

    /// 上から下へ描いた格子の座標を、下から上のレイヤーの座標へ返す。
    private static func flip(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    /// 20×16の格子の画面の絵。格子は上から下へ数える。slashed: 斜線を引く。そうでなければ中に感嘆符の棒を引く
    private static func screenIcon(slashed: Bool, size: CGSize) -> CGPath {
        let unit = size.width / 20
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 1.5 * unit, y: 1.5 * unit, width: 17 * unit, height: 11 * unit),
                            cornerWidth: 2 * unit, cornerHeight: 2 * unit)
        path.move(to: CGPoint(x: 7 * unit, y: 15 * unit)); path.addLine(to: CGPoint(x: 13 * unit, y: 15 * unit))
        if slashed {
            path.move(to: CGPoint(x: 3 * unit, y: 14.5 * unit)); path.addLine(to: CGPoint(x: 17 * unit, y: 0.8 * unit))
        } else {
            path.move(to: CGPoint(x: 10 * unit, y: 4 * unit)); path.addLine(to: CGPoint(x: 10 * unit, y: 8 * unit))
        }
        var flip = flip(height: size.height)
        return path.copy(using: &flip) ?? path
    }
}
