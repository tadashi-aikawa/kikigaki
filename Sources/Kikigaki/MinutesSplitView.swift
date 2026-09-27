import AppKit

struct MinutesLayout: Codable, Equatable {
    static let minimumLeft: CGFloat = 420
    static let minimumRight: CGFloat = 320
    var visible = false
    var leftWidth: CGFloat = 600
    var rightWidth: CGFloat = 1199
    static let key = "KikigakiMinutesLayout"
    static func constrained(frame: NSRect, screen: NSRect, fullScreen: Bool) -> Bool {
        if fullScreen { return true }
        return abs(frame.height - screen.height) < 3 &&
            (abs(frame.width - screen.width / 2) < 3 || abs(frame.width - screen.width) < 3) &&
            (abs(frame.minX - screen.minX) < 3 || abs(frame.maxX - screen.maxX) < 3)
    }
    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(Self.self, from: data),
              state.leftWidth.isFinite, state.rightWidth.isFinite, state.leftWidth >= 420, state.rightWidth >= 320 else { return Self() }
        return state
    }
    func fitting(frame: NSRect, screen: NSRect, divider: CGFloat) -> NSRect {
        let desired = leftWidth + (visible ? rightWidth + divider : 0)
        let minimum: CGFloat = visible ? 420 + 320 + divider : 420
        var result = frame
        let available = screen.maxX - max(screen.minX, frame.minX)
        result.size.width = min(desired, max(min(minimum, screen.width), available))
        result.origin.x = min(max(screen.minX, frame.minX), screen.maxX - result.width)
        return result
    }
    /// 閉じるときの枠。左端を固定し、閉じる直前の会話側の幅までウィンドウを縮める。タイル推定の配置でも縮め、
    /// タイルの状態から外れることは受け入れる。ネイティブのフルスクリーンは幅を変えられないので枠を保つ。
    static func closingFrame(frame: NSRect, leftWidth: CGFloat, fullScreen: Bool) -> NSRect {
        guard !fullScreen else { return frame }
        var result = frame
        result.size.width = min(frame.width, max(minimumLeft, leftWidth.rounded()))
        return result
    }
    /// 議事録を表示しているときの会話側の幅。分割の全幅と希望幅から決め、両ペインの最小幅を守る。
    static func leftWidth(total: CGFloat, divider: CGFloat, preferred: CGFloat) -> CGFloat {
        let available = max(0, total - divider)
        return min(max(min(minimumLeft, available * 0.57), preferred), max(0, available - min(minimumRight, available * 0.43)))
    }
}

/// 議事録ペインの開閉。閉じている間は薄墨で地なし、開いている間は罫色の地と墨の図で押し込み表示にする。
/// 開いている間は地で状態が分かるため、図だけにする。
final class MinutesToggleButton: HoverButton {
    // 地をboundsに描くため、標準ベゼルのalignment余白で32ptの枠を膨らませない。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    var isOn = false { didSet { if isOn != oldValue { refresh() } } }
    var showsTitle = true { didSet { if showsTitle != oldValue { refresh() } } }
    private lazy var onWidth = widthAnchor.constraint(equalToConstant: 32)
    func refresh() {
        let titled = showsTitle && !isOn
        if title != (titled ? "議事録" : "") { title = titled ? "議事録" : "" }
        imagePosition = titled ? .imageLeading : .imageOnly
        contentTintColor = isOn ? Washi.ink : Washi.muted
        onWidth.isActive = isOn
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if isOn && isEnabled {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            Washi.rule.setFill(); path.fill()
            // 罫色の地に同じ罫色のホバーは見えないため、薄墨を重ねて押せることを示す。
            if isHovered || isHighlighted { Washi.muted.withAlphaComponent(isHighlighted ? 0.22 : 0.12).setFill(); path.fill() }
        }
        super.draw(dirtyRect)
    }
}

/// 分割幅の正本は1キーだけ。画面制約やプログラムによるresizeを希望幅に保存しない。
@MainActor final class MinutesSplitView: NSSplitView, NSSplitViewDelegate {
    let left: NSView
    let preview: MinutesPreviewView
    private(set) var preference: MinutesLayout
    private let defaults: UserDefaults
    private var adjusting = false
    var onLayout: (() -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var isPreviewVisible: Bool { preference.visible }
    /// 開閉を動かしてよいか。既定は動かさない。書き起こしウィンドウが表示中かつ視差効果を減らさないときだけ真を返す。
    var animates: () -> Bool = { false }
    static let transitionDuration: CFTimeInterval = 0.25

    /// 開閉の途中。議事録ペインは最終の幅のまま右端の外から出入りさせ、中身を細い幅で組み直さない。
    /// ウィンドウが伸縮する場合は会話側の幅を保ち、分割だけの場合は会話側が縮む・広がる。
    private struct Transition {
        var fromFrame: NSRect
        var toFrame: NSRect
        var fromLeft: CGFloat
        var toLeft: CGFloat
        var previewWidth: CGFloat
        var started: CFTimeInterval
        var progress: CGFloat = 0
    }
    private var transition: Transition?
    private var transitionTimer: Timer?
    var isTransitioning: Bool { transition != nil }

    init(left: NSView, defaults: UserDefaults = .standard) {
        self.left = left; self.defaults = defaults; preference = .load(defaults)
        preview = MinutesPreviewView(frame: .zero, defaults: defaults)
        super.init(frame: .zero)
        isVertical = true; dividerStyle = .thin; delegate = self
        addSubview(left); addSubview(preview)
        preview.isHidden = !preference.visible
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawDivider(in rect: NSRect) { Washi.rule.setFill(); rect.fill() }
    func restore() { fitWindow(); layoutPanes(leftWidth: preference.leftWidth); onVisibility?(preference.visible) }
    func setVisible(_ visible: Bool) {
        guard visible != preference.visible else { return }
        // 開閉の直前の会話幅を希望幅にし、会話側を保ったまま右へ伸ばす・縮める。
        // ズームボタンやウィンドウ管理アプリなどライブリサイズ以外の幅の変化は保存値へ入らないため、ここで取る。
        // 開くとき: タイル・全幅の制約幅は希望幅ではないので取らない。閉じている間の会話幅はウィンドウの幅そのものなので、
        // ウィンドウに載っているときだけ取る。
        // 閉じるとき: タイル推定の配置でも会話幅へ縮めるので取る。フルスクリーンは幅を変えられないので取らない。
        // どちらも開閉の途中の幅は取らない。
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        let remember = visible ? window != nil && !constrainedWindow : !fullScreen
        if remember && transition == nil {
            preference.leftWidth = max(MinutesLayout.minimumLeft, left.frame.width)
        }
        let fromLeft = preference.visible || transition != nil ? left.frame.width : bounds.width
        let closingWidth = preview.frame.width
        // 開く途中で閉じたら、開く前の枠へ戻す。途中の会話幅は閉じる直前の幅ではない。
        let openedFrom = transition.flatMap { preference.visible ? $0.fromFrame : nil }
        stopTimer(); transition = nil
        preference.visible = visible
        guard let window else {
            preview.isHidden = !visible; layoutPanes(leftWidth: preference.leftWidth); persist()
            onVisibility?(visible); onLayout?(); return
        }
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1800, height: 1000)
        applyMinimumWidth(screen: screen)
        let target: NSRect
        if visible {
            target = constrainedWindow ? window.frame
                : preference.fitting(frame: window.frame, screen: screen, divider: dividerThickness)
        } else if let openedFrom, !fullScreen {
            target = openedFrom
        } else {
            target = MinutesLayout.closingFrame(frame: window.frame, leftWidth: preference.leftWidth, fullScreen: fullScreen)
        }
        if animates() {
            let total = bounds.width + target.width - window.frame.width
            let toLeft = visible ? MinutesLayout.leftWidth(total: total, divider: dividerThickness, preferred: preference.leftWidth) : total
            preview.isHidden = false
            transition = Transition(fromFrame: window.frame, toFrame: target, fromLeft: fromLeft, toLeft: toLeft,
                previewWidth: visible ? max(0, total - toLeft - dividerThickness) : closingWidth, started: CACurrentMediaTime())
            layoutPanes(leftWidth: preference.leftWidth)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepTransition() }
            }
            RunLoop.main.add(timer, forMode: .common)
            transitionTimer = timer
        } else {
            preview.isHidden = !visible
            if window.frame != target { adjusting = true; window.setFrame(target, display: true); adjusting = false }
            layoutPanes(leftWidth: preference.leftWidth)
        }
        persist()
        onVisibility?(visible); onLayout?()
    }
    /// 経過時間から進める。テストは `progress` を渡して任意の時点を再現する。
    func stepTransition(progress forced: CGFloat? = nil) {
        guard var current = transition, let window else { finishTransition(); return }
        let elapsed = min(1, max(0, (CACurrentMediaTime() - current.started) / Self.transitionDuration))
        let linear = forced ?? CGFloat(elapsed)
        current.progress = 1 - pow(1 - min(1, max(0, linear)), 3)
        transition = current
        guard linear < 1 else { finishTransition(); return }
        let p = current.progress
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * p).rounded() }
        let frame = NSRect(x: mix(current.fromFrame.minX, current.toFrame.minX), y: mix(current.fromFrame.minY, current.toFrame.minY),
                           width: mix(current.fromFrame.width, current.toFrame.width), height: mix(current.fromFrame.height, current.toFrame.height))
        adjusting = true
        if window.frame != frame { window.setFrame(frame, display: true) }
        adjusting = false
        layoutPanes(leftWidth: preference.leftWidth)
    }
    /// 途中の開閉を最終の配置へ揃える。画面の変更やライブリサイズの終わりもここを通す。
    func finishTransition() {
        stopTimer()
        guard let current = transition else { return }
        transition = nil
        preview.isHidden = !preference.visible
        if let window, window.frame != current.toFrame {
            adjusting = true; window.setFrame(current.toFrame, display: true); adjusting = false
        }
        layoutPanes(leftWidth: preference.leftWidth)
    }
    private func stopTimer() { transitionTimer?.invalidate(); transitionTimer = nil }
    private var constrainedWindow: Bool {
        guard let window else { return false }
        // 公開のtile状態がないため、半幅か全幅で画面全高の配置に限定して推定する。
        guard let screen = window.screen?.visibleFrame else { return false }
        return MinutesLayout.constrained(frame: window.frame, screen: screen, fullScreen: window.styleMask.contains(.fullScreen))
    }
    private func applyMinimumWidth(screen: NSRect) {
        window?.minSize.width = min(screen.width, preference.visible ? 740 + dividerThickness : 420)
    }
    func fitWindow() {
        finishTransition()
        guard let window else { return }
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1800, height: 1000)
        applyMinimumWidth(screen: screen)
        guard !constrainedWindow else { return }
        adjusting = true
        window.setFrame(preference.fitting(frame: window.frame, screen: screen, divider: dividerThickness), display: true)
        adjusting = false
    }
    private func persist() { if let bytes = try? JSONEncoder().encode(preference) { defaults.set(bytes, forKey: MinutesLayout.key) } }
    private func layoutPanes(leftWidth: CGFloat) {
        adjusting = true
        if let current = transition {
            let width = min(bounds.width, (current.fromLeft + (current.toLeft - current.fromLeft) * current.progress).rounded())
            left.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            preview.frame = NSRect(x: width + dividerThickness, y: 0, width: current.previewWidth, height: bounds.height)
        } else if preference.visible {
            let available = max(0, bounds.width - dividerThickness)
            let width = MinutesLayout.leftWidth(total: bounds.width, divider: dividerThickness, preferred: leftWidth)
            left.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            preview.frame = NSRect(x: width + dividerThickness, y: 0, width: max(0, available - width), height: bounds.height)
        } else { left.frame = bounds }
        adjusting = false
        onLayout?()
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanes(leftWidth: preference.visible && left.frame.width > 0 ? left.frame.width : preference.leftWidth)
        if window?.inLiveResize == true { rememberWidths() }
    }
    func rememberWidths() {
        guard !adjusting, transition == nil, !constrainedWindow else { return }
        preference.leftWidth = max(MinutesLayout.minimumLeft, left.frame.width)
        if preference.visible { preference.rightWidth = max(MinutesLayout.minimumRight, preview.frame.width) }
        persist()
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(420, bounds.width * 0.57) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(0, bounds.width - dividerThickness - min(320, bounds.width * 0.43)) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !adjusting, preference.visible, NSApp.currentEvent?.type == .leftMouseDragged else { onLayout?(); return }
        rememberWidths(); onLayout?()
    }
}
