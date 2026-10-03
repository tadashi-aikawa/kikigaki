import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct TranscriptScrollTests {
    private func controller(rows count: Int) -> (TranscriptWindowController, SessionSnapshot) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        let utterances = (0..<count).map { index in
            Utterance(speaker: index % 2, start: Double(index) * 6, end: Double(index) * 6 + 5, text: "発言\(index)")
        }
        var state = SessionSnapshot(state: .recording, utterances: utterances,
                                    timeline: MeetingTimeline(startedAt: Date(timeIntervalSince1970: 0)))
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-scroll.md")
        controller.apply(state)
        return (controller, state)
    }

    /// 載っている行と、見えている範囲の近くにある行が一致する。
    private func expectMountedNearViewport(_ controller: TranscriptWindowController) {
        let document = controller.transcriptDocument
        let clip = controller.scrollView.contentView.bounds
        let area = clip.insetBy(dx: 0, dy: -max(TranscriptDocument.mountMargin, clip.height))
        for row in document.rows {
            #expect((row.superview === document) == row.frame.intersects(area))
        }
    }

    @Test func 長い会話では見えている範囲の近くの行だけを載せる() {
        let (controller, _) = controller(rows: 400)
        let document = controller.transcriptDocument
        #expect(document.rows.count == 400)
        let mounted = document.rows.filter { $0.superview === document }
        #expect(!mounted.isEmpty && mounted.count < 100)
        #expect(document.rows.last?.superview === document)
        #expect(document.rows.first?.superview == nil)
        // 載せていない行も枠は置いてあり、文書の高さは全行ぶんになる。
        #expect(document.rows.last!.frame.maxY > CGFloat(400) * 40)
        expectMountedNearViewport(controller)
    }

    @Test func スクロールすると先で見える行を載せ替える() {
        let (controller, _) = controller(rows: 400)
        let document = controller.transcriptDocument
        document.scroll(.zero)
        #expect(document.rows.first?.superview === document)
        #expect(document.rows.last?.superview == nil)
        expectMountedNearViewport(controller)
        // 描画順は行の順のまま、範囲の印より下に置く。
        let order = document.subviews.compactMap { view in document.rows.firstIndex { $0 === view } }
        #expect(order == order.sorted())
    }

    @Test func 外した行を載せ直しても範囲の印は行より上に描く() {
        let (controller, _) = controller(rows: 400)
        let document = controller.transcriptDocument
        let rows = document.rows.compactMap { $0 as? TranscriptRow }
        document.setRangeBoundaries(AIRangeBoundaries(answered: 390, accepted: 395), utteranceRows: rows)
        #expect(document.rangeMarkers.count == 2)
        // 末尾近くの印の行を一度外し、戻って載せ直す。
        document.scroll(.zero)
        #expect(document.rangeMarkers.allSatisfy { $0.row.superview == nil })
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        #expect(document.rangeMarkers.allSatisfy { $0.row.superview === document })
        let markers = document.rangeMarkers.map(\.view)
        let lastRow = document.subviews.lastIndex { view in document.rows.contains { $0 === view } }!
        #expect(markers.allSatisfy { marker in document.subviews.firstIndex(of: marker)! > lastRow })
    }

    @Test func 上を読んでいる間の更新でも読んでいる位置を保つ() {
        var (controller, state) = controller(rows: 400)
        let document = controller.transcriptDocument
        let middle = document.rows[200]
        document.scroll(NSPoint(x: 0, y: middle.frame.minY))
        let y = controller.scrollView.contentView.bounds.minY
        state.utterances.append(Utterance(speaker: 0, start: 2400, end: 2405, text: "追加"))
        controller.apply(state)
        #expect(controller.scrollView.contentView.bounds.minY == y)
        #expect(middle.superview === document)
        #expect(document.rows.last?.superview == nil)
        expectMountedNearViewport(controller)
    }

    @Test func 縦に伸ばすと新しく見える範囲の行を載せる() {
        let (controller, _) = controller(rows: 400)
        let window = controller.window!
        controller.transcriptDocument.scroll(.zero)
        var frame = window.frame
        frame.size.height += 2000
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        expectMountedNearViewport(controller)
    }
}
