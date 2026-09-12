import Foundation
import Testing
@testable import KikigakiCore

@Suite struct UndiarizedTranscriptTests {
    private let tokens: [TimedToken] = [
        .init(text: "読", phraseId: 1, start: 0, end: 0.4),
        .init(text: "みます。", phraseId: 2, start: 0.4, end: 1),
        .init(text: "次です", phraseId: 2, start: 1.1, end: 2),
        .init(text: "区切ります", phraseId: 3, start: 3, end: 4),
        .init(text: "暫定", phraseId: 4, start: 4.1, end: 5)
    ]
    private var names: SpeakerNames {
        var value = SpeakerNames(); value.diarizationEnabled = false; return value
    }

    @Test func 確定は話者待ちせず語中の結果境界を結合し文末と無音で区切る() {
        let live = LiveTranscript(tokens: tokens, speakers: [], finalCount: 4, diarizationEnabled: false)
        #expect(live.utterances.map(\.text) == ["読みます。", "次です", "区切ります"])
        #expect(live.pendingSpeakerRows.isEmpty)
        #expect(live.tentativeText == "暫定")
        #expect(live.utterances.allSatisfy { $0.speaker == nil && $0.kind == .voice })
        let replaced = Array(tokens.prefix(4)) + [TimedToken(text: "訂正済み", phraseId: 5, start: 4.1, end: 5)]
        let next = LiveTranscript(tokens: replaced, speakers: [], finalCount: 5, diarizationEnabled: false)
        #expect(next.utterances.map(\.text) == ["読みます。", "次です", "区切ります訂正済み"])
        #expect(next.tentativeText == nil)
    }

    @Test func 長い独話を確定結果境界で区切り後続結果で閉じた行を動かさない() {
        let voice = [TimedToken(text: "前半", phraseId: 1, start: 0, end: 20),
                     TimedToken(text: "続き", phraseId: 2, start: 20, end: 31),
                     TimedToken(text: "後半", phraseId: 3, start: 31, end: 40)]
        let first = UndiarizedTranscript.utterances(tokens: voice)
        #expect(first.map(\.text) == ["前半続き", "後半"])
        let next = UndiarizedTranscript.utterances(tokens: voice + [.init(text: "末尾", phraseId: 4, start: 40, end: 45)])
        #expect(next.first == first.first)
        #expect(next.last?.text == "後半末尾")
        #expect(UndiarizedTranscript.utterances(tokens: []).isEmpty)
    }

    @Test func 画面と停止後とAIの会話が同じ行になり相槌省略を走らせない() throws {
        let fixed = Array(tokens.prefix(4))
        let live = LiveTranscript(tokens: fixed, speakers: [], finalCount: fixed.count, diarizationEnabled: false)
        let final = MeetingResult.withoutDiarization(tokens: fixed)
        #expect(live.utterances == final.utterances)
        #expect(final.processed == nil && final.candidates.isEmpty)
        let timeline = MeetingTimeline(startedAt: Date(timeIntervalSince1970: 0))
        let capture = try AICapture(tokens: tokens, speakers: Array(repeating: nil, count: tokens.count),
            finalCount: fixed.count, processedUntil: 5, cutoff: 4, names: names, timeline: timeline)
        #expect(capture.lines == TranscriptRenderer.lines(live.utterances, names: names, timeline: timeline))
        #expect(!capture.needsConfirmation)
        #expect(capture.lines.allSatisfy { $0.contains("発言: ") })
        #expect(capture.voice == "区切ります")
    }

    @Test func 過去の不明話者は不明のまま新しい無効会議は再保存後も発言になる() throws {
        let old = try JSONDecoder().decode(SpeakerNames.self, from: Data(#"{"names":{"0":"田中"}}"#.utf8))
        #expect(old.diarizationEnabled && old.name(for: nil) == "?" && old.name(for: 0) == "田中")
        let restored = try JSONDecoder().decode(SpeakerNames.self, from: JSONEncoder().encode(names))
        #expect(!restored.diarizationEnabled && restored.name(for: nil) == "発言")
        let typed = try Utterance(typedText: "URL", at: 0, postedAt: Date())
        #expect(restored.displayName(for: typed) == "手入力")
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 4,
            utterances: MeetingResult.withoutDiarization(tokens: Array(tokens.prefix(4))).utterances,
            names: restored)
        let archive = MeetingArchive(original: meeting, processed: nil, candidateCount: 0,
            markdownURL: URL(fileURLWithPath: "/tmp/unused.md"))
        let decoded = try JSONDecoder().decode(MeetingArchive.self, from: JSONEncoder().encode(archive))
        let markdown = MeetingMarkdown.render(decoded.original)
        #expect(markdown.contains("発言: 読みます。"))
        #expect(!markdown.contains("話者A") && !markdown.contains("?: "))
    }
}
