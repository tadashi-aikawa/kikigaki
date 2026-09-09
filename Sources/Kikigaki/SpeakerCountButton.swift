import AppKit
import KikigakiCore

/// アイコンと検出枠数を同じ中心線に上下で並べる。
@MainActor
final class SpeakerCountButton: NSButton {
    override var isFlipped: Bool { false }
    private(set) var countText = "0/4"
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 38) }
    func update(snapshot: SessionSnapshot) {
        countText = "\(snapshot.detectedSpeakerSlots.count)/\(SpeakerNames.slotCount)"
        title = ""; isBordered = false
        toolTip = "話者の統合先。使用枠 \(countText)"
        setAccessibilityLabel(toolTip); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [Washi.ink]))?
            .draw(in: NSRect(x: (bounds.width - 24) / 2, y: 15, width: 24, height: 20))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: Washi.muted]
        let size = (countText as NSString).size(withAttributes: attributes)
        (countText as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 1), withAttributes: attributes)
    }
}
