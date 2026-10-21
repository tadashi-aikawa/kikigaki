import Foundation
import Testing
@testable import KikigakiCore

@Suite struct InterimSaveTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    // 2026-09-05 12:40 JST
    private let startedAt = Date(timeIntervalSince1970: 1_788_579_600)
    private func meeting(duration: Double, utterances: [Utterance]) -> MeetingMarkdown.Meeting {
        MeetingMarkdown.Meeting(startedAt: startedAt, duration: duration, utterances: utterances, names: SpeakerNames())
    }
    private let first = Utterance(speaker: 0, start: 0, end: 2, text: "始めます")

    @Test func 途中保存は状態の行に保存時刻を書き停止後の本文には出さない() throws {
        var save = InterimSave()
        var written: [String] = []
        let at = startedAt.addingTimeInterval(97)
        #expect(try save.save(meeting(duration: 95, utterances: [first]), at: at, timeZone: tokyo) {
            written.append(String(decoding: $0, as: UTF8.self))
        })
        let expected = """
            # KIKIGAKI 2026-09-05 12:40

            - 開始: 2026-09-05 12:40
            - 長さ: 01:35
            - 状態: 録音中の途中保存 (12:41:37)
            - 話者: A=話者A

            ## 書き起こし

            - [12:40:00] 話者A: 始めます

            """
        #expect(written == [expected])
        #expect(!MeetingMarkdown.render(meeting(duration: 95, utterances: [first]), timeZone: tokyo).contains("状態"))
    }

    @Test func 長さだけ進んだときは書かず本文が変われば書く() throws {
        var save = InterimSave()
        var count = 0
        let write: (Data) throws -> Void = { _ in count += 1 }
        #expect(try save.save(meeting(duration: 10, utterances: [first]), at: startedAt, write: write))
        #expect(try !save.save(meeting(duration: 70, utterances: [first]), at: startedAt.addingTimeInterval(60), write: write))
        let second = Utterance(speaker: 1, start: 71, end: 72, text: "はい")
        #expect(try save.save(meeting(duration: 75, utterances: [first, second]), at: startedAt.addingTimeInterval(120), write: write))
        #expect(count == 2)
    }

    @Test func 書き込みに失敗した内容は次の周期で書き直す() throws {
        struct Failure: Error {}
        var save = InterimSave()
        #expect(throws: Failure.self) {
            try save.save(meeting(duration: 10, utterances: [first]), at: startedAt) { _ in throw Failure() }
        }
        var count = 0
        #expect(try save.save(meeting(duration: 70, utterances: [first]), at: startedAt.addingTimeInterval(60)) { _ in count += 1 })
        #expect(count == 1)
    }

    @Test func 間隔の表記は分で割り切れれば分にする() {
        #expect(InterimSave.intervalLabel(seconds: 60) == "1分")
        #expect(InterimSave.intervalLabel(seconds: 3600) == "60分")
        #expect(InterimSave.intervalLabel(seconds: 90) == "90秒")
        #expect(InterimSave.intervalLabel(seconds: 30) == "30秒")
    }
}
