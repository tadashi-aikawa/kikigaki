import AppKit
import KikigakiCore

/// 表示中の会議の統合と、小音量の除外。
/// 次の録音の話者判別は録音開始シートへ移したので、ここには置かない。
@MainActor
final class SpeakerSettingsPopover: NSObject, NSPopoverDelegate {
    var onMappingChange: ((Int, Int?) -> Void)?
    var onAudioExclusionChange: ((AudioExclusion) -> Void)?
    let exclusionSwitch = NSSwitch()
    let exclusionSlider = NSSlider(value: -45, minValue: -80, maxValue: -20, target: nil, action: nil)
    private let exclusionValue = Washi.label(size: 11)
    private var pendingExclusion: AudioExclusion?
    private var exclusionTimer: Timer?
    private let popover = NSPopover()
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
        popover.delegate = self
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
        let exclusionRow = NSStackView(views: [Washi.label("小音量発話を除外", size: 12, weight: .semibold), NSView(), exclusionSwitch])
        exclusionRow.widthAnchor.constraint(equalToConstant: 384).isActive = true
        stack.addArrangedSubview(exclusionRow)
        exclusionSwitch.target = self; exclusionSwitch.action = #selector(exclusionChanged)
        exclusionSwitch.setAccessibilityLabel("小音量発話を除外")
        exclusionSlider.target = self; exclusionSlider.action = #selector(exclusionChanged)
        exclusionSlider.isContinuous = true
        exclusionSlider.widthAnchor.constraint(equalToConstant: 384).isActive = true
        exclusionSlider.setAccessibilityLabel("除外する音量のしきい値 dBFS")
        stack.addArrangedSubview(exclusionSlider)
        stack.addArrangedSubview(exclusionValue)
        let exclusionHint = NSTextField(wrappingLabelWithString:
            "左ほど声を残し、右ほど除外します。薄い行はコピー・AI送信から除きます。\nOFFやしきい値の引き下げで復元できます。変更は次回も記憶します。\nマイク・入力音量を変えたら再調整してください。遠くの大声は区別できません。")
        exclusionHint.font = .systemFont(ofSize: 11); exclusionHint.textColor = Washi.muted
        exclusionHint.widthAnchor.constraint(equalToConstant: 384).isActive = true
        stack.addArrangedSubview(exclusionHint)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        update(snapshot: snapshot)
    }

    func present(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
    func close() { flushExclusion(); popover.close() }
    func popoverDidClose(_ notification: Notification) { flushExclusion() }

    @objc private func exclusionChanged() {
        guard snapshot.canChangeAudioExclusion else { return }
        pendingExclusion = AudioExclusion(enabled: exclusionSwitch.state == .on, thresholdDBFS: exclusionSlider.doubleValue.rounded())
        refreshExclusionControls()
        exclusionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushExclusion() }
        }
        exclusionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func flushExclusion() {
        exclusionTimer?.invalidate(); exclusionTimer = nil
        guard let value = pendingExclusion else { return }
        guard snapshot.canChangeAudioExclusion else { refreshExclusionControls(); return }
        pendingExclusion = nil
        onAudioExclusionChange?(value)
    }
    private func refreshExclusionControls() {
        let value = pendingExclusion ?? snapshot.audioExclusion
        exclusionSwitch.state = value.enabled ? .on : .off
        exclusionSlider.doubleValue = value.thresholdDBFS
        exclusionSwitch.isEnabled = snapshot.canChangeAudioExclusion
        exclusionSlider.isEnabled = snapshot.canChangeAudioExclusion
        exclusionValue.stringValue = String(format: "%.0f dBFS未満 · %@", value.thresholdDBFS,
            value.enabled ? "除外ON" : "除外OFF・全発話を含む")
    }

    func update(snapshot: SessionSnapshot) {
        let resumed = !self.snapshot.canChangeAudioExclusion && snapshot.canChangeAudioExclusion
        if self.snapshot.timeline.startedAt != snapshot.timeline.startedAt || snapshot.state == .preparing {
            pendingExclusion = nil; exclusionTimer?.invalidate(); exclusionTimer = nil
        }
        self.snapshot = snapshot
        refreshExclusionControls()
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
        contentView.layoutSubtreeIfNeeded()
        let size = NSSize(width: 420, height: ceil(stack.fittingSize.height) + 36)
        popover.contentSize = size
        contentView.setFrameSize(size)
        contentView.layoutSubtreeIfNeeded()
        if resumed { flushExclusion() }
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard snapshot.names.diarizationEnabled, snapshot.state != .preparing && snapshot.state != .finishing,
              let target = sender.selectedItem?.tag else { return }
        onMappingChange?(sender.tag, target == -1 ? nil : target)
    }
}

#if DEBUG
extension SpeakerSettingsPopover {
    /// 保留中のデバウンス。発火予定時刻と登録先を検査するために渡す。
    var exclusionDebounceForTesting: Timer? { exclusionTimer }
    /// 保留中のデバウンスを時間を待たずに発火する。テストが0.15秒の発火を壁時計で
    /// 待つと、並列実行でRunLoop.mainの再開が遅れたときだけ落ちる。発火予定時刻と
    /// 登録先は exclusionDebounceForTesting で別に検査し、ここでは反映を確かめる。
    func fireExclusionDebounceForTesting() { exclusionTimer?.fire() }
}
#endif
