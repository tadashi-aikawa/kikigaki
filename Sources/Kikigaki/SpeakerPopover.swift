import AppKit
import KikigakiCore

@MainActor
final class SpeakerPopover: NSObject, NSTextFieldDelegate {
    private let popover = NSPopover()
    private let field = NSTextField()
    private let scroll = NSScrollView()
    private let list = TranscriptContentView()
    private let avatars: AvatarStore
    private var avatarRows: [(AvatarView, String?)] = []
    private let slot: Int
    private let candidates: [SpeakerSuggestions.Candidate]
    private var edited = false
    private var rows: [Row] = []
    private var selected: Int?
    var onRename: ((String) -> Void)?
    var contentView: NSView { popover.contentViewController!.view }

    private struct Row {
        let name: String
        let candidate: SpeakerSuggestions.Candidate?
        var isSelectable: Bool { candidate?.isSelectable ?? true }
    }

    init(slot: Int, names: SpeakerNames, speakers: [KikigakiConfig.Speaker], avatars: AvatarStore,
         participants: [String] = [], frequentNames: [String] = []) {
        self.avatars = avatars
        self.slot = slot
        candidates = SpeakerSuggestions.candidates(participants: participants, frequent: frequentNames,
                                                   speakers: speakers, names: names, excluding: slot)
        super.init()
        popover.behavior = .transient
        popover.animates = false
        // contentSizeを入力中に変更しない。上向きの表示でも入力欄の画面位置を維持する。
        let listHeight = CGFloat(min(8, max(2, candidates.count)) * 28)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 104 + listHeight))
        Washi.surface(content, color: Washi.paper)
        let badge = AvatarView(frame: NSRect(x: 18, y: content.bounds.height - 43, width: 22, height: 23))
        badge.slot = slot
        badge.initial = SpeakerNames.letter(for: slot)
        badge.setAccessibilityLabel("話者\(SpeakerNames.letter(for: slot))")
        content.addSubview(badge)
        field.frame = NSRect(x: 48, y: content.bounds.height - 44, width: 274, height: 26)
        field.stringValue = names.name(for: slot)
        field.placeholderString = SpeakerNames.defaultName(for: slot)
        field.setAccessibilityLabel("話者\(SpeakerNames.letter(for: slot))の名前")
        field.delegate = self
        content.addSubview(field)
        scroll.frame = NSRect(x: 14, y: 50, width: 312, height: listHeight)
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        content.addSubview(scroll)
        let reset = NSButton(title: "既定に戻す", target: self, action: #selector(resetPressed))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: 14, y: 12, width: 100, height: 26)
        content.addSubview(reset)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        updateRows()
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
    private var query: String { edited ? field.stringValue : "" }

    func controlTextDidChange(_ notification: Notification) {
        edited = true
        updateRows()
    }

    private func updateRows() {
        let matches = SpeakerSuggestions.filtered(candidates, query: query)
        rows = matches.map { Row(name: $0.name, candidate: $0) }
        selected = nil
        if !query.isEmpty {
            if let exact = SpeakerSuggestions.exactMatch(in: matches, query: query) {
                selected = rows.firstIndex { $0.name == exact.name }
            } else {
                rows.insert(Row(name: query, candidate: nil), at: 0)
                selected = 0
            }
        }
        drawRows(noMatches: !query.isEmpty && matches.isEmpty)
        list.scroll(.zero)
    }

    private func drawRows(noMatches: Bool = false) {
        list.subviews.forEach { $0.removeFromSuperview() }
        avatarRows.removeAll()
        let count = rows.count + (noMatches ? 1 : 0)
        list.frame = NSRect(x: 0, y: 0, width: 312, height: max(scroll.bounds.height, CGFloat(count * 28)))
        scroll.hasVerticalScroller = CGFloat(count * 28) > scroll.bounds.height
        for (index, row) in rows.enumerated() {
            let y = CGFloat(index * 28)
            let background = NSView(frame: NSRect(x: 0, y: y, width: 312, height: 28))
            if selected == index { Washi.surface(background); background.layer?.cornerRadius = 4 }
            list.addSubview(background)
            let label: NSTextField
            if let candidate = row.candidate {
                let avatar = AvatarView(frame: NSRect(x: 4, y: y + 2, width: 22, height: 23))
                avatar.slot = candidate.usedBySlot ?? slot
                avatar.initial = candidate.name == SpeakerNames.defaultName(for: avatar.slot ?? slot)
                    ? SpeakerNames.letter(for: avatar.slot ?? slot) : String(candidate.name.prefix(1))
                avatar.alphaValue = candidate.isSelectable ? 1 : 0.45
                list.addSubview(avatar)
                avatarRows.append((avatar, candidate.avatar))
                label = Washi.label(candidate.name, color: candidate.isSelectable ? Washi.ink : Washi.muted)
                let attributed = NSMutableAttributedString(string: candidate.name,
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: label.textColor ?? Washi.ink])
                for range in SpeakerSuggestions.matchRanges(in: candidate.name, query: query) {
                    attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .bold), range: range)
                }
                label.attributedStringValue = attributed
                let hint: String
                if let used = candidate.usedBySlot { hint = "話者\(SpeakerNames.letter(for: used))で使用中" }
                else { hint = candidate.isParticipant ? "参加者" : "" }
                let hintWidth: CGFloat = candidate.usedBySlot != nil ? 104 : (hint.isEmpty ? 0 : 42)
                label.frame = NSRect(x: 34, y: y + 5, width: 250 - hintWidth, height: 18)
                if !hint.isEmpty {
                    let note = Washi.label(hint, size: 10, color: Washi.muted)
                    note.frame = NSRect(x: 286 - hintWidth, y: y + 5, width: hintWidth, height: 18)
                    note.alignment = .right
                    list.addSubview(note)
                }
            } else {
                let icon = Washi.label("✎", size: 15, color: Washi.muted)
                icon.frame = NSRect(x: 6, y: y + 4, width: 22, height: 20)
                list.addSubview(icon)
                label = Washi.label("「\(row.name)」をそのまま使う")
                label.frame = NSRect(x: 34, y: y + 5, width: 250, height: 18)
            }
            label.lineBreakMode = .byTruncatingTail
            list.addSubview(label)
            if selected == index {
                let enter = Washi.label("⏎", size: 14, color: Washi.muted)
                enter.frame = NSRect(x: 290, y: y + 4, width: 18, height: 20)
                list.addSubview(enter)
            }
            let button = SpeakerButton(frame: NSRect(x: 0, y: y, width: 312, height: 28))
            button.title = ""
            button.isBordered = false
            button.isEnabled = row.isSelectable
            button.tag = index
            button.target = self
            button.action = #selector(candidatePressed(_:))
            let usedHint = row.candidate?.usedBySlot.map { "、話者\(SpeakerNames.letter(for: $0))で使用中" } ?? ""
            button.setAccessibilityLabel((row.candidate == nil ? "「\(row.name)」をそのまま使う" : row.name)
                + usedHint + (row.candidate?.isParticipant == true ? "、参加者" : ""))
            button.toolTip = row.name
            list.addSubview(button)
        }
        if noMatches {
            let empty = Washi.label("一致する候補はありません", color: Washi.muted)
            empty.frame = NSRect(x: 34, y: CGFloat(rows.count * 28 + 5), width: 260, height: 18)
            list.addSubview(empty)
        }
        refreshAvatars()
    }

    private func moveSelection(_ direction: Int) {
        let choices = rows.indices.filter { rows[$0].isSelectable }
        guard !choices.isEmpty else { return }
        if let selected, let index = choices.firstIndex(of: selected) {
            self.selected = choices[min(max(index + direction, 0), choices.count - 1)]
        } else {
            selected = direction > 0 ? choices.first : choices.last
        }
        drawRows(noMatches: !query.isEmpty && SpeakerSuggestions.filtered(candidates, query: query).isEmpty)
        if let selected { list.scrollToVisible(NSRect(x: 0, y: selected * 28, width: 312, height: 28)) }
    }

    @objc private func candidatePressed(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].isSelectable else { return }
        commit(rows[sender.tag].name)
    }
    @objc private func resetPressed() { commit("") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 日本語入力の未確定文字は入力メソッドへ渡す。Returnで変換を確定しても改名しない。
        if textView.hasMarkedText() { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSelection(1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelection(-1); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit(selected.map { rows[$0].name } ?? field.stringValue); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
}
