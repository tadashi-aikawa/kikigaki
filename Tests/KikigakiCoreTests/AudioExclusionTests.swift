import Foundation
import Testing
@testable import KikigakiCore

@Suite struct AudioExclusionTests {
    private func fixture() throws -> (AudioLevelTrack, [Utterance]) {
        var meter = AudioLevelMeter()
        meter.append(Array(repeating: 0.1, count: 16000))
        meter.append(Array(repeating: 0.001, count: 16000))
        return (meter.track(), [.init(speaker: nil, start: 0, end: 1, text: "通常の声。"),
            .init(speaker: nil, start: 1, end: 2, text: "小さな声。"),
            try .init(typedText: "手入力", at: 2, postedAt: Date())])
    }
    @Test func 境界と欠測と手入力を守り設定変更で復元する() throws {
        let (track, rows) = try fixture()
        let on = AudioExclusion(enabled: true)
        #expect(on.included(rows, track: track).map(\.text) == ["通常の声。", "手入力"])
        #expect(AudioExclusion().included(rows, track: track) == rows)
        #expect(AudioExclusion(enabled: true, thresholdDBFS: -70).included(rows, track: track) == rows)
        #expect(on.included(rows, track: nil) == rows)
        #expect(!on.belowThreshold(-55) && on.belowThreshold(-55.01))
        #expect(AudioExclusion(thresholdDBFS: .nan).thresholdDBFS == -55)
    }
    @Test func 診断OFFで本文から除外し元発話と設定を保存して復元する() throws {
        let (track, rows) = try fixture()
        var meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 2, utterances: rows, names: SpeakerNames(), audioLevels: track)
        meeting.audioExclusion = AudioExclusion(enabled: true); meeting.showAudioLevels = false
        let data = try JSONEncoder().encode(meeting)
        var restored = try JSONDecoder().decode(MeetingMarkdown.Meeting.self, from: data)
        #expect(restored.utterances == rows && restored.audioLevels == track)
        let markdown = MeetingMarkdown.render(restored)
        let parts = markdown.components(separatedBy: "## 小音量で除外した発話")
        #expect(parts.count == 2 && !parts[0].contains("小さな声。") && parts[1].contains("小さな声。"))
        #expect(!markdown.contains("## 音量の計測"))
        restored.audioExclusion?.enabled = false
        #expect(!MeetingMarkdown.render(restored).contains("## 小音量で除外した発話"))
        #expect(MeetingMarkdown.render(restored).contains("小さな声。"))
    }
    @Test func AI本文と音声質問と暫定末尾から小声を除外する() throws {
        let (track, rows) = try fixture()
        let tokens = [TimedToken(text: rows[0].text, phraseId: 0, start: 0, end: 1),
                      TimedToken(text: rows[1].text, phraseId: 1, start: 1, end: 2)]
        for count in [1, 2] {
            let capture = try AICapture(tokens: tokens, speakers: [0, 1], finalCount: count, processedUntil: 2,
                cutoff: 2, names: SpeakerNames(), timeline: MeetingTimeline(startedAt: Date()), typed: [rows[2]],
                audioExclusion: AudioExclusion(enabled: true), audioLevels: track)
            #expect(!capture.lines.joined().contains("小さな声。"))
            #expect(capture.lines.joined().contains("手入力"))
            #expect(capture.voice.isEmpty && capture.tail == nil && capture.voiceUtteranceStart == nil)
            #expect(capture.voiceExcluded)
        }
    }
    @Test func 相槌省略の原文は小音量除外を適用せず順番を保つ() throws {
        let (track, rows) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 2, utterances: rows, names: SpeakerNames(), audioLevels: track)
        meeting.audioExclusion = .init(enabled: true); meeting.showAudioLevels = false
        let url = root.appendingPathComponent("meeting.md")
        var archive = MeetingArchive(original: meeting, processed: rows, candidateCount: 0, markdownURL: url)
        let result = archive.save()
        #expect(result.succeeded && result.rawSucceeded)
        let raw = try String(contentsOf: MeetingFiles.rawURL(for: url), encoding: .utf8)
        #expect(raw.contains("通常の声。") && raw.contains("小さな声。") && !raw.contains("## 小音量で除外した発話"))
        #expect(!FileManager.default.fileExists(atPath: MeetingFiles.levelsURL(for: url).path))
    }
    @Test func 全除外は削除訂正となり復元も差分で伝える() throws {
        let (track, rows) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let quiet = [rows[1]], names = SpeakerNames()
        var history = HandoffHistory()
        #expect(history.preview(utterances: [], names: names) == nil)
        _ = try history.copy(utterances: quiet, names: names, outputDirectory: root, writeClipboard: { _ in true })
        let empty = AudioExclusion(enabled: true).included(quiet, track: track)
        let removedCopy = try history.copy(utterances: empty, names: names, outputDirectory: root, writeClipboard: { _ in true })
        let removal = try #require(removedCopy)
        #expect(removal.preview.lineCount == 0 && removal.preview.includesCorrections)
        let restoredCopy = try history.copy(utterances: quiet, names: names, outputDirectory: root, writeClipboard: { _ in true })
        let restored = try #require(restoredCopy)
        #expect(restored.preview.lineCount == 1)
    }
}
