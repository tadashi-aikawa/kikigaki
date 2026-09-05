import Foundation
import Testing
@testable import KikigakiCore

@Suite struct MeetingTimelineTests {
    private let start = Date(timeIntervalSince1970: 0)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func 一時停止の前後と境界を変換する() {
        let timeline = MeetingTimeline(startedAt: start, pauses: [.init(audioTime: 10, duration: 90)])
        #expect(timeline.date(at: 9.5) == start.addingTimeInterval(9.5))
        #expect(timeline.date(at: 10) == start.addingTimeInterval(100))
        #expect(timeline.clock(at: 15, seconds: true, timeZone: utc) == "00:01:45")
        #expect(timeline.clock(at: 15, timeZone: utc) == "00:01")
    }

    @Test func 複数回と同じ位置での再停止を累積する() {
        let timeline = MeetingTimeline(startedAt: start, pauses: [
            .init(audioTime: 10, duration: 20), .init(audioTime: 10, duration: 5),
            .init(audioTime: 30, duration: 60)
        ])
        #expect(timeline.date(at: 9) == start.addingTimeInterval(9))
        #expect(timeline.date(at: 10) == start.addingTimeInterval(35))
        #expect(timeline.date(at: 29) == start.addingTimeInterval(54))
        #expect(timeline.date(at: 30) == start.addingTimeInterval(115))
    }

    @Test func 日跨ぎとタイムゾーンとreplayの長さ() {
        let timeline = MeetingTimeline(startedAt: start.addingTimeInterval(86390))
        #expect(timeline.clock(at: 20, seconds: true, timeZone: utc) == "00:00:10")
        #expect(timeline.clock(at: 20, seconds: true, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!) == "09:00:10")
        // replayの処理にかかった実時間ではなく、音声の20秒を加える。
        #expect(timeline.date(at: 20) == start.addingTimeInterval(86410))
    }

    @Test func 収録位置で停止し停止中の音声と消費側の遅れを含めない() {
        var clock = RecordedAudioClock(startedAt: start)
        let accepted = clock.accept(sampleCount: 160_000)
        #expect(accepted)
        clock.pause(at: start.addingTimeInterval(10))
        let dropped = clock.accept(sampleCount: 800_000)
        #expect(!dropped)
        #expect(clock.acceptedSamples == 160_000)
        // 消費側の表示が仮に3秒でも、収録済み10秒が境界。
        clock.resume(at: start.addingTimeInterval(60))
        #expect(clock.timeline.pauses == [.init(audioTime: 10, duration: 50)])
        let resumed = clock.accept(sampleCount: 16_000)
        #expect(resumed)
        #expect(clock.timeline.date(at: 10) == start.addingTimeInterval(60))
        #expect(clock.timeline.date(at: 11) == start.addingTimeInterval(61))
    }

    @Test func 停止中に終了すると未再開の休止を過去の発言へ足さない() {
        var clock = RecordedAudioClock(startedAt: start)
        clock.accept(sampleCount: 160_000)
        clock.pause(at: start.addingTimeInterval(10))
        clock.pause(at: start.addingTimeInterval(30))
        #expect(clock.isPaused)
        #expect(clock.timeline.date(at: 9) == start.addingTimeInterval(9))
        clock.resume(at: start.addingTimeInterval(40))
        clock.resume(at: start.addingTimeInterval(50))
        #expect(clock.timeline.pauses == [.init(audioTime: 10, duration: 30)])
        let fresh = RecordedAudioClock(startedAt: start.addingTimeInterval(100))
        #expect(!fresh.isPaused)
        #expect(fresh.acceptedSamples == 0)
        #expect(fresh.timeline.pauses.isEmpty)
    }

    @Test func Markdownは休止を含む実時刻と音声の長さを別々に出す() {
        let meeting = MeetingMarkdown.Meeting(startedAt: start, duration: 20,
            utterances: [.init(speaker: 0, start: 11, end: 15, text: "再開後")], names: .init(),
            pauses: [.init(audioTime: 10, duration: 90)])
        let markdown = MeetingMarkdown.render(meeting, timeZone: utc)
        #expect(markdown.contains("- 長さ: 00:20"))
        #expect(markdown.contains("- [00:01:41] 話者A: 再開後"))
    }
}

@Suite struct LiveTranscriptTests {
    private let tokens: [TimedToken] = [
        .init(text: "確認しました。", phraseId: 0, start: 0, end: 2),
        .init(text: "次は", phraseId: 1, start: 3, end: 4),
        .init(text: "予算です", phraseId: 1, start: 4, end: 5)
    ]

    @Test func 確定末尾と同じ話者でも暫定は独立する() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 0, 0], finalCount: 1)
        #expect(live.utterances.map(\.text) == ["確認しました。"])
        #expect(live.utterances.map(\.speaker) == [0])
        #expect(live.tentativeText == "次は予算です")
    }

    @Test func 暫定中の話者交代は1つの本文にまとまる() {
        let live = LiveTranscript(tokens: tokens, speakers: [nil, 1, 2], finalCount: 0)
        #expect(live.utterances.isEmpty)
        #expect(live.tentativeText == "確認しました。次は予算です")
    }

    @Test func 全確定で暫定が消えて話者が付く() {
        let live = LiveTranscript(tokens: tokens, speakers: [nil, 1, 1], finalCount: 3)
        #expect(live.tentativeText == nil)
        #expect(live.utterances.map(\.text) == ["確認しました。", "次は予算です"])
        #expect(live.utterances.map(\.speaker) == [nil, 1])
    }

    @Test func 空と範囲外の確定数を安全に扱う() {
        #expect(LiveTranscript(tokens: [], speakers: [], finalCount: 3).utterances.isEmpty)
        #expect(LiveTranscript(tokens: tokens, speakers: [0, 0, 0], finalCount: -1).utterances.isEmpty)
        #expect(LiveTranscript(tokens: tokens, speakers: [0, 0, 0], finalCount: 99).tentativeText == nil)
    }

    @Test func コピーに暫定を混ぜず昇格後だけ追加する() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 0)
        let timeline = MeetingTimeline(startedAt: start, pauses: [.init(audioTime: 3, duration: 60)])
        var history = HandoffHistory(startedAt: start)
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1], finalCount: 1)
        let first = try #require(history.copy(utterances: live.utterances, names: .init(), outputDirectory: directory,
                                             timeline: timeline) { _ in true })
        let original = try String(contentsOf: first.fileURL, encoding: .utf8)
        #expect(!original.contains("予算"))
        let final = LiveTranscript(tokens: tokens, speakers: [0, 1, 1], finalCount: 3)
        let second = try #require(history.copy(utterances: final.utterances, names: .init(), outputDirectory: directory,
                                              timeline: timeline) { _ in true })
        #expect(second.preview.startLine == 2)
        #expect(second.preview.startTime == 3)
        #expect(!second.preview.includesCorrections)
        let stamp = timeline.clock(at: 3, seconds: true)
        #expect(try String(contentsOf: second.fileURL, encoding: .utf8).contains("[\(stamp)] 話者B: 次は予算です"))
        #expect(try String(contentsOf: first.fileURL, encoding: .utf8) == original)
        #expect(try history.recopy { _ in true } == second)
        #expect(history.preview(utterances: final.utterances, names: .init(), timeline: timeline) == nil)
    }
}
