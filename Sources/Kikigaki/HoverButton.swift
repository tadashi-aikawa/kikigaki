import AppKit

/// 押せる部品の追跡とカーソルを共通化する。無効時には地も手形も足さない。
class HoverButton: NSButton {
    private var pointerInside = false
    private var hoverTrackingArea: NSTrackingArea?
    var isHovered: Bool { pointerInside && isEnabled && !isHiddenOrHasHiddenAncestor }
    var interactionCursor: NSCursor { isEnabled ? .pointingHand : .arrow }
    // 標準ベゼルの外へ背景を描かない。枠なしの話者名などは背景を保つ。
    var drawsHoverBackground: Bool { !isBordered }

    override var isEnabled: Bool {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            if pointerInside { interactionCursor.set() }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTrackingArea = area
        // スクロールや再配置でポインタの下へ来た場合も、次のマウス移動を待たず揃える。
        pointerInside = window.map { $0.isKeyWindow && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    override func mouseEntered(with event: NSEvent) {
        pointerInside = true; needsDisplay = true
        interactionCursor.set()
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false; needsDisplay = true
        NSCursor.arrow.set()
    }
    override func cursorUpdate(with event: NSEvent) { interactionCursor.set() }
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = bounds.intersection(visibleRect)
        if isEnabled && !rect.isEmpty && !rect.isNull { addCursorRect(rect, cursor: interactionCursor) }
    }
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerInside = false; needsDisplay = true
    }
    func drawHoverBackground() {
        guard isEnabled && (isHovered || isHighlighted) else { return }
        Washi.rule.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        if drawsHoverBackground { drawHoverBackground() }
        super.draw(dirtyRect)
    }
}
