import AppKit
import KikigakiCore

enum AIFooterMetrics {
    /// 40ptの部品内で、顔と未読の丸の中心、下ラベルの原点を揃える。
    static let iconCenterY: CGFloat = 24.5
    static let labelY: CGFloat = 2
    static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
}

/// フッターのアイコン操作。無効時は地を足さず色だけを抜く。
class AIFooterButton: HoverButton {
    override var isFlipped: Bool { false }
    var callback: (() -> Void)?
    var symbolName: String
    var tint = Washi.red
    init(symbol: String, label: String) {
        symbolName = symbol
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(pressed)
        setAccessibilityLabel(label); toolTip = label
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { callback?() }
    override func draw(_ dirtyRect: NSRect) {
        drawHoverBackground()
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [isEnabled ? tint : Washi.muted])) else { return }
        let scale = 23 / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
}

final class AIFooterCount: AIFooterButton {
    let kind: AIBadgeKind
    var count = 0
    var badgeFrame: NSRect { NSRect(x: 8, y: AIFooterMetrics.iconCenterY - 10, width: 20, height: 20) }
    var labelFont: NSFont { AIFooterMetrics.labelFont }
    init(kind: AIBadgeKind) {
        self.kind = kind
        super.init(symbol: "questionmark.bubble.fill", label: kind == .unread ? "未読" : "要返答")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        drawHoverBackground()
        let color = kind == .unread ? Washi.red : Washi.color(0xC4801F)
        if kind == .unread {
            color.setFill(); NSBezierPath(ovalIn: badgeFrame).fill()
            centered(String(count), y: AIFooterMetrics.iconCenterY - 8, size: 11, color: .white)
        } else {
            NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color]))?
                .draw(in: NSRect(x: 1, y: AIFooterMetrics.iconCenterY - 9.5, width: 19, height: 19))
            (String(count) as NSString).draw(at: NSPoint(x: 23, y: AIFooterMetrics.iconCenterY - 8), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color])
        }
        centered(kind == .unread ? "未読" : "要返答", y: AIFooterMetrics.labelY, font: labelFont, color: Washi.muted)
    }
    private func centered(_ text: String, y: CGFloat, size: CGFloat, color: NSColor) {
        centered(text, y: y, font: .systemFont(ofSize: size, weight: .medium), color: color)
    }
    private func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(at: NSPoint(x: (bounds.width - width) / 2, y: y), withAttributes: attributes)
    }
}

final class AIRobotButton: AIFooterButton {
    private(set) var displayText = ""
    private(set) var eyeOffset: CGFloat = 0
    private(set) var isRunning = false
    var statusFont: NSFont { AIFooterMetrics.labelFont }
    var eyeColor: NSColor { isRunning && isEnabled ? .white : isEnabled ? tint : Washi.muted }
    var headFrame: NSRect { NSRect(x: bounds.midX - 11.5, y: AIFooterMetrics.iconCenterY - 8.5, width: 23, height: 17) }
    init() { super.init(symbol: "", label: "AIの操作") }
    required init?(coder: NSCoder) { fatalError() }
    func update(schedule: AIScheduleViewState, waiting: Bool, animate: Bool, now: Date) {
        isRunning = waiting
        tint = waiting || schedule.active ? Washi.red : Washi.muted
        let remaining = max(0, Int(ceil(schedule.nextFire?.timeIntervalSince(now) ?? 0)))
        let countdown = String(format: "%d:%02d", remaining / 60, remaining % 60)
        displayText = waiting ? "実行中" : !schedule.active ? "" :
            schedule.skipReason != nil || schedule.nextFire == nil ? "—" : countdown
        eyeOffset = waiting && animate ? (Int(now.timeIntervalSince1970) % 2 == 0 ? -1.5 : 1.5) : 0
        let status = waiting ? "AI実行中・返事待ち" : !schedule.active ? "クリックで自動実行・手動実行を選択" :
            schedule.skipReason ?? (schedule.nextFire == nil ? "最終送信を待っています" : "次 " + countdown)
        toolTip = isEnabled ? [status, schedule.active ? schedule.destination.map { $0 + "へ" } : nil,
            waiting ? schedule.skipReason : nil].compactMap { $0 }.joined(separator: " · ") : "AI連携が設定されていません"
        setAccessibilityLabel("AIの操作、" + (toolTip ?? ""))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        drawHoverBackground()
        let color = isEnabled ? tint : Washi.muted
        let face = headFrame
        let x = face.minX
        color.setStroke()
        let head = NSBezierPath(roundedRect: face, xRadius: 4, yRadius: 4)
        head.lineWidth = 1.7
        if isRunning && isEnabled { color.setFill(); head.fill() }
        head.stroke()
        let antenna = NSBezierPath(); antenna.lineWidth = 1.7
        antenna.move(to: NSPoint(x: bounds.midX, y: face.maxY)); antenna.line(to: NSPoint(x: bounds.midX, y: face.maxY + 4)); antenna.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1.5, y: face.maxY + 4, width: 3, height: 3)).fill()
        eyeColor.setFill()
        for eye: CGFloat in [6, 16] {
            NSBezierPath(ovalIn: NSRect(x: x + eye + eyeOffset - 1.5, y: face.midY - 1.5, width: 3, height: 3)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: displayText == "実行中" ? color : Washi.muted]
        let width = (displayText as NSString).size(withAttributes: attributes).width
        (displayText as NSString).draw(at: NSPoint(x: bounds.midX - width / 2, y: AIFooterMetrics.labelY), withAttributes: attributes)
    }
}

/// 1秒単位の更新だけ。CALayerへ連続アニメーションを登録しない。
final class AICompactFooter: NSStackView {
    let robot = AIRobotButton()
    private let rule = NSView()
    let unread = AIFooterCount(kind: .unread)
    let confirmation = AIFooterCount(kind: .confirmation)
    let warning = AIFooterButton(symbol: "exclamationmark.triangle", label: "警告")
    let more = AIFooterButton(symbol: "ellipsis", label: "その他の操作")
    var onSelect: ((String) -> Void)?
    private var state = SessionSnapshot()
    private var reduceMotion = false
    private var timer: Timer?
    private let visibility: (() -> Bool)?
    private var observers: [any NSObjectProtocol] = []
    var timerRunning: Bool { timer != nil }
    init(visibility: (() -> Bool)? = nil) {
        self.visibility = visibility
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8
        edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        Washi.surface(rule, color: Washi.rule)
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for view in [robot, rule, unread, confirmation, warning, NSView(), more] { addArrangedSubview(view) }
        more.tint = Washi.muted
        Washi.surface(self)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func update(_ state: SessionSnapshot, reduceMotion: Bool, now: Date = Date()) {
        self.state = state; self.reduceMotion = reduceMotion
        robot.isEnabled = state.ai != nil
        robot.isHidden = state.ai == nil; rule.isHidden = robot.isHidden
        let questions = state.ai?.conversation?.questions ?? []
        for button in [unread, confirmation] {
            let matching = questions.filter { button.kind.matches($0, in: questions) }
            button.count = matching.count; button.isHidden = matching.isEmpty; button.needsDisplay = true
            button.setAccessibilityLabel("\(button.kind == .unread ? "未読" : "要返答") \(matching.count)、最初の行へ移動")
            let kind = button.kind
            button.callback = { [weak self] in if let first = matching.first { self?.onSelect?(kind.rowID(first)) } }
        }
        let failures = questions.filter { $0.state == .failed || $0.state == .deliveryUnknown }
        let warnings = [state.ai?.warning, state.aiSchedule.warning, state.aiRecoveryWarning,
                        state.handoffFailed ? state.handoffMessage : nil].compactMap { $0 }.filter { !$0.isEmpty }
        warning.toolTip = (warnings + failures.map {
            ["#\($0.request.number) \($0.state == .failed ? "失敗" : "送達不明")", $0.failure, $0.result?.body]
                .compactMap { $0 }.joined(separator: "\n")
        }).joined(separator: "\n")
        warning.isHidden = warning.toolTip?.isEmpty != false
        warning.callback = { [weak self] in
            if let first = failures.first { self?.onSelect?((first.state == .deliveryUnknown ? AIBadgeKind.unknown : .failed).rowID(first)) }
        }
        refresh(now: now)
        updateVisibility()
    }
    private var displayed: Bool {
        if isHiddenOrHasHiddenAncestor { return false }
        if let visibility { return visibility() }
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    func updateVisibility() {
        let waiting = state.ai?.conversation?.questions.contains { $0.isAwaitingResult } == true
        let needsTimer = displayed && (waiting ? !reduceMotion : state.aiSchedule.active)
        if needsTimer && timer == nil {
            let value = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    self.updateVisibility()
                    if self.timer != nil { self.refresh(now: Date()) }
                }
            }
            value.tolerance = 0.1; RunLoop.main.add(value, forMode: .common); timer = value
        } else if !needsTimer { timer?.invalidate(); timer = nil }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateVisibility() }
                })
            }
        }
        updateVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }
    func refresh(now: Date) {
        let waiting = state.ai?.conversation?.questions.contains { $0.isAwaitingResult } == true
        robot.update(schedule: state.aiSchedule, waiting: waiting, animate: !reduceMotion && displayed, now: now)
    }
}
