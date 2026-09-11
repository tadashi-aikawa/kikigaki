import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIHeaderMetricsTests {
    @Test func 記録範囲と認識人数を11ptで表示して600幅に収める() throws {
        _ = NSApplication.shared
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        let window = controller.window!
        window.setFrameAutosaveName(""); window.setContentSize(NSSize(width: 600, height: 578))
        var state = SessionSnapshot(state: .recording, utterances: [.init(speaker: 0, start: 0, end: 1, text: "会議を始めます")],
            timeline: .init(startedAt: Date(timeIntervalSince1970: 1_788_759_600)), elapsed: 754,
            markdownURL: URL(fileURLWithPath: "/tmp/meeting.md"))
        state.detectedSpeakerSlots = [0, 1, 2]
        controller.apply(state)
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content)
        // 表示は端末のタイムゾーンに従うため、期待値も同じ整形で作る(CIのUTCで "14:40〜" 固定は落ちる)。
        let expected = state.timeline.clock(at: 0) + "〜"
        let range = try #require(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == expected })
        let speakers = try #require(views.compactMap { $0 as? SpeakerCountButton }.first)
        #expect(range.font?.pointSize == 11 && speakers.countFont.pointSize == 11)
        #expect(speakers.countText == "3/4")
        #expect(range.frame.width >= range.intrinsicContentSize.width)
        #expect((speakers.countText as NSString).size(withAttributes: [.font: speakers.countFont]).width <= speakers.bounds.width)
        #expect(content.convert(range.bounds, from: range).maxX <= content.convert(speakers.bounds, from: speakers).minX)
    }
}
