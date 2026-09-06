import AppKit
import KikigakiCore

/// 元の検出枠を常に並べ、統合で表示から消えた話者も訂正できるようにする。
@MainActor
final class SpeakerSettingsPopover: NSObject {
    var onMappingChange: ((Int, Int?) -> Void)?
    private let popover = NSPopover()
    private let emptyHint = Washi.label("話者が検出されると、統合先を変更できます。", color: Washi.muted)
    private var rows: [(label: NSTextField, choice: NSPopUpButton)] = []
    private var detectedSlots: [Int] = []
    private var snapshot: SessionSnapshot
    var isShown: Bool { popover.isShown }

    init(snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        super.init()
        popover.behavior = .transient
        popover.animates = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 290))
        content.appearance = NSAppearance(named: .aqua)
        Washi.surface(content, color: Washi.paper)
        let title = Washi.label("話者", size: 14, weight: .semibold)
        title.frame = NSRect(x: 18, y: 248, width: 384, height: 22)
        content.addSubview(title)
        let sourceTitle = Washi.label("検出された話者", color: Washi.muted)
        sourceTitle.frame = NSRect(x: 18, y: 212, width: 130, height: 18)
        content.addSubview(sourceTitle)
        let destinationTitle = Washi.label("統合先", color: Washi.muted)
        destinationTitle.frame = NSRect(x: 150, y: 212, width: 252, height: 18)
        content.addSubview(destinationTitle)
        emptyHint.frame = NSRect(x: 18, y: 177, width: 384, height: 22)
        content.addSubview(emptyHint)
        for index in 0..<SpeakerNames.slotCount {
            let y = CGFloat(175 - index * 34)
            let label = Washi.label()
            label.frame = NSRect(x: 18, y: y + 3, width: 126, height: 22)
            label.lineBreakMode = .byTruncatingTail
            content.addSubview(label)
            let choice = NSPopUpButton(frame: NSRect(x: 150, y: y, width: 252, height: 26), pullsDown: false)
            choice.target = self
            choice.action = #selector(mappingChanged(_:))
            content.addSubview(choice)
            rows.append((label, choice))
        }
        let hint = NSTextField(wrappingLabelWithString: "統合先の名前へ直接まとめます。統合は連鎖しません。\n新しい録音を始めるとリセットします。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Washi.muted
        hint.frame = NSRect(x: 18, y: 16, width: 384, height: 40)
        content.addSubview(hint)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        update(snapshot: snapshot)
    }

    func present(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
    func close() { popover.close() }

    func update(snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        let slots = snapshot.detectedSpeakerSlots.filter { (0..<SpeakerNames.slotCount).contains($0) }
        let slotsChanged = slots != detectedSlots
        detectedSlots = slots
        emptyHint.isHidden = !slots.isEmpty
        for (index, row) in rows.enumerated() {
            let visible = index < slots.count
            row.label.isHidden = !visible
            row.choice.isHidden = !visible
            guard visible else { continue }
            let slot = slots[index]
            let original = SpeakerNames.defaultName(for: slot)
            row.label.stringValue = snapshot.names.customName(for: slot).map { original + " / " + $0 } ?? original
            row.label.toolTip = row.label.stringValue
            row.choice.tag = slot
            row.choice.setAccessibilityLabel(row.label.stringValue + "の統合先")
            row.choice.isEnabled = snapshot.state != .preparing && snapshot.state != .finishing
            // 定期更新でコントロールを作り直さず、操作中の選択とフォーカスを保つ。
            if slotsChanged || row.choice.numberOfItems == 0 {
                row.choice.removeAllItems()
                row.choice.addItem(withTitle: "統合しない")
                row.choice.lastItem?.tag = -1
                for target in slots where target != slot {
                    row.choice.addItem(withTitle: SpeakerNames.defaultName(for: target))
                    row.choice.lastItem?.tag = target
                }
            }
            row.choice.item(at: 0)?.title = "統合しない: " + snapshot.names.name(for: slot)
            for (offset, target) in slots.filter({ $0 != slot }).enumerated() {
                let name = snapshot.names.name(for: target)
                row.choice.item(at: offset + 1)?.title = name
            }
            let target = snapshot.speakerOverrides[slot]
            row.choice.selectItem(withTag: target == slot ? -1 : target ?? -1)
            row.choice.toolTip = row.choice.selectedItem?.title
        }
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard snapshot.state != .preparing && snapshot.state != .finishing,
              let target = sender.selectedItem?.tag else { return }
        onMappingChange?(sender.tag, target == -1 ? nil : target)
    }
}
