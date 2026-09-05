import AppKit
import KikigakiCore

@MainActor
final class SpeakerPopover: NSObject, NSTextFieldDelegate {
    private let popover = NSPopover()
    private let field = NSTextField()
    private let avatars: AvatarStore
    private var avatarRows: [(AvatarView, String?)] = []
    private let speakers: [KikigakiConfig.Speaker]
    var onRename: ((String) -> Void)?

    init(slot: Int, names: SpeakerNames, speakers: [KikigakiConfig.Speaker], avatars: AvatarStore) {
        self.avatars = avatars
        self.speakers = speakers
        super.init()
        popover.behavior = .transient
        popover.animates = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 204 + min(8, speakers.count) * 28))
        Washi.surface(content, color: Washi.paper)
        let title = Washi.label("話者\(SpeakerNames.letter(for: slot))の名前", size: 14, weight: .semibold)
        title.frame = NSRect(x: 18, y: content.bounds.height - 42, width: 260, height: 22)
        content.addSubview(title)
        let listHeight = CGFloat(min(8, speakers.count) * 28)
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 150, width: 272, height: listHeight))
        scroll.hasVerticalScroller = speakers.count > 8
        scroll.drawsBackground = false
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: speakers.count * 28))
        scroll.documentView = list
        content.addSubview(scroll)
        for (index, speaker) in speakers.enumerated() {
            let y = CGFloat((speakers.count - index - 1) * 28)
            let used = names.otherSlot(using: speaker.name, excluding: slot)
            let avatar = AvatarView(frame: NSRect(x: 4, y: y + 2, width: 22, height: 23))
            avatar.slot = used ?? slot
            avatar.initial = String(speaker.name.prefix(1))
            avatar.alphaValue = used == nil ? 1 : 0.45
            list.addSubview(avatar)
            avatarRows.append((avatar, speaker.avatar))
            let label = Washi.label(speaker.name, color: used == nil ? Washi.ink : Washi.muted)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 34, y: y + 5, width: used == nil ? 210 : 110, height: 18)
            list.addSubview(label)
            if let used {
                let hint = Washi.label("話者\(SpeakerNames.letter(for: used))で使用中", size: 10, color: Washi.muted)
                hint.frame = NSRect(x: 146, y: y + 5, width: 110, height: 18)
                list.addSubview(hint)
            }
            let button = SpeakerButton(frame: NSRect(x: 0, y: y, width: 256, height: 28))
            button.title = ""
            button.isBordered = false
            button.isEnabled = used == nil
            button.tag = index
            button.target = self
            button.action = #selector(candidatePressed(_:))
            button.setAccessibilityLabel(speaker.name + (used.map { "、話者\(SpeakerNames.letter(for: $0))で使用中" } ?? ""))
            button.toolTip = speaker.name
            list.addSubview(button)
        }
        list.scroll(NSPoint(x: 0, y: max(0, list.bounds.height - listHeight)))
        let inputLabel = Washi.label("自由に入力", color: Washi.muted)
        inputLabel.frame = NSRect(x: 18, y: 117, width: 260, height: 18)
        content.addSubview(inputLabel)
        field.frame = NSRect(x: 18, y: 82, width: 264, height: 26)
        field.stringValue = names.name(for: slot)
        field.placeholderString = SpeakerNames.defaultName(for: slot)
        field.setAccessibilityLabel("話者\(SpeakerNames.letter(for: slot))の名前")
        field.delegate = self
        content.addSubview(field)
        let reset = NSButton(title: "既定に戻す", target: self, action: #selector(resetPressed))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: 14, y: 30, width: 100, height: 26)
        content.addSubview(reset)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        refreshAvatars()
    }
    func present(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
    }
    func refreshAvatars() {
        for (view, source) in avatarRows { view.image = avatars.image(for: source) }
    }
    func close() { popover.close() }
    private func commit(_ name: String) { close(); onRename?(name) }
    @objc private func candidatePressed(_ sender: NSButton) { commit(speakers[sender.tag].name) }
    @objc private func resetPressed() { commit("") }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commit(field.stringValue); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
}
