import AppKit
import KikigakiCore

/// 確認できた位置だけを描く。時計以外の周期描画とバーのアニメーションは持たない。
final class AIProgressView: NSView {
    override var isFlipped: Bool { true }
    private let label = Washi.label(size: 13, color: Washi.muted)
    private(set) var progress: AIProgress?
    private var reduceMotion = false
    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private let visibility: (() -> Bool)?
    private var wasDisplayed = false
    var timerRunning: Bool { timer != nil }
    var displayText: String { label.stringValue }
    var observerCount: Int { observers.count }
    init(visibility: (() -> Bool)? = nil) {
        self.visibility = visibility
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func update(_ progress: AIProgress?, reduceMotion: Bool, now: Date = Date()) {
        self.progress = progress; self.reduceMotion = reduceMotion
        isHidden = progress?.showsReplyProgress != true
        updateObservers()
        refresh(now: now)
        updateVisibility(now: now)
        needsDisplay = true
    }
    private var displayed: Bool {
        // clipsToBounds=falseのビューではvisibleRectが自分のbounds外まで広がる。
        guard !isHiddenOrHasHiddenAncestor, !visibleRect.intersection(bounds).isEmpty else { return false }
        if let visibility { return visibility() }
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    func updateVisibility(now: Date = Date()) {
        let visible = displayed
        if visible && !wasDisplayed { refresh(now: now) }
        wasDisplayed = visible
        let needsTimer = progress?.updatesElapsedTime(isDisplayed: visible, reduceMotion: reduceMotion) == true
        if needsTimer && timer == nil {
            let value = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    self.updateVisibility()
                    if self.timer != nil { self.refresh(now: Date()) }
                }
            }
            value.tolerance = 0.1
            RunLoop.main.add(value, forMode: .common); timer = value
        } else if !needsTimer { timer?.invalidate(); timer = nil }
    }
    func refresh(now: Date) {
        guard let progress else { label.stringValue = ""; return }
        label.stringValue = progress.text(at: now)
        label.textColor = progress.isPaused ? Washi.aiProgressBlocked : Washi.muted
        let stages = AIProgress.Stage.allCases.map {
            $0.title + (progress.observedStages.contains($0) ? "：確認済み" : "：未確認")
        }.joined(separator: " → ")
        // 秒更新でtooltipを再登録すると、ホバーの表示待ちが毎秒やり直しになる。
        let tip = progress.message + "\n" + stages + "\n確認できた位置を示します。時間は送信試行からの経過です。"
        if toolTip != tip { toolTip = tip; label.toolTip = tip }
        setAccessibilityLabel(progress.message + "、" + stages)
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        updateVisibility()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservers()
        updateVisibility()
    }
    private func updateObservers() {
        let target = progress?.showsReplyProgress == true ? window : nil
        if observedWindow === target, target != nil, !observers.isEmpty { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        observedWindow = target
        if let window = target {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        if note.name == NSWindow.willCloseNotification {
                            self?.timer?.invalidate(); self?.timer = nil; self?.wasDisplayed = false
                        }
                        else { self?.updateVisibility() }
                    }
                })
            }
        }
    }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }
    override func draw(_ dirtyRect: NSRect) {
        guard let progress else { return }
        let width = min(234, bounds.width - 2)
        let count = CGFloat(AIProgress.Stage.allCases.count)
        let segment = max(0, (width - (count - 1) * 6) / count)
        for stage in AIProgress.Stage.allCases {
            let observed = progress.observedStages.contains(stage)
            let current = stage == progress.currentStage && !progress.isHistorical
            let color = current ? Washi.red.withAlphaComponent(progress.isUnknown ? 0.5 : 1)
                : observed ? Washi.muted : Washi.aiProgressPending
            let rect = NSRect(x: 2 + CGFloat(stage.rawValue) * (segment + 6), y: 26, width: segment, height: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            if observed { color.setFill(); path.fill() }
            else { color.setStroke(); path.lineWidth = 1.5; path.stroke() }
            let textColor = current && !progress.isUnknown ? Washi.red
                : observed ? Washi.ink : Washi.muted
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: textColor]
            let title = stage.title as NSString
            let size = title.size(withAttributes: attributes)
            title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: 31), withAttributes: attributes)
            if current && !progress.isUnknown && !progress.isPaused {
                ("▾" as NSString).draw(at: NSPoint(x: rect.midX - 3, y: 17), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: color])
            }
        }
    }
}
