import Foundation
import Testing
@testable import KikigakiCore

@Suite struct TypedEntriesTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let start = Date(timeIntervalSince1970: 0)
    private var timeline: MeetingTimeline { .init(startedAt: start) }
    private func typed(_ text: String = "https://example.com/meeting", at: Double = 60, posted: Double = 120) throws -> Utterance {
        try Utterance(typedText: text, at: at, postedAt: start.addingTimeInterval(posted))
    }
    private func voice(_ text: String, at: Double, speaker: Int? = 0) -> Utterance {
        Utterance(speaker: speaker, start: at, end: at + 1, text: text)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typed-entries-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func 旧JSONは声として読み新旧の日時を往復する() throws {
        let old = Data(#"{"speaker":0,"start":1,"end":2,"text":"声"}"#.utf8)
        let unknown = Data(#"{"start":1,"end":2,"text":"不明"}"#.utf8)
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let oldVoice = try decoder.decode(Utterance.self, from: old)
        #expect(oldVoice.kind == .voice && oldVoice.postedAt == nil)
        #expect(try decoder.decode(Utterance.self, from: unknown).speaker == nil)
        for entry in [oldVoice, try typed(posted: 120.125)] {
            #expect(try decoder.decode(Utterance.self, from: encoder.encode(entry)) == entry)
            #expect(try AIJSON.decode(Utterance.self, from: AIJSON.encode(entry)) == entry)
        }
        let legacyArchive = Data(#"{"original":{"startedAt":0,"duration":2,"utterances":[{"start":1,"end":2,"text":"旧会議"}],"names":{"names":{}},"pauses":[]},"markdownURL":"file:///tmp/legacy-meeting.md","candidateCount":0,"ownsRawFile":false,"omissionDisabledAfterFailure":false}"#.utf8)
        let archive = try decoder.decode(MeetingArchive.self, from: legacyArchive)
        #expect(archive.original.utterances.first?.kind == .voice)
    }

    @Test(arguments: [
        #"{"kind":"future","start":0,"end":0,"text":"本文"}"#,
        #"{"kind":null,"start":0,"end":0,"text":"本文"}"#,
        #"{"kind":"typed","start":0,"end":0,"text":"本文"}"#,
        #"{"kind":"typed","postedAt":null,"start":0,"end":0,"text":"本文"}"#,
        #"{"kind":"typed","postedAt":0,"speaker":0,"start":0,"end":0,"text":"本文"}"#,
        #"{"kind":"typed","postedAt":0,"start":0,"end":1,"text":"本文"}"#,
        #"{"kind":"typed","postedAt":0,"start":-1,"end":-1,"text":"本文"}"#,
        #"{"kind":"voice","postedAt":0,"start":0,"end":1,"text":"本文"}"#
    ]) func 不正な由来や投稿日時を拒否する(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Utterance.self, from: Data(json.utf8)) }
    }

    @Test func 入力を一行にして不正な投稿を保存しない() throws {
        let entry = try typed("  https://example.com/a?q=1:2\r\n補足\u{2028}続き  ")
        #expect(entry.text == "https://example.com/a?q=1:2 補足 続き")
        #expect(entry.kind == .typed && entry.speaker == nil && entry.start == entry.end)
        for text in [" \n\r\t", "本文\0"] {
            #expect(throws: Utterance.ValidationError.invalidTypedEntry) { try typed(text) }
        }
        #expect(throws: Utterance.ValidationError.invalidTypedEntry) { try typed(at: .infinity) }
        #expect(throws: Utterance.ValidationError.invalidTypedEntry) { try typed(posted: .infinity) }
        var corrupted = entry
        corrupted.speaker = 0
        #expect(throws: (any Error).self) { try JSONEncoder().encode(corrupted) }
    }

    @Test func 表示名と時計を共有し再開しても投稿時刻を変えない() throws {
        let entry = try typed()
        let resumed = MeetingTimeline(startedAt: start, pauses: [.init(audioTime: 60, duration: 240)])
        let names = SpeakerNames([0: "手入力"])
        #expect(names.displayName(for: entry) == "手入力")
        #expect(names.displayName(for: voice("不明", at: 0, speaker: nil)) == "?")
        let expected = "[00:02:00] 手入力: https://example.com/meeting"
        for clock in [timeline, resumed] {
            #expect(TranscriptRenderer.line(entry, names: names, timeline: clock, timeZone: utc) == expected)
            #expect(TranscriptRenderer.clock(for: entry, timeline: clock, timeZone: utc) == "00:02:00")
        }
        #expect(TranscriptRenderer.clock(for: voice("再開", at: 60), timeline: resumed, seconds: true, timeZone: utc) == "00:05:00")
        #expect(TranscriptRenderer.clock(for: entry, timeline: resumed, seconds: true, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!) == "09:02:00")
    }

    @Test func 音声位置を優先し同値は実時刻で併合して未確定添字を移す() throws {
        let resumed = MeetingTimeline(startedAt: start, pauses: [.init(audioTime: 60, duration: 240)])
        let voices = [voice("末尾", at: 70), voice("再開", at: 60), voice("前", at: 0)]
        let entries = [try typed("停止中1", posted: 120), try typed("停止中2", posted: 180),
                       try typed("時計も同じ", posted: 300), try typed("音声位置が後", at: 65, posted: 1)]
        let result = TranscriptEntries.merge(voice: voices, typed: entries, timeline: resumed, pendingVoiceRows: [0, 1])
        #expect(result.utterances.map(\.text) == ["前", "停止中1", "停止中2", "再開", "時計も同じ", "音声位置が後", "末尾"])
        #expect(result.pendingSpeakerRows == [3, 6])
        let duplicate = try typed("同文", posted: 120)
        #expect(TranscriptEntries.merge(voice: [], typed: [duplicate, duplicate], timeline: timeline).utterances.count == 2)
        let backwards = [try typed("先の投稿", posted: 200), try typed("後の投稿", posted: 100)]
        #expect(TranscriptEntries.merge(voice: [], typed: backwards, timeline: timeline).utterances == backwards)
    }

    @Test func 改名と再分割とarchive復元でも両保存先に手入力を一度だけ残す() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meeting.md")
        let entry = try typed(at: 2, posted: 2)
        let rawVoice = [voice("はいはい本文", at: 0), voice("続き", at: 3)]
        let processedVoice = [voice("本文", at: 0), voice("続き", at: 3)]
        let merged = TranscriptEntries.merge(voice: rawVoice, typed: [entry], timeline: timeline).utterances
        let processed = TranscriptEntries.merge(voice: processedVoice, typed: [entry], timeline: timeline).utterances
        let meeting = MeetingMarkdown.Meeting(startedAt: start, duration: 4, utterances: merged, names: SpeakerNames())
        var archive = MeetingArchive(original: meeting, processed: processed, candidateCount: 1, markdownURL: url)
        #expect(archive.save().utterances == processed)
        archive = try AIJSON.decode(MeetingArchive.self, from: AIJSON.encode(archive))
        archive.original.names.set("佐藤", for: 0)
        let split = [voice("はいはい", at: 0, speaker: 1), voice("本文", at: 1), voice("続き", at: 3)]
        let result = MeetingResult(speakers: [1, 0, 0], utterances: split, processed: split, candidates: [])
        // 複数回の統合訂正でも前回の併合済み結果へ足さない。
        archive.replaceResult(result)
        archive.replaceResult(result)
        #expect(archive.save().utterances.map(\.text) == ["はいはい", "本文", entry.text, "続き"])
        for file in [url, MeetingFiles.rawURL(for: url)] {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.components(separatedBy: "手入力: ").count == 2)
            #expect(text.contains("佐藤: 本文") && text.contains("手入力: " + entry.text))
            #expect(text.range(of: "佐藤: 本文")!.lowerBound < text.range(of: "手入力: ")!.lowerBound)
            #expect(text.range(of: "手入力: ")!.lowerBound < text.range(of: "佐藤: 続き")!.lowerBound)
        }
    }

    @Test func 混在した配列も由来で振り分けて全行と声の未確定位置を保つ() throws {
        let first = try typed("混ざった投稿", at: 1, posted: 1)
        let second = try typed("次の投稿", at: 1, posted: 2)
        let result = TranscriptEntries.merge(voice: [first, voice("声", at: 0)],
            typed: [second, voice("後の声", at: 3)], timeline: timeline, pendingVoiceRows: [0, 1])
        #expect(result.utterances.map(\.text) == ["声", first.text, second.text, "後の声"])
        #expect(result.pendingSpeakerRows == [0])
    }

    @Test func raw保存失敗と省略なしでも手入力を保つ() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let entry = try typed(at: 2)
        for omit in [true, false] {
            let url = dir.appendingPathComponent("\(omit).md")
            let raw = MeetingFiles.rawURL(for: url)
            if omit { try "別の会議".write(to: raw, atomically: true, encoding: .utf8) }
            let meeting = MeetingMarkdown.Meeting(startedAt: start, duration: 3, utterances: [entry], names: SpeakerNames())
            var archive = MeetingArchive(original: meeting, processed: omit ? [entry] : nil, candidateCount: 0, markdownURL: url)
            archive.replaceResult(.init(speakers: [], utterances: [], processed: omit ? [] : nil, candidates: []))
            #expect(archive.save().utterances == [entry])
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("手入力: ") && !text.contains("- 話者:"))
            if omit { #expect(try String(contentsOf: raw, encoding: .utf8) == "別の会議") }
            else { #expect(!FileManager.default.fileExists(atPath: raw.path)) }
        }
    }

    @Test func AI文脈へ境界の投稿を含めても声の問いと確定待ちは変わらない() throws {
        let tokens = [TimedToken(text: "声の問い", phraseId: 0, start: 0, end: 1),
                      TimedToken(text: "暫定", phraseId: 1, start: 1, end: 2)]
        let entries = [try typed("境界のURL", at: 2, posted: 120), try typed("送信後", at: 3, posted: 121)]
        let capture = try AICapture(tokens: tokens, speakers: [0, 1], finalCount: 1, processedUntil: 2,
            cutoff: 2, names: SpeakerNames(), timeline: timeline, typed: entries)
        #expect(capture.lines.count == 2)
        #expect(capture.lines.last?.contains("手入力: 境界のURL") == true)
        #expect(!capture.lines.joined().contains("送信後"))
        #expect(capture.voice == "声の問い暫定" && capture.voiceUtteranceStart == 0)
        #expect(capture.tail?.text == "暫定" && capture.needsConfirmation)
        let noVoice = try AICapture(tokens: [], speakers: [], finalCount: 0, processedUntil: 2,
            cutoff: 2, names: SpeakerNames(), timeline: timeline, typed: entries)
        #expect(noVoice.lines.count == 1 && noVoice.voice.isEmpty && noVoice.voiceUtteranceStart == nil)
        #expect(!noVoice.needsConfirmation && noVoice.tail == nil)
    }

    @Test func コピー後の音声訂正でも投稿を残し固定ファイルは変えない() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let entry = try typed(at: 2, posted: 2)
        var history = HandoffHistory(startedAt: start)
        let firstCopy = try history.copy(utterances: [voice("URL送ります", at: 0), entry], names: SpeakerNames(),
            outputDirectory: dir, timeline: timeline, writeClipboard: { _ in true })
        let first = try #require(firstCopy)
        let original = try Data(contentsOf: first.fileURL)
        let merged = TranscriptEntries.merge(voice: [voice("URL送ります", at: 0), voice("遅れて確定", at: 1)], typed: [entry], timeline: timeline).utterances
        let secondCopy = try history.copy(utterances: merged, names: SpeakerNames(), outputDirectory: dir,
            timeline: timeline, writeClipboard: { _ in true })
        let second = try #require(secondCopy)
        #expect(second.preview.startLine == 2 && second.preview.includesCorrections)
        #expect(try String(contentsOf: second.fileURL, encoding: .utf8).contains("手入力: " + entry.text))
        #expect(try Data(contentsOf: first.fileURL) == original)
        #expect(try history.recopy(writeClipboard: { _ in true }) == second)
    }
}
