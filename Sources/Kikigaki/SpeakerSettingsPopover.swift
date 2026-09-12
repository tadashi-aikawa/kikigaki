import AppKit
import KikigakiCore

/// 表示中の会議の統合と、次に始める録音の設定を分ける。
@MainActor
final class SpeakerSettingsPopover: NSObject {
    var onMappingChange: ((Int, Int?) -> Void)?
    var onDiarizationChange: ((Bool) -> Void)?
    private let popover = NSPopover()
    let diarizationSwitch = NSSwitch()
    private let modeHint = NSTextField(wrappingLabelWithString: "")
    private let meetingTitle = Washi.label(size: 12, weight: .semibold)
    private let emptyHint = Washi.label(color: Washi.muted)
    private let mappingHint = NSTextField(wrappingLabelWithString:
        "統合先の名前へ直接まとめます。統合は連鎖しません。\n新しい録音を始めるとリセットします。")
    private let meetingSection = NSStackView()
    private let stack = NSStackView()
    private var rows: [(view: NSStackView, label: NSTextField, choice: NSPopUpButton)] = []
    private var detectedSlots: [Int] = []
    private var snapshot: SessionSnapshot
    var isShown: Bool { popover.isShown }
    var contentView: NSView { popover.contentViewController!.view }

    init(snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        super.init()
        popover.behavior = .transient
        popover.animates = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        content.appearance = NSAppearance(named: .aqua)
        Washi.surface(content, color: Washi.paper)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.widthAnchor.constraint(equalToConstant: 384)
        ])
        stack.addArrangedSubview(Washi.label("話者", size: 14, weight: .semibold))
        meetingSection.orientation = .vertical; meetingSection.alignment = .leading; meetingSection.spacing = 8
        meetingSection.addArrangedSubview(meetingTitle)
        meetingSection.addArrangedSubview(emptyHint)
        for _ in 0..<SpeakerNames.slotCount {
            let label = Washi.label()
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(equalToConstant: 126).isActive = true
            let choice = NSPopUpButton()
            choice.widthAnchor.constraint(equalToConstant: 248).isActive = true
            choice.target = self; choice.action = #selector(mappingChanged(_:))
            let row = NSStackView(views: [label, choice])
            row.spacing = 10
            meetingSection.addArrangedSubview(row)
            rows.append((row, label, choice))
        }
        mappingHint.font = .systemFont(ofSize: 11); mappingHint.textColor = Washi.muted
        mappingHint.widthAnchor.constraint(equalToConstant: 384).isActive = true
        meetingSection.addArrangedSubview(mappingHint)
        stack.addArrangedSubview(meetingSection)
        let nextTitle = Washi.label("次の録音", size: 12, weight: .semibold)
        stack.addArrangedSubview(nextTitle)
        let modeLabel = Washi.label("話者判別")
        let spacer = NSView()
        let modeRow = NSStackView(views: [modeLabel, spacer, diarizationSwitch])
        modeRow.widthAnchor.constraint(equalToConstant: 384).isActive = true
        diarizationSwitch.target = self; diarizationSwitch.action = #selector(modeChanged)
        diarizationSwitch.setAccessibilityLabel("次の録音の話者判別")
        stack.addArrangedSubview(modeRow)
        modeHint.font = .systemFont(ofSize: 11); modeHint.textColor = Washi.muted
        modeHint.widthAnchor.constraint(equalToConstant: 384).isActive = true
        stack.addArrangedSubview(modeHint)
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
        let hasMeeting = snapshot.markdownURL != nil || snapshot.state != .idle
        let enabled = snapshot.names.diarizationEnabled
        meetingSection.isHidden = !hasMeeting
        meetingTitle.stringValue = snapshot.state == .idle ? "表示中の会議" : "この会議"
        emptyHint.stringValue = enabled ? "話者が検出されると、統合先を変更できます。"
            : "この会議は話者を区別していません。"
        let slots = enabled ? snapshot.detectedSpeakerSlots.filter { (0..<SpeakerNames.slotCount).contains($0) } : []
        let slotsChanged = slots != detectedSlots
        detectedSlots = slots
        emptyHint.isHidden = !slots.isEmpty
        mappingHint.isHidden = slots.isEmpty
        for (index, row) in rows.enumerated() {
            let visible = index < slots.count
            row.view.isHidden = !visible
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
                row.choice.item(at: offset + 1)?.title = snapshot.names.name(for: target)
            }
            let target = snapshot.speakerOverrides[slot]
            row.choice.selectItem(withTag: target == slot ? -1 : target ?? -1)
            row.choice.toolTip = row.choice.selectedItem?.title
        }
        diarizationSwitch.state = snapshot.nextDiarizationEnabled ? .on : .off
        diarizationSwitch.isEnabled = snapshot.canChangeDiarization
        modeHint.stringValue = (snapshot.canChangeDiarization ? "録音開始時に適用します。選択は次回も記憶します。"
            : "録音を停止すると変更できます。この会議には適用しません。")
            + (snapshot.nextDiarizationEnabled ? ""
                : "\n文字起こしが確定したら、話者を待たず表示します。\n話者に基づく繰り返し相槌の省略は行いません。")
        diarizationSwitch.toolTip = modeHint.stringValue
        contentView.layoutSubtreeIfNeeded()
        let size = NSSize(width: 420, height: ceil(stack.fittingSize.height) + 36)
        popover.contentSize = size
        contentView.setFrameSize(size)
        contentView.layoutSubtreeIfNeeded()
    }

    @objc private func modeChanged() {
        guard snapshot.canChangeDiarization else { return }
        onDiarizationChange?(diarizationSwitch.state == .on)
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard snapshot.names.diarizationEnabled, snapshot.state != .preparing && snapshot.state != .finishing,
              let target = sender.selectedItem?.tag else { return }
        onMappingChange?(sender.tag, target == -1 ? nil : target)
    }
}
