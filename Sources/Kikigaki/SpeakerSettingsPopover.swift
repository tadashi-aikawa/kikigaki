import AppKit
import KikigakiCore

/// 元の検出枠を常に並べ、統合で表示から消えた話者も訂正できるようにする。
@MainActor
final class SpeakerSettingsPopover: NSObject {
    var onLimitChange: ((Int?) -> Void)?
    var onMappingChange: ((Int, Int?) -> Void)?
    private let popover = NSPopover()
    private let limit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let limitHint = Washi.label(color: Washi.muted)
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 366))
        content.appearance = NSAppearance(named: .aqua)
        Washi.surface(content, color: Washi.paper)
        let title = Washi.label("話者", size: 14, weight: .semibold)
        title.frame = NSRect(x: 18, y: 324, width: 384, height: 22)
        content.addSubview(title)
        let limitLabel = Washi.label("人数上限")
        limitLabel.frame = NSRect(x: 18, y: 288, width: 110, height: 22)
        content.addSubview(limitLabel)
        limit.frame = NSRect(x: 150, y: 286, width: 252, height: 26)
        limit.addItem(withTitle: "自動")
        limit.lastItem?.tag = 0
        for count in 1...SpeakerNames.slotCount {
            limit.addItem(withTitle: "\(count)人")
            limit.lastItem?.tag = count
        }
        limit.target = self
        limit.action = #selector(limitChanged(_:))
        limit.setAccessibilityLabel("次の録音の話者人数上限")
        content.addSubview(limit)
        limitHint.frame = NSRect(x: 18, y: 261, width: 384, height: 18)
        content.addSubview(limitHint)
        let sourceTitle = Washi.label("検出された話者", color: Washi.muted)
        sourceTitle.frame = NSRect(x: 18, y: 225, width: 130, height: 18)
        content.addSubview(sourceTitle)
        let destinationTitle = Washi.label("統合先", color: Washi.muted)
        destinationTitle.frame = NSRect(x: 150, y: 225, width: 252, height: 18)
        content.addSubview(destinationTitle)
        emptyHint.frame = NSRect(x: 18, y: 190, width: 384, height: 22)
        content.addSubview(emptyHint)
        for index in 0..<SpeakerNames.slotCount {
            let y = CGFloat(188 - index * 34)
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
        let hint = NSTextField(wrappingLabelWithString: "手動指定は人数上限を超えることがあります。\n統合先の名前へ直接まとめます。統合は連鎖しません。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Washi.muted
        hint.frame = NSRect(x: 18, y: 20, width: 384, height: 44)
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
        limit.selectItem(withTag: snapshot.maxSpeakers ?? 0)
        limit.isEnabled = snapshot.state == .idle
        limitHint.stringValue = snapshot.state == .idle ? "次の録音から適用" : "人数上限は録音を停止すると変更できます。"
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
                row.choice.addItem(withTitle: "自動")
                row.choice.lastItem?.tag = -1
                for target in slots {
                    row.choice.addItem(withTitle: SpeakerNames.defaultName(for: target))
                    row.choice.lastItem?.tag = target
                }
            }
            let automatic = snapshot.speakerMapping[slot].map { snapshot.names.name(for: $0) } ?? "判定待ち"
            row.choice.item(at: 0)?.title = snapshot.speakerOverrides[slot] == nil ? "自動: " + automatic : "自動"
            for (offset, target) in slots.enumerated() {
                let name = snapshot.names.name(for: target)
                row.choice.item(at: offset + 1)?.title = target == slot ? "元の話者に戻す: " + name : name
            }
            row.choice.selectItem(withTag: snapshot.speakerOverrides[slot] ?? -1)
            row.choice.toolTip = row.choice.selectedItem?.title
        }
    }

    @objc private func limitChanged(_ sender: NSPopUpButton) {
        guard snapshot.state == .idle, let tag = sender.selectedItem?.tag else { return }
        onLimitChange?(tag == 0 ? nil : tag)
    }
    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard snapshot.state != .preparing && snapshot.state != .finishing,
              let target = sender.selectedItem?.tag else { return }
        onMappingChange?(sender.tag, target == -1 ? nil : target)
    }
}
