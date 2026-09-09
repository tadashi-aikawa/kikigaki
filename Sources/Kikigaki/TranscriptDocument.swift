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

final class CopyBoundary: NSView, DocumentRow {
    override var isFlipped: Bool { true }
    func height(for width: CGFloat) -> CGFloat { 32 }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Washi.muted]
        let text = "次にコピーする範囲" as NSString
        let size = text.size(withAttributes: attributes)
        let x = (bounds.width - size.width) / 2
        Washi.rule.setFill()
        NSRect(x: 56, y: 15, width: max(0, x - 68), height: 0.5).fill()
        NSRect(x: x + size.width + 12, y: 15, width: max(0, bounds.width - x - size.width - 32), height: 0.5).fill()
        text.draw(at: NSPoint(x: x, y: 7), withAttributes: attributes)
    }
}

/// 行ビューを再利用する。再配置は高さの加算だけで、本文の計測は変更行だけに限る。
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
        for row in rows where row.superview !== self { addSubview(row) }
        self.rows = rows
        reflow(anchor: anchor)
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
        let surviving = anchor.candidates.first { $0.0.superview === self }
        let target = anchor.atBottom && followsBottom ? frame.height - scroll.contentSize.height
            : surviving.map { $0.0.frame.minY - $0.1 } ?? anchor.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(target, frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
