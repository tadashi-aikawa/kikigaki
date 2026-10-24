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

    @Test func 書き起こし中のメニューの表題は中止() {
        #expect(RecordingState.recording.startStopTitle(transcribingFile: true) == "書き起こしを中止")
        #expect(RecordingState.recording.statusLabel(transcribingFile: true) == "書き起こし中")
        #expect(RecordingState.finishing.statusLabel(transcribingFile: true) == "保存中")
        #expect(RecordingState.idle.startStopTitle(transcribingFile: true) == "録音を開始")
        #expect(RecordingState.recording.startStopTitle(transcribingFile: false) == "録音を停止")
    }

    @Test func 完了時に送信は周期を飛ばし保存後の1回だけを送る() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = AIScheduleState(meetingID: UUID())
        try state.startFinalOnly(options: .init(prompt: "議事録を作成", interval: 180, workAllowed: false), runID: UUID())
        #expect(state.finalOnly)
        #expect(state.phase == .awaitingSave)
        #expect(state.nextFire == nil)
        #expect(state.fireNow(now: now, availability: .ready, hasChanges: true) == .none)
        #expect(state.tick(now: now.addingTimeInterval(3600), availability: .ready, hasChanges: true) == .none)
        // 書き起こしの終わりは録音の停止と同じ経路を通るが、周期が無いので状態を変えない。
        state.recordingStopped()
        #expect(state.phase == .awaitingSave)
        #expect(state.finalSaveCompleted(succeeded: true) == .none)
        #expect(state.finalDecision(availability: .ready, hasChanges: true) == .send(final: true))
        #expect(state.phase == .stopped)
        // 新しい会議で録音の自動送信を始めたら、完了時の扱いを持ち越さない。
        try state.start(options: .init(prompt: "次"), now: now, runID: UUID())
        #expect(!state.finalOnly)
    }

    @Test func 完了時に送信は保存に失敗したら送らない() throws {
        var state = AIScheduleState(meetingID: UUID())
        try state.startFinalOnly(options: .init(prompt: "議事録を作成"), runID: UUID())
        #expect(state.finalSaveCompleted(succeeded: false) == .skipped(.saveFailed))
        #expect(state.phase == .stopped)
        #expect(throws: AIError.self) {
            var running = AIScheduleState(meetingID: UUID())
            try running.start(options: .init(prompt: "録音"), now: Date(), runID: UUID())
            try running.startFinalOnly(options: .init(prompt: "二重"), runID: UUID())
        }
    }
}
