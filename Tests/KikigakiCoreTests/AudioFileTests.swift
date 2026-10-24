import Foundation
import Testing

@testable import KikigakiCore

/// 音声ファイルの書き起こし。仕様は docs/audio-file.md
@Suite struct AudioFileTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    // 2026-10-20 10:00 JST
    private let recordedAt = Date(timeIntervalSince1970: 1_792_458_000)

    @Test func 開始シートの行は長さと録音日時を出す() {
        let file = AudioFile(url: URL(fileURLWithPath: "/tmp/定例.m4a"), duration: 1935, recordedAt: recordedAt)
        #expect(file.name == "定例.m4a")
        #expect(file.summary(timeZone: tokyo) == "32:15 · 10/20 10:00 録音")
        #expect(AudioFile.datePrefix(recordedAt, timeZone: tokyo) == "10/20 ")
    }

    @Test func 書き起こし中の位置は全体の長さを超えない() {
        let file = AudioFile(url: URL(fileURLWithPath: "/tmp/a.wav"), duration: 1935, recordedAt: recordedAt)
        #expect(file.progress(at: 750) == "12:30 / 32:15")
        // 最後のチャンクは長さの端数を越えて数えることがある。
        #expect(file.progress(at: 1935.4) == "32:15 / 32:15")
    }

    @Test func 録音日時はメタデータを優先しファイルの作成日時へ戻る() {
        let metadata = Date(timeIntervalSince1970: 100), created = Date(timeIntervalSince1970: 200)
        let fallback = Date(timeIntervalSince1970: 300)
        #expect(AudioFile.recordedAt(metadata: metadata, fileCreation: created, fallback: fallback) == metadata)
        #expect(AudioFile.recordedAt(metadata: nil, fileCreation: created, fallback: fallback) == created)
        #expect(AudioFile.recordedAt(metadata: nil, fileCreation: nil, fallback: fallback) == fallback)
    }

    @Test func 会議Markdownは長さの下に元のファイル名を出す() throws {
        var meeting = MeetingMarkdown.Meeting(startedAt: recordedAt, duration: 1935,
            utterances: [Utterance(speaker: 0, start: 0, end: 2, text: "始めます")], names: SpeakerNames())
        #expect(!MeetingMarkdown.render(meeting, timeZone: tokyo).contains("- 音声:"))
        meeting.sourceAudio = "定例\n2.m4a"
        let lines = MeetingMarkdown.render(meeting, timeZone: tokyo).components(separatedBy: "\n")
        let length = try #require(lines.firstIndex(of: "- 長さ: 32:15"))
        #expect(lines[length + 1] == "- 音声: 定例 2.m4a")
        // 旧archiveは音源の欄を持たない。
        let decoded = try JSONDecoder().decode(MeetingMarkdown.Meeting.self,
            from: JSONEncoder().encode(MeetingMarkdown.Meeting(startedAt: recordedAt, duration: 1, utterances: [], names: SpeakerNames())))
        #expect(decoded.sourceAudio == nil)
    }

    @Test func 書き起こし中のメニューの表題は中止で仕上げ中は完了() {
        #expect(RecordingState.recording.startStopTitle(transcribingFile: true) == "書き起こしを中止")
        #expect(RecordingState.recording.statusLabel(transcribingFile: true) == "書き起こし中")
        #expect(RecordingState.finishing.statusLabel(transcribingFile: true) == "保存中")
        #expect(RecordingState.idle.startStopTitle(transcribingFile: false, reviewingFile: true) == "仕上げを完了")
        #expect(RecordingState.idle.statusLabel(transcribingFile: false, reviewingFile: true) == "仕上げ中")
        #expect(RecordingState.idle.startStopTitle(transcribingFile: false) == "録音を開始")
        #expect(RecordingState.recording.startStopTitle(transcribingFile: false) == "録音を停止")
    }
}
