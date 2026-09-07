import AppKit
import Testing
@testable import Kikigaki

@Suite @MainActor struct RecordingPulseTests {
    @Test func 録音の点は秒境界だけで切り替わりアニメーションを持たない() throws {
        let chip = RecordingStatusChip()
        let mark = try #require(chip.arrangedSubviews.first as? NSTextField)
        let layer = try #require(mark.layer)
        var snapshot = SessionSnapshot(state: .recording)
        for (time, expected) in [(0.0, Float(1)), (0.9, 1), (1.0, 0.45), (1.9, 0.45), (2.0, 1)] {
            snapshot.elapsed = time
            chip.update(snapshot, reduceMotion: false)
            #expect(layer.opacity == expected)
            #expect(layer.animationKeys()?.isEmpty ?? true)
        }
        snapshot.elapsed = 3
        chip.update(snapshot, reduceMotion: true)
        #expect(layer.opacity == 1)
        chip.update(snapshot, reduceMotion: false)
        #expect(layer.opacity == 0.45)
        snapshot.state = .paused
        chip.update(snapshot, reduceMotion: false)
        #expect(layer.opacity == 1 && mark.stringValue == "‖")
        snapshot.state = .idle
        chip.update(snapshot, reduceMotion: false)
        #expect(layer.opacity == 1 && mark.isHidden)
        #expect(layer.animationKeys()?.isEmpty ?? true)
    }
}
