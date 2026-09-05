import AppKit
import KikigakiCore

/// 会話内の検索。一致箇所は行ビューへ塗り、現在位置だけ濃くする
extension TranscriptWindowController {
    struct SearchHit: Equatable {
        let row: RowID
        let rowIndex: Int
        let inName: Bool
        let range: NSRange
    }

    @objc func showSearch(_ sender: Any?) {
        let anchor = transcriptDocument.anchor()
        searchOpen = true
        transcriptDocument.followsBottom = false
        searchBar.isHidden = false
        window?.contentView?.layoutSubtreeIfNeeded()
        transcriptDocument.reflow(anchor: anchor)
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        refreshSearch(reset: false, reveal: true)
    }
    @objc func closeSearch(_ sender: Any?) {
        guard searchOpen else { return }
        let anchor = transcriptDocument.anchor()
        searchOpen = false
        searchBar.isHidden = true
        window?.makeFirstResponder(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        transcriptDocument.followsBottom = true
        transcriptDocument.reflow(anchor: anchor)
        refreshSearch(reset: true, reveal: false)
        scrolled()
    }
    @objc func findNext(_ sender: Any?) { moveSearch(by: 1) }
    @objc func findPrevious(_ sender: Any?) { moveSearch(by: -1) }
    func moveSearch(by direction: Int) {
        if !searchOpen { showSearch(nil); return }
        guard !searchHits.isEmpty else { return }
        currentHit = ((currentHit ?? 0) + direction + searchHits.count) % searchHits.count
        paintSearch()
        revealCurrentHit()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        refreshSearch(reset: true, reveal: true)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeSearch(nil); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertLineBreak(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            moveSearch(by: NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            return true
        }
        return false
    }
    func refreshSearch(reset: Bool, reveal: Bool) {
        let previous = currentHit.flatMap { searchHits.indices.contains($0) ? searchHits[$0] : nil }
        searchHits = []
        if searchOpen, !searchField.stringValue.isEmpty {
            var occurrences: [Double: Int] = [:]
            for (index, utterance) in snapshot.utterances.enumerated() {
                let occurrence = occurrences[utterance.start, default: 0]
                occurrences[utterance.start] = occurrence + 1
                let id = RowID(start: utterance.start, occurrence: occurrence)
                for (inName, text) in [(true, snapshot.names.name(for: utterance.speaker)), (false, utterance.text)] {
                    for range in TranscriptSearch.ranges(in: text, query: searchField.stringValue) {
                        searchHits.append(SearchHit(row: id, rowIndex: index, inName: inName, range: NSRange(range, in: text)))
                    }
                }
            }
        }
        if searchHits.isEmpty { currentHit = nil }
        else if !reset, let previous {
            let sameRow = searchHits.indices.filter { searchHits[$0].row == previous.row }
            currentHit = sameRow.min { a, b in
                let left = searchHits[a], right = searchHits[b]
                if (left.inName == previous.inName) != (right.inName == previous.inName) { return left.inName == previous.inName }
                return abs(left.range.location - previous.range.location) < abs(right.range.location - previous.range.location)
            } ?? searchHits.indices.min { abs(searchHits[$0].rowIndex - previous.rowIndex) < abs(searchHits[$1].rowIndex - previous.rowIndex) }
        } else { currentHit = 0 }
        paintSearch()
        let rowDisappeared = previous.map { old in !searchHits.contains { $0.row == old.row } } ?? false
        if reveal || rowDisappeared || (previous == nil && currentHit != nil) { revealCurrentHit() }
    }
    private func paintSearch() {
        let current = currentHit.map { searchHits[$0] }
        let grouped = Dictionary(grouping: searchHits, by: \.row)
        for (id, row) in rows {
            let hits = grouped[id] ?? []
            row.markSearch(nameRanges: hits.filter(\.inName).map(\.range), textRanges: hits.filter { !$0.inName }.map(\.range),
                           currentName: current?.row == id && current?.inName == true ? current?.range : nil,
                           currentText: current?.row == id && current?.inName == false ? current?.range : nil)
        }
        searchCount.stringValue = currentHit.map { "\($0 + 1) / \(searchHits.count)" } ?? (searchField.stringValue.isEmpty ? "" : "一致なし")
        searchPrevious.isEnabled = !searchHits.isEmpty
        searchNext.isEnabled = !searchHits.isEmpty
    }
    private func revealCurrentHit() {
        guard let currentHit, let row = rows[searchHits[currentHit].row] else { return }
        let clip = scrollView.contentView.bounds
        if row.frame.minY < clip.minY || row.frame.maxY > clip.maxY {
            transcriptDocument.scroll(NSPoint(x: 0, y: max(0, min(row.frame.minY - 8, transcriptDocument.frame.height - clip.height))))
        }
        scrolled()
    }
}
