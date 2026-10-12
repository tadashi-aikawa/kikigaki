import AppKit
import KikigakiCore

enum AIFooterMetrics {
    /// 40ptのアイコン部品内で、要返答の丸と下ラベルの原点を揃える。
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
    var visibleLabel: String?
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
        let centerY = visibleLabel == nil ? bounds.height / 2 : AIFooterMetrics.iconCenterY
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: centerY - size.height / 2, width: size.width, height: size.height))
        if let visibleLabel {
            let attributes: [NSAttributedString.Key: Any] = [.font: AIFooterMetrics.labelFont, .foregroundColor: Washi.muted]
            let label = visibleLabel as NSString
            label.draw(at: NSPoint(x: (bounds.width - label.size(withAttributes: attributes).width) / 2, y: AIFooterMetrics.labelY), withAttributes: attributes)
        }
    }
}

final class AIFooterCount: AIFooterButton {
    var count = 0
    var badgeFrame: NSRect { NSRect(x: 8, y: AIFooterMetrics.iconCenterY - 10, width: 20, height: 20) }
    var labelFont: NSFont { AIFooterMetrics.labelFont }
    init() {
        super.init(symbol: "questionmark.bubble.fill", label: "要返答")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        drawHoverBackground()
        let color = Washi.red
        color.setFill(); NSBezierPath(ovalIn: badgeFrame).fill()
        centered(String(count), y: AIFooterMetrics.iconCenterY - 8, size: 11, color: .white)
        centered("要返答", y: AIFooterMetrics.labelY, font: labelFont, color: Washi.muted)
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

/// 種別・アバター・状態の幅を保ち、宛先名だけを末尾省略する固定サイズの操作部。
final class AIFooterDestination: HoverButton {
    let automatic: Bool
    private let avatars = AvatarStore()
    var callback: (() -> Void)?
    private(set) var destination: AIDestinationPicker.Item?
    private(set) var displayText = ""
    private(set) var isRunning = false
    private(set) var isPreparing = false
    var statusFont: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
    var kindFont: NSFont { .systemFont(ofSize: 10, weight: .medium) }
    var nameFont: NSFont { .systemFont(ofSize: 12) }
    var destinationName: String { destination?.name ?? (automatic ? "送らない" : "指定しない") }
    var filled: Bool { isRunning || isPreparing }
    var foreground: NSColor { filled ? .white : isEnabled ? Washi.ink : Washi.muted }
    var fillColor: NSColor {
        filled ? Washi.red.withAlphaComponent(isEnabled ? 1 : 0.55) : Washi.paper.withAlphaComponent(0.6)
    }
    var statusWidth: CGFloat { (displayText as NSString).size(withAttributes: [.font: statusFont]).width }
    var nameFrame: NSRect {
        let start: CGFloat = destination == nil ? 32 : 53
        let end = bounds.width - 7 - (automatic ? 13 : 0) - (displayText.isEmpty ? 0 : statusWidth + 6)
        return NSRect(x: start, y: bounds.midY - 7, width: max(0, end - start), height: 15)
    }
    init(automatic: Bool) {
        self.automatic = automatic
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(pressed)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
        setContentHuggingPriority(.init(200), for: .horizontal)
        avatars.onChange = { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: min(320, (destinationName as NSString).size(withAttributes: [.font: nameFont]).width + 110), height: 20)
    }
    @objc private func pressed() { guard isEnabled else { return }; callback?() }
    func update(_ item: AIDestinationPicker.Item?, schedule: AIScheduleViewState,
                waiting: Bool, preparing: Bool, now: Date) {
        let previousDestination = destination, previousStatusWidth = statusWidth
        destination = item
        isRunning = waiting
        isPreparing = preparing && !waiting
        let remaining = max(0, Int(ceil(schedule.nextFire?.timeIntervalSince(now) ?? 0)))
        let countdown = String(format: "%d:%02d", remaining / 60, remaining % 60)
        displayText = waiting ? "実行中" : preparing ? "準備中" : !automatic || !schedule.active ? "" :
            !schedule.canCountDown || schedule.nextFire == nil ? "—" : countdown
        let status = waiting ? "AI実行中・返事待ち" : preparing ? "AI送信の準備中" :
            !automatic ? (isEnabled ? "クリックで手動実行" : "録音停止後は手動実行できません") :
            !schedule.active ? "クリックで自動実行を選択" :
            schedule.skipReason ?? (schedule.nextFire == nil ? "最終送信を待っています" : "自動実行を待っています")
        let tooltip = automatic
            ? [status, schedule.active ? item.map { $0.name + "へ" } ?? schedule.destination.map { $0 + "へ" } : nil,
               waiting ? schedule.skipReason : nil].compactMap { $0 }.joined(separator: " · ")
            : ["手動: " + destinationName, status].joined(separator: " · ")
        if toolTip != tooltip { toolTip = tooltip }
        setAccessibilityLabel((automatic ? "自動、" : "手動、") + destinationName + "、" + tooltip)
        if previousDestination != destination || previousStatusWidth != statusWidth { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let accent = isEnabled ? Washi.red : Washi.muted
        fillColor.setFill(); shape.fill()
        if !filled { drawHoverBackground() }
        (destination == nil && !filled ? Washi.muted : accent).setStroke()
        if destination == nil && !filled { shape.setLineDash([3, 2], count: 2, phase: 0) }
        shape.lineWidth = 1; shape.stroke()
        ((automatic ? "自動" : "手動") as NSString).draw(at: NSPoint(x: 6, y: bounds.midY - 6),
            withAttributes: [.font: kindFont, .foregroundColor: foreground])
        if let destination {
            let avatar = AIProfileAvatar.image(name: destination.name, source: destination.avatar, store: avatars)
            avatar.draw(in: NSRect(x: 32, y: bounds.midY - 8, width: 16, height: 16),
                        from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45)
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (destinationName as NSString).draw(in: nameFrame, withAttributes: [
            .font: nameFont, .foregroundColor: destination == nil && !filled ? Washi.muted : foreground,
            .paragraphStyle: paragraph])
        let statusX = bounds.width - 7 - (automatic ? 13 : 0) - statusWidth
        (displayText as NSString).draw(at: NSPoint(x: statusX, y: bounds.midY - 6),
            withAttributes: [.font: statusFont, .foregroundColor: filled ? .white : Washi.muted])
        if automatic {
            ("▾" as NSString).draw(at: NSPoint(x: bounds.width - 14, y: bounds.midY - 6),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: foreground])
        }
    }
}

/// 1秒単位の更新だけ。CALayerへ連続アニメーションを登録しない。
final class AICompactFooter: NSStackView {
    let minutesNotice = AIFooterButton(symbol: "doc.text", label: "議事録")
    let automaticDestination = AIFooterDestination(automatic: true)
    let manualDestination = AIFooterDestination(automatic: false)
    let destinations = NSStackView()
    private let spacer = NSView()
    private let rule = NSView()
    let confirmation = AIFooterCount()
    let warning = AIFooterButton(symbol: "exclamationmark.triangle", label: "警告")
    let more = AIFooterButton(symbol: "ellipsis", label: "その他の操作")
    let pin = AIFooterButton(symbol: "pin", label: "最前面に固定")
    var onSelect: ((String) -> Void)?
    private var state = SessionSnapshot()
    private var timer: Timer?
    private let visibility: (() -> Bool)?
    private var observers: [any NSObjectProtocol] = []
    var timerRunning: Bool { timer != nil }
    init(visibility: (() -> Bool)? = nil) {
        self.visibility = visibility
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8
        distribution = .fill
        edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        heightAnchor.constraint(equalToConstant: 54).isActive = true
        Washi.surface(rule, color: Washi.rule)
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 24).isActive = true
        minutesNotice.isHidden = true
        minutesNotice.tint = Washi.muted
        minutesNotice.visibleLabel = "議事録"
        minutesNotice.setAccessibilityLabel("議事録あり。議事録を表示")
        destinations.orientation = .vertical; destinations.alignment = .leading; destinations.spacing = 2
        destinations.distribution = .fill
        destinations.heightAnchor.constraint(equalToConstant: 42).isActive = true
        destinations.addArrangedSubview(automaticDestination)
        destinations.addArrangedSubview(manualDestination)
        automaticDestination.widthAnchor.constraint(equalTo: destinations.widthAnchor).isActive = true
        manualDestination.widthAnchor.constraint(equalTo: destinations.widthAnchor).isActive = true
        destinations.setContentHuggingPriority(.init(200), for: .horizontal)
        destinations.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        for view in [destinations, rule, confirmation, warning, spacer, minutesNotice, pin, more] { addArrangedSubview(view) }
        pin.tint = Washi.muted
        pin.setAccessibilityValue("OFF")
        pin.callback = { [weak self] in
            guard let self, let window = self.window else { return }
            let pinned = window.level != .floating
            window.level = pinned ? .floating : .normal
            self.pin.symbolName = pinned ? "pin.fill" : "pin"
            self.pin.tint = pinned ? Washi.red : Washi.muted
            self.pin.toolTip = pinned ? "最前面の固定を解除" : "最前面に固定"
            self.pin.setAccessibilityLabel(self.pin.toolTip)
            self.pin.setAccessibilityValue(pinned ? "ON" : "OFF")
            self.pin.needsDisplay = true
        }
        more.tint = Washi.muted
        Washi.surface(self)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func update(_ state: SessionSnapshot, reduceMotion: Bool, now: Date = Date()) {
        self.state = state
        destinations.isHidden = state.ai == nil; rule.isHidden = destinations.isHidden
        spacer.isHidden = state.ai != nil
        automaticDestination.isEnabled = state.ai != nil
        manualDestination.isEnabled = state.ai != nil && state.canSubmitAI
        let questions = state.ai?.conversation?.questions ?? []
        let matching = questions.filter { AIBadgeKind.confirmation.matches($0, in: questions) }
        confirmation.count = matching.count; confirmation.isHidden = matching.isEmpty; confirmation.needsDisplay = true
        confirmation.setAccessibilityLabel("要返答 \(matching.count)、最初の行へ移動")
        confirmation.callback = { [weak self] in
            if let first = matching.first { self?.onSelect?(AIBadgeKind.confirmation.rowID(first)) }
        }
        let failures = questions.filter { $0.state == .failed || $0.state == .deliveryUnknown }
        let warnings = [state.ai?.warning, state.aiSchedule.warning, state.aiRecoveryWarning,
                        state.handoffFailed ? state.handoffMessage : nil].compactMap { $0 }.filter { !$0.isEmpty }
        let warningText = (warnings + failures.map {
            ["#\($0.request.number) \($0.state == .failed ? "失敗" : "送達不明")", $0.failure, $0.result?.body]
                .compactMap { $0 }.joined(separator: "\n")
        }).joined(separator: "\n")
        // 定期更新で同じtooltipを再登録すると、ホバーの表示待ちがリセットされる。
        if warning.toolTip != warningText { warning.toolTip = warningText }
        warning.setAccessibilityValue(warningText)
        warning.isHidden = warningText.isEmpty
        warning.callback = { [weak self] in
            if let first = failures.first {
                self?.onSelect?((first.state == .deliveryUnknown ? AIBadgeKind.unknown : .failed).rowID(first))
            } else if let window = self?.window, !warningText.isEmpty {
                let alert = NSAlert()
                alert.messageText = "AIの警告"
                alert.informativeText = warningText
                alert.addButton(withTitle: "閉じる")
                alert.beginSheetModal(for: window)
            }
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
        let needsTimer = displayed && state.ai != nil && state.aiSchedule.active
            && state.aiSchedule.canCountDown && state.aiSchedule.nextFire != nil
            && !automaticDestination.isRunning && !automaticDestination.isPreparing
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
        let waiting = state.ai?.conversation?.questions.filter { $0.isAwaitingResult } ?? []
        automaticDestination.update(state.aiSchedule.active ? state.automaticDestination : nil,
            schedule: state.aiSchedule, waiting: waiting.contains { $0.request.trigger == .scheduled },
            preparing: state.ai?.automaticPreparing == true, now: now)
        // 通常の手動シートで送信に成功した宛先を、声の合図と共通で表示する。
        manualDestination.update(state.manualDestination, schedule: state.aiSchedule,
            waiting: waiting.contains { $0.request.trigger != .scheduled },
            preparing: state.ai?.manualPreparing == true, now: now)
    }
}
