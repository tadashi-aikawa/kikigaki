import AppKit
import KikigakiCore

struct MinutesLayout: Codable, Equatable {
    static let minimumLeft: CGFloat = 420
    static let minimumRight: CGFloat = 320
    var visible = false
    var leftWidth: CGFloat = 600
    var rightWidth: CGFloat = 1199
    /// 画像レーンの希望の幅。境目のドラッグで変え、次の会議と次の起動でも使う。仕様は docs/screen-capture.md の「表示」
    var screenLaneWidth = CGFloat(ScreenLaneLayout.defaultWidth)
    /// `leftWidth` を保存したときに出していた画像レーンの幅。ウィンドウを合わせ直すとき、`leftWidth` にこの幅を足す。
    /// 希望の幅 `screenLaneWidth` と分けるのは、狭めたウィンドウでレーンが譲った分まで、合わせ直しで広げないため。
    var screenLaneShownWidth = CGFloat(ScreenLaneLayout.defaultWidth)
    static let key = "KikigakiMinutesLayout"
    private enum CodingKeys: String, CodingKey { case visible, leftWidth, rightWidth, screenLaneWidth, screenLaneShownWidth }
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
    /// - lane: 会話側に足す画像レーンの希望の幅。`leftWidth` はレーンを含まない発言の列の希望幅で、
    ///   レーンが出ればその分だけウィンドウを広げ、発言の列を狭めない。仕様は docs/screen-capture.md の「表示」
    /// - laneMinimum: 最小幅に足すレーンの幅。省けば `lane`。広げたレーンは狭い画面で最小幅まで譲るので、最小幅には最小のレーンを足す
    func fitting(frame: NSRect, screen: NSRect, divider: CGFloat, lane: CGFloat = 0, laneMinimum: CGFloat? = nil) -> NSRect {
        let desired = leftWidth + lane + (visible ? rightWidth + divider : 0)
        let minimum: CGFloat = (visible ? 420 + 320 + divider : 420) + (laneMinimum ?? lane)
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
    /// 整数ptへ丸める。半端な位置のWKWebViewは1倍の画面で隣の画素へ割れ、本文全体がぼやける。
    static func leftWidth(total: CGFloat, divider: CGFloat, preferred: CGFloat, lane: CGFloat = 0) -> CGFloat {
        min(max(leftLowerBound(total: total, divider: divider, lane: lane), preferred.rounded()), leftUpperBound(total: total, divider: divider))
    }
    /// 会話側の幅の上限。切り捨てて、丸めで右ペインの最小幅を割らない。
    static func leftUpperBound(total: CGFloat, divider: CGFloat) -> CGFloat {
        let available = max(0, total - divider)
        return max(0, available - min(minimumRight, available * 0.43)).rounded(.down)
    }
    /// 会話側の幅の下限。狭いウィンドウでは比率で決まり、上限を超えない。
    /// 画像レーンが出ている間は、レーンを除いた幅で発言の列の下限を決めてからレーンの分を足す。
    /// 足してから比率を掛けると、レーンの分まで比率で削られ、発言の列が最小幅を割るため。
    static func leftLowerBound(total: CGFloat, divider: CGFloat, lane: CGFloat = 0) -> CGFloat {
        let available = max(0, total - divider)
        let column = min(minimumLeft, max(0, available - lane) * 0.57).rounded(.up)
        return min(column + lane, leftUpperBound(total: total, divider: divider))
    }
}

extension MinutesLayout {
    /// 画像レーンの幅を足す前に保存した値も読む。無ければ既定の幅。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visible = try container.decode(Bool.self, forKey: .visible)
        leftWidth = try container.decode(CGFloat.self, forKey: .leftWidth)
        rightWidth = try container.decode(CGFloat.self, forKey: .rightWidth)
        let lane = try container.decodeIfPresent(CGFloat.self, forKey: .screenLaneWidth) ?? CGFloat(ScreenLaneLayout.defaultWidth)
        screenLaneWidth = CGFloat(ScreenLaneLayout.clamp(Double(lane)))
        let shown = try container.decodeIfPresent(CGFloat.self, forKey: .screenLaneShownWidth) ?? screenLaneWidth
        screenLaneShownWidth = CGFloat(ScreenLaneLayout.clamp(Double(shown)))
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

/// 分割幅の単一情報源は1キーだけ。画面制約やプログラムによるresizeを希望幅に保存しない。
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
    /// ウィンドウが載っている画面の可視域。テストは実行機の画面の大きさに左右されないよう固定の値へ差し替える。
    var visibleScreen: (NSWindow) -> NSRect? = { $0.screen?.visibleFrame }
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
    func restore() { fitWindow(); layoutPanes(leftWidth: preferredLeft); onVisibility?(preference.visible) }
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
        if remember && transition == nil { rememberColumnWidth() }
        let fromLeft = preference.visible || transition != nil ? left.frame.width : bounds.width
        let closingWidth = preview.frame.width
        // 開く途中で閉じたら、開く前の枠へ戻す。途中の会話幅は閉じる直前の幅ではない。
        let openedFrom = transition.flatMap { preference.visible ? $0.fromFrame : nil }
        stopTimer(); transition = nil
        preference.visible = visible
        guard let window else {
            preview.isHidden = !visible; layoutPanes(leftWidth: preferredLeft); persist()
            onVisibility?(visible); onLayout?(); return
        }
        let screen = visibleScreen(window) ?? NSRect(x: 0, y: 0, width: 1800, height: 1000)
        applyMinimumWidth(screen: screen)
        let target: NSRect
        if visible {
            target = constrainedWindow ? window.frame
                : preference.fitting(frame: window.frame, screen: screen, divider: dividerThickness, lane: laneFit, laneMinimum: laneMinimum)
        } else if let openedFrom, !fullScreen {
            target = openedFrom
        } else {
            target = MinutesLayout.closingFrame(frame: window.frame, leftWidth: preferredLeft, fullScreen: fullScreen)
        }
        if animates() {
            let total = bounds.width + target.width - window.frame.width
            let toLeft = visible ? MinutesLayout.leftWidth(total: total, divider: dividerThickness, preferred: preferredLeft, lane: laneMinimum) : total
            preview.isHidden = false
            transition = Transition(fromFrame: window.frame, toFrame: target, fromLeft: fromLeft, toLeft: toLeft,
                previewWidth: visible ? max(0, total - toLeft - dividerThickness) : closingWidth, started: CACurrentMediaTime())
            layoutPanes(leftWidth: preferredLeft)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepTransition() }
            }
            RunLoop.main.add(timer, forMode: .common)
            transitionTimer = timer
        } else {
            preview.isHidden = !visible
            if window.frame != target { adjusting = true; window.setFrame(target, display: true); adjusting = false }
            layoutPanes(leftWidth: preferredLeft)
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
        layoutPanes(leftWidth: preferredLeft)
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
        layoutPanes(leftWidth: preferredLeft)
    }
    private func stopTimer() { transitionTimer?.invalidate(); transitionTimer = nil }
    private var constrainedWindow: Bool {
        guard let window else { return false }
        // 公開のtile状態がないため、半幅か全幅で画面全高の配置に限定して推定する。
        guard let screen = visibleScreen(window) else { return false }
        return MinutesLayout.constrained(frame: window.frame, screen: screen, fullScreen: window.styleMask.contains(.fullScreen))
    }
    private func applyMinimumWidth(screen: NSRect) {
        window?.minSize.width = min(screen.width, (preference.visible ? 740 + dividerThickness : 420) + laneMinimum)
    }
    /// 会話側の希望幅。保存する `leftWidth` は発言の列だけの幅で、画像レーンの分はここで足す。
    /// レーンの無い会議へ移ったときに、前の会議のレーンの分だけ広いまま残さないため。
    private var preferredLeft: CGFloat { preference.leftWidth + laneFit }
    /// 表示中の会議に画面の行があるか。あれば画像レーンを出す。
    private(set) var laneShown = false
    /// ウィンドウを合わせ直すときに `leftWidth` へ足すレーンの幅。`leftWidth` を保存したときに出していた幅で、希望の幅を超えない。
    /// 希望の幅を足すと、狭めたウィンドウでレーンが譲った分だけ、リサイズの終わりの合わせ直しで広がってしまう。
    private var laneFit: CGFloat {
        guard laneShown else { return 0 }
        let preferred = ScreenLaneLayout.clamp(Double(preference.screenLaneWidth))
        return CGFloat(min(preferred, ScreenLaneLayout.clamp(Double(preference.screenLaneShownWidth))))
    }
    /// 発言の列の希望幅と、そのとき出していたレーンの幅を一緒に取る。2つを足すと、いまの会話側の幅になる。
    private func rememberColumnWidth() {
        preference.leftWidth = max(MinutesLayout.minimumLeft, left.frame.width - laneWidth)
        if laneShown { preference.screenLaneShownWidth = laneWidth }
    }
    /// 最小幅と議事録の区切り線の下限に足すレーンの幅。広げたレーンは会話側が狭まると最小幅まで譲る。
    private var laneMinimum: CGFloat { laneShown ? CGFloat(ScreenLaneLayout.minimumWidth) : 0 }
    /// 出している画像レーンの幅。希望の幅を、会話側の幅で発言の列の最小幅を残せる分までに抑える。出さなければ0。
    /// 会話側の幅を決めるたびに `layoutPanes` で決め直す。
    private(set) var laneWidth: CGFloat = 0
    /// レーンの出入りで、発言の列の幅を保ったままウィンドウを広げる・縮める。
    /// タイル・全画面などウィンドウの幅を変えられないときは、議事録を開いていれば右ペインから、閉じていれば発言の列から譲る。
    func setLaneShown(_ shown: Bool) {
        guard shown != laneShown else { return }
        finishTransition()
        // レーンを足す直前だけ、開閉と同じくライブリサイズ以外で変わった幅も希望幅として取る。
        // 外すときは取らない。画面の右端などで伸ばせなかった幅からレーンの分を引くと、
        // レーンを足す前の希望幅より狭い値を保存してしまうため。レーンの出ている間の手動の変更は
        // ライブリサイズで `rememberWidths` が取る。
        if shown, window != nil, !constrainedWindow, left.frame.width > 0 {
            preference.leftWidth = max(MinutesLayout.minimumLeft, left.frame.width)
        }
        // 出すときは希望の幅の分だけ広げる。前に狭めたウィンドウで譲った幅は引き継がない。
        if shown { preference.screenLaneShownWidth = preference.screenLaneWidth }
        if shown { persist() }
        laneShown = shown
        fitWindow()
        layoutPanes(leftWidth: preferredLeft)
    }
    /// 境目のドラッグ。ウィンドウと議事録ペインの幅は変えず、会話側の中で発言の列とレーンが分け合う。
    /// - commit: 離したとき真。レーンの幅と、そのときの発言の列の幅を希望幅として保存する。
    ///   列の幅も取るのは、次の会議や次の起動で、広げたレーンの分だけウィンドウが広がらないようにするため
    ///   - 例外: タイル・全画面では列の幅を取らない。開閉と同じく、制約された幅は希望幅ではない
    func dragLane(to width: CGFloat, commit: Bool) {
        guard laneShown else { return }
        finishTransition()
        preference.screenLaneWidth = CGFloat(ScreenLaneLayout.clamp(Double(width)))
        layoutPanes(leftWidth: preference.visible ? left.frame.width : preferredLeft)
        guard commit else { return }
        preference.screenLaneWidth = laneWidth
        if !constrainedWindow { rememberColumnWidth() }
        persist()
    }
    func fitWindow() {
        finishTransition()
        guard let window else { return }
        let screen = visibleScreen(window) ?? NSRect(x: 0, y: 0, width: 1800, height: 1000)
        applyMinimumWidth(screen: screen)
        guard !constrainedWindow else { return }
        adjusting = true
        window.setFrame(preference.fitting(frame: window.frame, screen: screen, divider: dividerThickness,
                                           lane: laneFit, laneMinimum: laneMinimum), display: true)
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
            let width = MinutesLayout.leftWidth(total: bounds.width, divider: dividerThickness, preferred: leftWidth, lane: laneMinimum)
            left.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            preview.frame = NSRect(x: width + dividerThickness, y: 0, width: max(0, available - width), height: bounds.height)
        } else { left.frame = bounds }
        updateLaneWidth()
        adjusting = false
        onLayout?()
    }
    /// 会話側の幅から、出す画像レーンの幅を決め直す。
    private func updateLaneWidth() {
        laneWidth = laneShown
            ? CGFloat(ScreenLaneLayout.width(preferred: Double(preference.screenLaneWidth), pane: Double(left.frame.width))) : 0
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanes(leftWidth: preference.visible && left.frame.width > 0 ? left.frame.width : preferredLeft)
        if window?.inLiveResize == true { rememberWidths() }
    }
    func rememberWidths() {
        guard !adjusting, transition == nil, !constrainedWindow else { return }
        rememberColumnWidth()
        if preference.visible { preference.rightWidth = max(MinutesLayout.minimumRight, preview.frame.width) }
        persist()
    }
    // ドラッグの両端は配置と同じ計算にする。AppKitが上下限と丸めをどちらの順で適用しても、位置は整数のまま範囲に収まる。
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        MinutesLayout.leftLowerBound(total: bounds.width, divider: dividerThickness, lane: laneMinimum)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        MinutesLayout.leftUpperBound(total: bounds.width, divider: dividerThickness)
    }
    /// Retinaのドラッグは0.5pt単位で届く。そのまま置くと、1倍の画面へ移したときに議事録ペインがぼやける。
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { proposedPosition.rounded() }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // 議事録の区切り線のドラッグは `layoutPanes` を通らずに会話側の幅を変える。
        if !adjusting { updateLaneWidth() }
        guard !adjusting, preference.visible, NSApp.currentEvent?.type == .leftMouseDragged else { onLayout?(); return }
        rememberWidths(); onLayout?()
    }
}
