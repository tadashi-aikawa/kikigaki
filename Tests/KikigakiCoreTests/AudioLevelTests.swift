import Foundation
import Testing
@testable import KikigakiCore

@Suite struct AudioLevelTests {
    private func track(_ amplitudes: [Float], samplesPerLevel: Int = 1600) -> AudioLevelTrack {
        var meter = AudioLevelMeter()
        for amplitude in amplitudes { meter.append(Array(repeating: amplitude, count: samplesPerLevel)) }
        return meter.track(includingPartial: true)
    }

    @Test func 既知振幅と無音と端数をチャンク分割に依存せず計測する() throws {
        let samples: [Float] = Array(repeating: 0.1, count: 1600) + Array(repeating: 0.01, count: 1600) + Array(repeating: 0, count: 321)
        var whole = AudioLevelMeter(); whole.append(samples)
        var split = AudioLevelMeter()
        for start in stride(from: 0, to: samples.count, by: 173) { split.append(Array(samples[start..<min(start + 173, samples.count)])) }
        let result = whole.track(includingPartial: true)
        #expect(result == split.track(includingPartial: true))
        #expect(result.sampleCount == samples.count && result.levels.count == 3)
        #expect(abs(try #require(result.levels[0]) + 20) < 0.0001)
        #expect(abs(try #require(result.levels[1]) + 40) < 0.0001)
        #expect(result.levels[2] == -120)
        #expect(whole.track().sampleCount == 3200)
        #expect(result.level(start: 0.201, end: result.duration) == -120)
        #expect(whole.track().level(start: 0.201, end: result.duration) == nil)
    }

    @Test func 短い区間と未到着と欠測は低音量と誤認しない() {
        let t = track([0.1, .nan, 0.001, .infinity])
        #expect(t.level(start: 0, end: 0.01) == nil)
        #expect(t.level(start: 0, end: 0.5) == nil)
        #expect(t.level(start: 0, end: 0.4) == nil)
        #expect(t.level(start: -.infinity, end: 0.1) == nil)
        let values = t.assessments(for: [.init(speaker: nil, start: 0.1, end: 0.2, text: "欠測")])
        #expect(values[0]?.dbFS == nil && values[0]?.isCandidate == false)
    }

    @Test func 息継ぎの無音で行全体を小音量にしない() throws {
        let t = track([0, 0, 0, 0, 0, 0, 0, 0, 0.1, 0.1])
        #expect(abs(try #require(t.level(start: 0, end: 1)) + 20) < 0.0001)
    }

    @Test func 相対基準には手入力と未来の行を混ぜない() throws {
        let t = track(Array(repeating: 0.1, count: 8) + [0.01, 1, 0.001])
        var rows = (0..<11).map { Utterance(speaker: 0, start: Double($0) / 10, end: Double($0 + 1) / 10, text: "声") }
        let before = t.assessments(for: Array(rows.prefix(9)))
        let after = t.assessments(for: rows)
        #expect(Array(after.prefix(9)) == before)
        #expect(before[7]?.referenceDBFS == nil)
        #expect(before[8]?.isCandidate == true) // −40dBFSなので絶対値だけなら候補にならない。
        rows.insert(try .init(typedText: "手入力", at: 0, postedAt: Date()), at: 0)
        let typed = t.assessments(for: rows)
        #expect(typed[0] == nil && Array(typed.dropFirst()) == after)
        #expect(after[10]?.isCandidate == true)
    }

    @Test func 旧会議との互換と不正トラックの拒否() throws {
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 0, utterances: [], names: SpeakerNames())
        let data = try JSONEncoder().encode(meeting)
        #expect(try JSONDecoder().decode(MeetingMarkdown.Meeting.self, from: data).audioLevels == nil)
        for text in ["{\"sampleCount\":-1,\"levels\":[]}", "{\"sampleCount\":1601,\"levels\":[-20]}",
                     "{\"sampleCount\":1600,\"levels\":[-121]}"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AudioLevelTrack.self, from: Data(text.utf8)) }
        }
        let t = track([.nan, 0.1])
        #expect(try JSONDecoder().decode(AudioLevelTrack.self, from: JSONEncoder().encode(t)) == t)
    }

    @Test func 設定は既定無効で真偽値だけを受け付ける() throws {
        #expect(!ResolvedConfig(config: try ConfigLoader.parse(toml: "")).measureAudioLevels)
        #expect(ResolvedConfig(config: try ConfigLoader.parse(toml: "measureAudioLevels = true")).measureAudioLevels)
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "measureAudioLevels = 1") }
    }

    @Test func 計測を保存しても本文とAIの入力を減らさず改名も保存する() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = [TimedToken(text: "小さな声。", phraseId: 0, start: 0, end: 1)]
        let rows = [Utterance(speaker: 0, start: 0, end: 1, text: "小さな声。")]
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 1, utterances: rows, names: SpeakerNames(), audioLevels: track([0.001], samplesPerLevel: 16000))
        let url = try MeetingFiles.reserveMarkdownURL(in: root, startedAt: meeting.startedAt)
        var archive = MeetingArchive(original: meeting, processed: nil, candidateCount: 0, markdownURL: url)
        let result = archive.save()
        #expect(result.succeeded && result.levelsSucceeded && result.utterances == rows)
        let report = try JSONDecoder().decode(AudioLevelReport.self, from: Data(contentsOf: MeetingFiles.levelsURL(for: url)))
        #expect(report.track == meeting.audioLevels && report.utterances == rows)
        let rendered = try String(contentsOf: url, encoding: .utf8)
        #expect(rendered.contains("話者A: 小さな声。") && rendered.contains("小音量候補") && rendered.contains("除外OFF"))
        let capture = try AICapture(tokens: tokens, speakers: [0], finalCount: 1, processedUntil: 1, cutoff: 1, names: meeting.names, timeline: meeting.timeline)
        #expect(capture.lines.count == 1 && capture.voice == "小さな声。")
        #expect(!capture.lines[0].contains("dBFS"))
        archive = try JSONDecoder().decode(MeetingArchive.self, from: JSONEncoder().encode(archive))
        archive.original.names.set("改名", for: 0)
        #expect(archive.save().levelsSucceeded)
        let renamed = try JSONDecoder().decode(AudioLevelReport.self, from: Data(contentsOf: MeetingFiles.levelsURL(for: url)))
        #expect(renamed.names.name(for: 0) == "改名")
    }

    @Test func 計測保存の失敗は本文保存と区別して既存内容を上書きしない() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 0.1, utterances: [], names: SpeakerNames(), audioLevels: track([0.1]))
        let url = try MeetingFiles.reserveMarkdownURL(in: root, startedAt: meeting.startedAt)
        let levels = MeetingFiles.levelsURL(for: url)
        try Data("既存の記録".utf8).write(to: levels)
        var archive = MeetingArchive(original: meeting, processed: nil, candidateCount: 0, markdownURL: url)
        let result = archive.save()
        #expect(result.succeeded && !result.levelsSucceeded && result.message.contains("音量記録の保存に失敗"))
        #expect(try String(contentsOf: levels, encoding: .utf8) == "既存の記録")
        try FileManager.default.removeItem(at: levels)
        #expect(archive.save().levelsSucceeded)
    }

    @Test func 一時間の音量保存の規模を測る() throws {
        var meter = AudioLevelMeter()
        let chunk = Array(repeating: Float(0.01), count: 16000)
        for _ in 0..<3600 { meter.append(chunk) }
        let t = meter.track()
        #expect(t.levels.count == 36000)
        let start = ContinuousClock.now
        let data = try JSONEncoder().encode(t)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        #expect(try JSONDecoder().decode(AudioLevelTrack.self, from: Data(contentsOf: url)) == t)
        print("[audio-level-hour] \(data.count) bytes, encode/write/read/decode \(start.duration(to: .now))")
    }

    @Test func 計測保存直後の中断は同一内容だけを引き継いで復旧する() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 0.1, utterances: [], names: SpeakerNames(), audioLevels: track([0.1]))
        let url = try MeetingFiles.reserveMarkdownURL(in: root, startedAt: meeting.startedAt)
        var archive = MeetingArchive(original: meeting, processed: nil, candidateCount: 0, markdownURL: url)
        let before = try JSONEncoder().encode(archive)
        #expect(archive.save().levelsSucceeded)
        var recovered = try JSONDecoder().decode(MeetingArchive.self, from: before)
        #expect(recovered.save().levelsSucceeded)
        recovered.original.names.set("再開後", for: 0)
        #expect(recovered.save().levelsSucceeded)
    }
}
