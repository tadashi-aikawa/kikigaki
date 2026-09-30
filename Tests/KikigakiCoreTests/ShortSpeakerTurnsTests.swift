import Testing
@testable import KikigakiCore

/// フレーズの多数派へ短い別話者の塊を吸収する補正は廃止した。短い返答は区間が示す話者のまま残る。
/// 吸収で直っていた実録の事例は、元の期待を `withKnownIssue` の中に残し、既知の退行として示す。
/// 期待を変更後の出力で上書きしない。経緯: docs/records/speaker-correction-trial.md
@Suite struct ShortSpeakerTurnsTests {
    // 2026-09-05_1529.wavの再処理ログ。rawは窓判定の観測値で、正解ラベルではない。
    @Test func 実録のはいとすごいねを多数派へ吸収しない() {
        let tokens = RecordedSpeakerFixtures.haiSugoine.tokens
        let raw: [Int?] = [0, 1, 1, 0, 1, 1, 1, 1, 1]
        #expect(RecordedSpeakerFixtures.haiSugoine.raw == raw)
        let speakers = Aligner.smoothSpeakers(tokens: tokens, speakers: raw)
        #expect(speakers == raw)
        #expect(Aligner.utterances(tokens: tokens, speakers: speakers).map(\.text)
                == ["一応経過報告させていただきますと", "はい", "それから毎日続いてまして", "すごいね。"])
    }

    /// 主話者(1)が喋り続ける最中に、相手(0)の1語が文字として出た形。主話者の区間が島を覆う
    @Test(arguments: ["はい", "うん", "なるほど", "確かに", "そうですね"])
    func 多数派に覆われていても短い返答は残す(_ word: String) {
        let texts = ["今日", "は", "、", word, "資料", "を", "説明", "し", "ます", "。"]
        let tokens = texts.enumerated().map {
            TimedToken(text: $0.element, phraseId: 1, start: Double($0.offset) * 0.2, end: Double($0.offset + 1) * 0.2)
        }
        let raw: [Int?] = [1, 1, 1, 0, 1, 1, 1, 1, 1, 1]
        let segments = [SpeakerSegment(speaker: 1, start: 0, end: 2.2), SpeakerSegment(speaker: 0, start: 0.5, end: 0.9)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: raw, segments: segments) == raw, "\(word) が吸収された")
    }

    @Test func 語として完結する長い不明の島は不明のまま残す() {
        let tokens = [TimedToken(text: "はい", phraseId: 1, start: 0, end: 2.0), TimedToken(text: "続いてます", phraseId: 1, start: 2.0, end: 3)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0]) == [nil, 0])
    }

    // 2026-09-06_1727.wav の再処理ログ。発話前の間を含む長い1文字が、どの話者区間にも当たらず不明になっていた
    @Test func 既知の退行_語の途中を切る長い不明の島が不明の行に残る() {
        let texts = ["欲", "し", "い", "な", "と", "。"]
        let times = [765.90, 767.82, 767.94, 768.06, 768.18, 768.36, 768.72]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1636, start: times[$0.offset], end: times[$0.offset + 1]) }
        // 長い語頭の付け替えは既知の話者だけが対象。不明を新しく補わない
        withKnownIssue("吸収の廃止で「欲 / しいなと」が不明の行に割れる") {
            #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0, 0, 0, 0, 0]) == [0, 0, 0, 0, 0, 0])
        }
        let lead = [TimedToken(text: "で", phraseId: 817, start: 586.20, end: 588.72), TimedToken(text: "、", phraseId: 817, start: 588.72, end: 588.84),
                    TimedToken(text: "具体的には", phraseId: 817, start: 588.84, end: 589.62)]
        withKnownIssue("吸収の廃止で「で、」が不明の行に残る") {
            #expect(Aligner.smoothSpeakers(tokens: lead, speakers: [nil, nil, 0]) == [0, 0, 0])
        }
    }

    // 2026-09-06_1416_2.wav の再処理ログ(24.60〜26.82秒)。相槌が重なり、音声側の区間が交互に出る場面。
    // 「代表」(25.62〜25.92)は多数派(1)の区間 25.44〜25.92 に収まるのに、窓判定は 0 に倒れていた
    @Test func 既知の退行_実録の多数派に覆われた文中の1語が別話者に残る() {
        let fixture = RecordedSpeakerFixtures.daihyou
        let speakers = Aligner.smoothSpeakers(tokens: fixture.tokens, speakers: fixture.raw, segments: fixture.segments)
        withKnownIssue("吸収の廃止で「代表」が相手の話者に残る") {
            #expect(speakers == fixture.expected)
            #expect(Aligner.utterances(tokens: fixture.tokens, speakers: speakers).map(\.text) == ["はい管理のプロ代表の松村です。"])
        }
    }
}
