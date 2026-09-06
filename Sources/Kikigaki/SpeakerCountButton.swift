import AppKit
import KikigakiCore

/// 枠数を輪郭、認識済み人数を塗りつぶしで表す。同じ統合先は1人として数える。
@MainActor
final class SpeakerCountButton: NSButton {
    private var lastCounts: [Int] = []

    func update(snapshot: SessionSnapshot) {
        let capacity = SpeakerNames.slotCount
        let recognized = Set(snapshot.speakerMapping.values).count
        let used = snapshot.detectedSpeakerSlots.count
        let merged = max(0, used - recognized)
        let count = capacity
        let description = "認識済み\(recognized)人、最大\(capacity)人"
        let slotsDescription = "この会議で検出した枠\(used)/\(SpeakerNames.slotCount)、未使用\(SpeakerNames.slotCount - used)枠"
            + (merged > 0 ? "。\(merged)枠を統合済み。統合しても検出枠は空きません" : "")
        title = "話者… 使用枠 \(used)/\(SpeakerNames.slotCount)"
        toolTip = description + "。" + slotsDescription + "。人型の輪郭は人数上限を表し、未使用の検出枠ではありません"
        setAccessibilityLabel("話者設定。" + description + "。" + slotsDescription)
        guard lastCounts != [capacity, recognized] else { return }
        lastCounts = [capacity, recognized]
        let symbols = (0..<count).map { index in
            NSImage(systemSymbolName: index < recognized ? "person.fill" : "person", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [index < recognized ? Washi.ink : Washi.muted]))
        }
        image = NSImage(size: NSSize(width: count * 16 - 2, height: 16), flipped: false) { _ in
            for (index, symbol) in symbols.enumerated() {
                symbol?.draw(in: NSRect(x: index * 16, y: 0, width: 14, height: 16),
                             from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        imagePosition = .imageLeft
        imageScaling = .scaleNone
    }
}
