import AppKit
import QuartzCore

/// 表裏は開始時と画像到着時だけ描く。フレームごとの仕事は描画サーバーの3D変換だけ。
final class SpeakerRevealCoin: NSView {
    static let duration: TimeInterval = 5
    static let turns = 6.5
    // 0〜1.5秒は2.5回転/秒。1.5〜3.5秒で1/7回転/秒へ、3.5〜5秒で0へ減速する。
    // 各区間は時間に対して等加速度。境界の速度を揃え、半整数回転で必ず裏に着地する。
    static let timings = [CAMediaTimingFunction(name: .linear),
        CAMediaTimingFunction(controlPoints: 1 / 3, 70 / 111, 2 / 3, 107 / 111),
        CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)]
    let rotor = CATransformLayer()
    private let front = CALayer()
    private let back = CALayer()
    private var backImage: NSImage?
#if DEBUG
    private(set) var backSnapshotCount = 0
    var backContentsForTesting: CGImage? { back.contents.map { $0 as! CGImage } }
#endif
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(rotor)
        for face in [front, back] {
            face.isDoubleSided = false
            face.contentsGravity = .resize
            rotor.addSublayer(face)
        }
        // 同一平面の面を逆向きに置く。裏面の文字は鏡文字にならない。
        back.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 回転のtransformを持つレイヤーには、派生値のframeを設定しない。
        rotor.bounds = bounds
        rotor.position = NSPoint(x: bounds.midX, y: bounds.midY)
        front.frame = bounds
        back.bounds = bounds
        back.position = NSPoint(x: bounds.midX, y: bounds.midY)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(1, bounds.width * 8)
        layer?.sublayerTransform = perspective
        CATransaction.commit()
    }
    func start(front oldAvatar: AvatarView, back avatar: AvatarView) {
        stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Retinaの実ピクセル数で保持し、回転中にNSViewや画像を作り直さない。
        for (face, view) in [(front, oldAvatar), (back, avatar)] {
            capture(view, into: face)
        }
        backImage = avatar.image
        isHidden = false
        rotor.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        CATransaction.commit()
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.y")
        spin.values = [0, 3.75, 179 / 28, Self.turns].map { $0 * 2 * Double.pi }
        spin.keyTimes = [0, NSNumber(value: 1.5 / Self.duration), NSNumber(value: 3.5 / Self.duration), 1]
        spin.calculationMode = .linear
        spin.duration = Self.duration
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.timingFunctions = Self.timings
        rotor.add(spin, forKey: "speakerCoin")
    }
    /// 共有ストアから届いた画像だけを写す。回転の時刻・角度・アニメーションは触らない。
    func updateBack(from avatar: AvatarView) {
        guard !isHidden, let image = avatar.image, image !== backImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capture(avatar, into: back)
        backImage = image
        CATransaction.commit()
    }
    private func capture(_ avatar: AvatarView, into face: CALayer) {
        let scale = avatar.window?.backingScaleFactor ?? 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(avatar.bounds.width * scale)), pixelsHigh: Int(ceil(avatar.bounds.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        // 通常のアバターは回転中に隠すため、cacheDisplayではなくdrawを一度だけ呼ぶ。
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        avatar.draw(avatar.bounds)
        NSGraphicsContext.restoreGraphicsState()
        face.contents = bitmap.cgImage
        face.contentsScale = scale
#if DEBUG
        if face === back { backSnapshotCount += 1 }
#endif
    }
    func stop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.removeAllAnimations()
        rotor.speed = 1; rotor.timeOffset = 0; rotor.beginTime = 0
        front.contents = nil; back.contents = nil
        backImage = nil
        isHidden = true
        CATransaction.commit()
    }
#if DEBUG
    func freezeForCapture(at elapsed: TimeInterval) {
        rotor.speed = 0
        rotor.timeOffset = elapsed
        if let spin = rotor.animation(forKey: "speakerCoin")?.copy() as? CAAnimation {
            spin.beginTime = 0
            rotor.add(spin, forKey: "speakerCoin")
        }
    }
#endif
}

/// 書き起こしの上端に置く固定倍率の帯。複数枠も省略せず1件ずつ3秒出す。
final class SpeakerRevealBanner: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let bubble = NSView()
    var onChange: (() -> Void)?
    private var queue: [SpeakerReveal] = []
    private var dismissal: Timer?
    private var reduceMotion = false
    private var heightConstraint: NSLayoutConstraint!
    private var bubbleWidth: NSLayoutConstraint!
    private var shownUntil: TimeInterval?
    private var fadingOut = false
    private static let fadeDuration: TimeInterval = 0.18
    private(set) var current: SpeakerReveal?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Washi.surface(self, color: Washi.paper)
        isHidden = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Washi.paper
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        Washi.surface(bubble, color: Washi.ai.background)
        bubble.layer?.cornerRadius = 10
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)
        bubble.addSubview(label)
        heightConstraint = heightAnchor.constraint(equalToConstant: 44)
        bubbleWidth = bubble.widthAnchor.constraint(equalToConstant: 300)
        NSLayoutConstraint.activate([heightConstraint,
            bubbleWidth, bubble.centerXAnchor.constraint(equalTo: centerXAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: bubble.centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func enqueue(_ reveals: [SpeakerReveal], reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        queue.append(contentsOf: reveals)
        if current == nil { showNext() }
    }
    private func showNext() {
        dismissal?.invalidate(); dismissal = nil
        fadingOut = false
        shownUntil = nil
        guard !queue.isEmpty else {
            current = nil; isHidden = true
            onChange?()
            return
        }
        let reveal = queue.removeFirst()
        current = reveal
        label.stringValue = reveal.message
        label.setAccessibilityLabel(reveal.message)
        resizeHeight()
        isHidden = false
        onChange?()
        bubble.layer?.removeAllAnimations()
        setOpacity(1)
        if !reduceMotion {
            animateOpacity(from: 0, to: 1)
        }
        shownUntil = CACurrentMediaTime() + 3
        scheduleDismissal()
    }
    private func scheduleDismissal() {
        dismissal?.invalidate()
        guard let shownUntil else { return }
        let delay = max(0, shownUntil - CACurrentMediaTime() - (reduceMotion ? 0 : Self.fadeDuration))
        dismissal = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.dismissCurrent() }
        RunLoop.main.add(dismissal!, forMode: .common)
    }
    private func dismissCurrent() {
        guard !reduceMotion else { showNext(); return }
        fadingOut = true
        animateOpacity(from: 1, to: 0)
        dismissal = Timer(timeInterval: Self.fadeDuration, repeats: false) { [weak self] _ in self?.showNext() }
        RunLoop.main.add(dismissal!, forMode: .common)
    }
    private func setOpacity(_ value: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.layer?.opacity = value
        CATransaction.commit()
    }
    private func animateOpacity(from: Float, to: Float) {
        setOpacity(to)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to; animation.duration = Self.fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bubble.layer?.add(animation, forKey: "speakerReveal")
    }
    override func layout() { super.layout(); resizeHeight() }
    private func resizeHeight() {
        guard bounds.width > 40 else { return }
        let naturalWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + 32
        let width = min(bounds.width - 40, naturalWidth)
        if bubbleWidth.constant != width { bubbleWidth.constant = width }
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width - 28), height: .greatestFiniteMagnitude)) ?? .zero
        let height = max(44, ceil(size.height) + 30)
        if heightConstraint.constant != height { heightConstraint.constant = height }
    }
    /// 推定し直しや人の確認で由来が消えた帯を、待ち行列と表示中から外す。
    func prune(keeping isValid: (SpeakerReveal) -> Bool) {
        queue.removeAll { !isValid($0) }
        if let current, !isValid(current) { showNext() }
    }
    func stopAnimations() {
        reduceMotion = true
        bubble.layer?.removeAllAnimations()
        setOpacity(1)
        if fadingOut { showNext() }
        else { scheduleDismissal() }
    }
    func clear() {
        let wasVisible = !isHidden
        dismissal?.invalidate(); dismissal = nil
        queue.removeAll(); current = nil
        shownUntil = nil; fadingOut = false
        isHidden = true
        stopAnimations()
        if wasVisible { onChange?() }
    }
    deinit { dismissal?.invalidate() }
}
