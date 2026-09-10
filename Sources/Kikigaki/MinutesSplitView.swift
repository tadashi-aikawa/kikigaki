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
}

/// 分割幅の正本は1キーだけ。画面制約やプログラムによるresizeを希望幅に保存しない。
@MainActor final class MinutesSplitView: NSSplitView, NSSplitViewDelegate {
    let left: NSView
    let preview = MinutesPreviewView(frame: .zero)
    private(set) var preference: MinutesLayout
    private let defaults: UserDefaults
    private var adjusting = false
    var onLayout: (() -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var isPreviewVisible: Bool { preference.visible }

    init(left: NSView, defaults: UserDefaults = .standard) {
        self.left = left; self.defaults = defaults; preference = .load(defaults)
        super.init(frame: .zero)
        isVertical = true; dividerStyle = .thin; delegate = self
        addSubview(left); addSubview(preview)
        preview.isHidden = !preference.visible
        preview.onClose = { [weak self] in self?.setVisible(false) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawDivider(in rect: NSRect) { Washi.rule.setFill(); rect.fill() }
    func restore() { fitWindow(); layoutPanes(leftWidth: preference.leftWidth); onVisibility?(preference.visible) }
    func setVisible(_ visible: Bool) {
        guard visible != preference.visible else { return }
        if !visible && !constrainedWindow { preference.leftWidth = max(420, left.frame.width) }
        preference.visible = visible; preview.isHidden = !visible
        fitWindow(); layoutPanes(leftWidth: preference.leftWidth); persist()
        onVisibility?(visible); onLayout?()
    }
    private var constrainedWindow: Bool {
        guard let window else { return false }
        // 公開のtile状態がないため、半幅か全幅で画面全高の配置に限定して推定する。
        guard let screen = window.screen?.visibleFrame else { return false }
        return MinutesLayout.constrained(frame: window.frame, screen: screen, fullScreen: window.styleMask.contains(.fullScreen))
    }
    func fitWindow() {
        guard let window else { return }
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1800, height: 1000)
        window.minSize.width = min(screen.width, preference.visible ? 740 + dividerThickness : 420)
        guard !constrainedWindow else { return }
        adjusting = true
        window.setFrame(preference.fitting(frame: window.frame, screen: screen, divider: dividerThickness), display: true)
        adjusting = false
    }
    private func persist() { if let bytes = try? JSONEncoder().encode(preference) { defaults.set(bytes, forKey: MinutesLayout.key) } }
    private func layoutPanes(leftWidth: CGFloat) {
        adjusting = true
        if preference.visible {
            let available = max(0, bounds.width - dividerThickness)
            let width = min(max(min(420, available * 0.57), leftWidth), max(0, available - min(320, available * 0.43)))
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
        guard !adjusting, !constrainedWindow else { return }
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
