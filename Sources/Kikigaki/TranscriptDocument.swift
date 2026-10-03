import AppKit
import KikigakiCore

final class AIRangeBoundaryView: NSView {
    let answered: Bool
    init(answered: Bool) {
        self.answered = answered
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(answered ? "ここまで返事済み" : "ここまで受領")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let text = (answered ? "ここまで返事済み" : "ここまで受領") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: Washi.muted]
        let size = text.size(withAttributes: attrs)
        let x = bounds.width - 20 - size.width
        (answered ? Washi.muted : Washi.gold).withAlphaComponent(0.35).setFill()
        NSRect(x: 54, y: 6, width: max(0, x - 64), height: 0.5).fill()
        text.draw(at: NSPoint(x: x, y: 0), withAttributes: attrs)
    }
}

protocol DocumentRow: NSView { func height(for width: CGFloat) -> CGFloat }

/// 行ビューを再利用する。再配置は高さの加算だけで、本文の計測は変更行だけに限る。
///
/// 行ビューは全行ぶん持ち、枠も全行に置くが、サブビューに載せるのは見えている範囲の近くだけにする。
/// AppKitはスクロールのたびにサブビューを全部たどるので、全行を載せると1コマの時間が行数に比例する
/// (実測: 60分・581行で43ms、画面外を外すと約5ms)。行の生存は `rows` で判定し、`superview` では見ない。
final class TranscriptDocument: NSView {
    override var isFlipped: Bool { true }
    var followsBottom = true
    var rows: [any DocumentRow] = []
    private(set) var rangeMarkers: [(row: NSView, view: AIRangeBoundaryView)] = []
    func setRangeBoundaries(_ boundaries: AIRangeBoundaries, utteranceRows: [NSView]) {
        let targets: [(NSView, Bool)] = [(boundaries.answered, true), (boundaries.accepted, false)].compactMap { index, answered in
            guard let index, utteranceRows.indices.contains(index) else { return nil }
            return (utteranceRows[index], answered)
        }
        if targets.count == rangeMarkers.count,
           zip(targets, rangeMarkers).allSatisfy({ $0.0.0 === $0.1.row && $0.0.1 == $0.1.view.answered }) { return }
        for marker in rangeMarkers { marker.view.removeFromSuperview() }
        rangeMarkers = targets.map { row, answered in
            let view = AIRangeBoundaryView(answered: answered)
            addSubview(view)
            return (row, view)
        }
        positionRangeMarkers()
    }
    private func positionRangeMarkers() {
        for marker in rangeMarkers {
            addSubview(marker.view, positioned: .above, relativeTo: nil)
            marker.view.frame = NSRect(x: 0, y: marker.row.frame.maxY - 5, width: bounds.width, height: 12)
            marker.view.needsDisplay = true
        }
    }
    private var layingOut = false
    struct Anchor {
        let candidates: [(NSView, CGFloat)]
        let y: CGFloat
        let atBottom: Bool
    }
    func anchor() -> Anchor {
        let clip = enclosingScrollView?.contentView.bounds ?? .zero
        let candidates = rows.filter { $0.frame.maxY > clip.minY }.map { ($0 as NSView, $0.frame.minY - clip.minY) }
        return Anchor(candidates: candidates, y: clip.minY, atBottom: clip.maxY >= frame.height - 24)
    }
    func setRows(_ rows: [any DocumentRow], anchor: Anchor) {
        let keep = Set(rows.map { ObjectIdentifier($0) })
        for view in subviews where !(view is AIRangeBoundaryView) && !keep.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        self.rows = rows
        reflow(anchor: anchor)
    }
    /// 見えている範囲の上下にこの高さ(最低でも見えている高さ)の余白を取り、その中の行だけを載せる。
    /// 速いスクロールやウィンドウを縦に伸ばした直後でも、載せ替えの前に空白が見えないための幅。
    static let mountMargin: CGFloat = 1200
    /// スクロール・再配置・表示域の変化の後に呼ぶ。行の枠は `reflow` が全行に置いてある前提。
    func mountVisibleRows() {
        guard let clip = enclosingScrollView?.contentView.bounds else { return }
        let area = clip.insetBy(dx: 0, dy: -max(Self.mountMargin, clip.height))
        // 行は上から順に並ぶ。載せる範囲より下は外すだけなので、交差の判定は全行で行う。
        var previous: NSView?
        for row in rows {
            if row.frame.intersects(area) {
                // 重なりは無いが、描画順を行の順に揃えて範囲の印より下に置く。
                if row.superview !== self {
                    if let previous { addSubview(row, positioned: .above, relativeTo: previous) }
                    else { addSubview(row, positioned: .below, relativeTo: nil) }
                }
                previous = row
            } else if row.superview === self {
                row.removeFromSuperview()
            }
        }
    }
    /// 載っていない行も含めて、その行が見える位置までスクロールする。
    func scrollRowToVisible(_ row: NSView) {
        guard rows.contains(where: { $0 === row }) else { return }
        scrollToVisible(row.frame)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        let before = anchor()
        super.setFrameSize(newSize)
        if oldWidth != newSize.width && !layingOut { reflow(anchor: before) }
    }
    func reflow(anchor: Anchor) {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        guard let scroll = enclosingScrollView else { return }
        let width = scroll.contentSize.width
        var y: CGFloat = 8
        for row in rows {
            let height = row.height(for: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            row.needsLayout = true
            y += height
        }
        setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, y + 8)))
        positionRangeMarkers()
        let alive = Set(rows.map { ObjectIdentifier($0) })
        let surviving = anchor.candidates.first { alive.contains(ObjectIdentifier($0.0)) }
        let target = anchor.atBottom && followsBottom ? frame.height - scroll.contentSize.height
            : surviving.map { $0.0.frame.minY - $0.1 } ?? anchor.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(target, frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        mountVisibleRows()
    }
}
