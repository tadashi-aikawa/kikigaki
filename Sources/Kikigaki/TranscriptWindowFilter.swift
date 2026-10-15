import AppKit
import KikigakiCore

/// 会話を話者で絞り込む。選んだ相手の行だけを出し、間の行は「ほかの発言N件」の線へ畳む。
/// 表示専用で、保存・コピー・AIへ渡す会話は変えない。並べ方はCoreの `TranscriptFilter` が決める。
extension TranscriptWindowController {
    struct FilterEntry {
        let row: any DocumentRow
        let key: FilterRowKey
        let subject: TranscriptFilter.Subject?
    }

    /// 行の並びへ絞り込みを当て、畳んだ区間を線の行へ置き換える。
    func arrangeFiltered(_ entries: [FilterEntry]) -> [any DocumentRow] {
        let layout = TranscriptFilter.layout(subjects: entries.map(\.subject), keys: entries.map(\.key),
                                             selected: filterSelection, expanded: filterExpanded)
        var next: [FilterRowKey: TranscriptFilterGapRow] = [:]
        let rows = layout.map { entry -> any DocumentRow in
            switch entry {
            case let .row(index): return entries[index].row
            case let .gap(indices, count):
                let keys = indices.map { entries[$0].key }
                // 区間の先頭の行で線を引き継ぎ、末尾へ行が増えても同じ線のまま件数だけを変える。
                let gap = gapRows[keys[0]] ?? TranscriptFilterGapRow()
                gap.update(count: count, keys: keys)
                let first: NSView = entries[indices[0]].row
                gap.onExpand = { [weak self, weak gap, weak first] in
                    guard let self, let gap else { return }
                    expandFilterGap(gap, first: first)
                }
                next[keys[0]] = gap
                return gap
            }
        }
        gapRows = next
        return rows
    }

    /// 開いた行の先頭を線のあった位置に置き、上の行を動かさない。
    func expandFilterGap(_ gap: TranscriptFilterGapRow, first: NSView?) {
        let clip = scrollView.contentView.bounds
        let anchor = TranscriptDocument.Anchor(candidates: first.map { [($0, gap.frame.minY - clip.minY)] } ?? [],
                                               y: clip.minY, atBottom: false)
        filterExpanded.formUnion(gap.keys)
        refreshRows(anchor: anchor)
    }

    /// 畳まれた行へ移る前に、その行を含む区間を開く。表示中なら何もしない。
    func revealFilteredRow(_ key: FilterRowKey) {
        guard let gap = transcriptDocument.rows.lazy.compactMap({ $0 as? TranscriptFilterGapRow })
            .first(where: { $0.keys.contains(key) }) else { return }
        filterExpanded.formUnion(gap.keys)
        refreshRows()
    }

    func setFilter(_ selection: Set<TranscriptFilter.Subject>) {
        guard selection != filterSelection else { return }
        let anchor = transcriptDocument.anchor()
        filterSelection = selection
        filterExpanded = []
        updateFilterControls()
        window?.contentView?.layoutSubtreeIfNeeded()
        refreshRows(anchor: anchor)
    }

    /// 会議が変わったら解除から始める。並べ直しは呼び出し側の更新に任せる。
    func resetFilter() {
        filterSelection = []
        filterExpanded = []
        filterPopover?.close()
    }

    private var filterAINames: [String] {
        (snapshot.ai?.conversation?.questions ?? []).map { $0.request.envelope.participant.participantName }
    }

    func updateFilterControls() {
        let subjects = TranscriptFilter.subjects(utterances: snapshot.utterances, aiNames: filterAINames, selected: filterSelection)
        let active = !filterSelection.isEmpty
        filterButton.isEnabled = !subjects.isEmpty
        let title = active ? "話者で絞り込み中" : "話者で絞り込む"
        filterButton.image = NSImage(systemSymbolName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                                     accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        filterButton.imagePosition = .imageOnly
        filterButton.title = ""
        filterButton.contentTintColor = Washi.ink
        filterButton.toolTip = title
        filterButton.setAccessibilityLabel(title)
        filterButton.setAccessibilityValue(active ? subjects.filter(filterSelection.contains).map(filterName).joined(separator: "、") : nil)
        filterBar.update(subjects.filter(filterSelection.contains).map { subject in
            .init(subject: subject, name: filterName(subject)) { [weak self] avatar in self?.configureFilterAvatar(avatar, for: subject) }
        })
        filterPopover?.update(items: subjects.map { subject in
            var title = filterName(subject)
            if case .ai = subject { title += "(AI)" }
            return .init(subject: subject, title: title) { [weak self] avatar in self?.configureFilterAvatar(avatar, for: subject) }
        }, selected: filterSelection)
    }

    private func filterName(_ subject: TranscriptFilter.Subject) -> String {
        TranscriptFilter.name(for: subject, names: snapshot.names)
    }

    /// 札のアバターを、その相手の行と同じ色・記号・画像にする。
    private func configureFilterAvatar(_ avatar: AvatarView, for subject: TranscriptFilter.Subject) {
        avatar.typed = false; avatar.undiarized = false; avatar.accent = nil; avatar.slot = nil; avatar.image = nil
        switch subject {
        case let .speaker(slot):
            let name = snapshot.names.name(for: slot)
            avatar.slot = slot
            avatar.undiarized = slot == nil && !snapshot.names.diarizationEnabled
            avatar.initial = slot.map { snapshot.names.customName(for: $0) == nil ? SpeakerNames.letter(for: $0) : String(name.prefix(1)) } ?? "?"
            avatar.image = slot == nil ? nil : avatars.image(for: snapshot.speakers.first { $0.name == name }?.avatar)
        case .typed:
            avatar.typed = true
        case let .ai(name):
            avatar.accent = Washi.ai
            avatar.initial = String(name.prefix(1))
            let request = snapshot.ai?.conversation?.questions.first { $0.request.envelope.participant.participantName == name }?.request
            avatar.image = request.flatMap { snapshot.ai?.avatarSource(for: $0.id) }.flatMap { avatars.image(for: $0) }
        }
    }
}
