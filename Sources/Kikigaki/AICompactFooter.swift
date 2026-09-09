import AppKit
import KikigakiCore

/// フッターのアイコン操作。無効時は地を足さず色だけを抜く。
class AIFooterButton: NSButton {
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
    init(kind: AIBadgeKind) {
        self.kind = kind
        super.init(symbol: "questionmark.bubble.fill", label: kind == .unread ? "未読" : "要返答")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let color = kind == .unread ? Washi.red : Washi.color(0xC4801F)
        if kind == .unread {
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: 8, y: 17, width: 20, height: 20)).fill()
            centered(String(count), y: 19, size: 11, color: .white)
        } else {
            NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color]))?
                .draw(in: NSRect(x: 1, y: 18, width: 19, height: 19))
            (String(count) as NSString).draw(at: NSPoint(x: 23, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color])
        }
        centered(kind == .unread ? "未読" : "要返答", y: 2, size: 9, color: Washi.muted)
    }
    private func centered(_ text: String, y: CGFloat, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(at: NSPoint(x: (bounds.width - width) / 2, y: y), withAttributes: attributes)
    }
}

final class AIScheduleGauge: AIFooterButton {
    var onConfigure: (() -> Void)?
    var onFire: (() -> Void)?
    private(set) var scheduleState = AIScheduleViewState()
    private(set) var displayText = ""
    private var fraction: CGFloat = 0
    init() {
        super.init(symbol: "", label: "自動送信")
        callback = { [weak self] in
            guard let self, !scheduleState.active else { return }
            onConfigure?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ state: AIScheduleViewState, now: Date) {
        self.scheduleState = state
        let remaining = max(0, Int(ceil(state.nextFire?.timeIntervalSince(now) ?? 0)))
        let countdown = remaining >= 60 ? String(format: "%d:%02d", remaining / 60, remaining % 60) : String(remaining)
        displayText = !state.active ? "" : state.skipReason != nil ? "—" : countdown
        fraction = state.active && state.skipReason == nil ? CGFloat(min(1, max(0, Double(remaining) / state.interval))) : 0
        toolTip = !state.active ? "クリックで自動送信を設定" : state.skipReason ?? "次 \(countdown) · ダブルクリックで今すぐ送る"
        setAccessibilityLabel("自動送信、" + (toolTip ?? ""))
        needsDisplay = true
    }
    func activate(clickCount: Int) {
        guard isEnabled else { return }
        if !scheduleState.active { onConfigure?() }
        else if clickCount == 2, scheduleState.skipReason == nil { onFire?() }
    }
    override func mouseDown(with event: NSEvent) { activate(clickCount: event.clickCount) }
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - 28) / 2, y: (bounds.height - 28) / 2, width: 28, height: 28)
        Washi.rule.setStroke(); let circle = NSBezierPath(ovalIn: rect); circle.lineWidth = 2; circle.stroke()
        if fraction > 0 && isEnabled {
            Washi.color(0xC4801F).setStroke()
            let arc = NSBezierPath(); arc.lineWidth = 2; arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: 14,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true); arc.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: displayText.contains(":") ? 8 : 11, weight: .medium),
            .foregroundColor: scheduleState.skipReason == nil && isEnabled ? Washi.ink : Washi.muted]
        let size = (displayText as NSString).size(withAttributes: attributes)
        (displayText as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

/// 1秒単位の更新だけ。CALayerへ連続アニメーションを登録しない。
final class AICompactFooter: NSStackView {
    let gauge = AIScheduleGauge()
    let unread = AIFooterCount(kind: .unread)
    let confirmation = AIFooterCount(kind: .confirmation)
    let warning = AIFooterButton(symbol: "exclamationmark.triangle", label: "警告")
    let ask = AIFooterButton(symbol: "sparkles", label: "AIへ送る")
    let more = AIFooterButton(symbol: "ellipsis", label: "その他の操作")
    var onSelect: ((String) -> Void)?
    private var state = SessionSnapshot()
    private var reduceMotion = false
    private var timer: Timer?
    private(set) var pulseDimmed = false
    init() {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8
        edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        let rule = NSView(); Washi.surface(rule, color: Washi.rule)
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for view in [gauge, rule, unread, confirmation, warning, ask, NSView(), more] { addArrangedSubview(view) }
        more.tint = Washi.muted
        Washi.surface(self)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func update(_ state: SessionSnapshot, reduceMotion: Bool, now: Date = Date()) {
        self.state = state; self.reduceMotion = reduceMotion
        gauge.isEnabled = state.ai != nil && (state.aiSchedule.active || state.state == .recording || state.state == .paused)
        ask.isHidden = state.ai == nil
        ask.isEnabled = state.canShare
        ask.toolTip = ["AIへ依頼する " + (state.ai?.shortcut ?? ""), state.ai?.progress].compactMap { $0 }.joined(separator: "\n")
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
        let needsTimer = state.aiSchedule.active || (!reduceMotion && questions.contains { $0.isAwaitingResult })
        if needsTimer && timer == nil {
            let value = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated { guard let self else { timer.invalidate(); return }; self.refresh(now: Date()) }
            }
            value.tolerance = 0.1; RunLoop.main.add(value, forMode: .common); timer = value
        } else if !needsTimer { timer?.invalidate(); timer = nil }
    }
    func refresh(now: Date) {
        gauge.update(state.aiSchedule, now: now)
        let waiting = state.ai?.conversation?.questions.contains { $0.isAwaitingResult } == true
        pulseDimmed = waiting && !reduceMotion && Int(now.timeIntervalSince1970) % 2 == 1
        ask.tint = pulseDimmed ? Washi.red.withAlphaComponent(0.35) : Washi.red
        ask.needsDisplay = true
    }
}
