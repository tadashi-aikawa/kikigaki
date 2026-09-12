import AppKit
import KikigakiCore

/// アイコンと検出枠数を同じ中心線に上下で並べる。
@MainActor
final class SpeakerCountButton: HoverButton {
    override var isFlipped: Bool { false }
    private(set) var countText = "0/4"
    private var diarizationEnabled = true
    let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 38) }
    func update(snapshot: SessionSnapshot) {
        diarizationEnabled = snapshot.displayedDiarizationEnabled
        countText = diarizationEnabled ? "\(snapshot.detectedSpeakerSlots.count)/\(SpeakerNames.slotCount)" : "なし"
        title = ""; isBordered = false
        let subject = snapshot.markdownURL == nil && snapshot.state == .idle ? "次の録音" : "表示中の会議"
        toolTip = subject + (diarizationEnabled ? "の話者。使用枠 \(countText)" : "は話者判別なし。すべて「発言」として記録します")
        setAccessibilityLabel(toolTip); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        drawHoverBackground()
        NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [Washi.ink]))?
            .draw(in: NSRect(x: (bounds.width - 24) / 2, y: 15, width: 24, height: 20))
        if !diarizationEnabled {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: bounds.midX - 12, y: 35))
            slash.line(to: NSPoint(x: bounds.midX + 12, y: 15))
            Washi.paper.setStroke(); slash.lineWidth = 4; slash.stroke()
            Washi.ink.setStroke(); slash.lineWidth = 1.5; slash.stroke()
        }
        let font = diarizationEnabled ? countFont : NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Washi.muted]
        let size = (countText as NSString).size(withAttributes: attributes)
        (countText as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 1), withAttributes: attributes)
    }
}
