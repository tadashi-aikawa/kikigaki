import AppKit

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
        for view in subviews where !keep.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
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
        let surviving = anchor.candidates.first { $0.0.superview === self }
        let target = anchor.atBottom && followsBottom ? frame.height - scroll.contentSize.height
            : surviving.map { $0.0.frame.minY - $0.1 } ?? anchor.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(target, frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
