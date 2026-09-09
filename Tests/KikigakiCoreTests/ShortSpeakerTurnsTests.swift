import Testing
@testable import KikigakiCore

@Suite struct ShortSpeakerTurnsTests {
    // 2026-09-05_1529.wavの再処理ログ。rawは窓判定の観測値で、正解ラベルではない。
    @Test func 実録のはいとすごいねを多数派へ吸収しない() {
        let tokens: [TimedToken] = [
            .init(text: "一応経過報告させていただきますと", phraseId: 1146, start: 180.12, end: 182.82),
            .init(text: "は", phraseId: 1146, start: 182.82, end: 183.06),
            .init(text: "い", phraseId: 1146, start: 183.06, end: 183.18),
            .init(text: "それから毎日続いてまして", phraseId: 1146, start: 183.18, end: 185.22),
            .init(text: "す", phraseId: 1146, start: 185.22, end: 185.58),
            .init(text: "ご", phraseId: 1146, start: 185.58, end: 185.70),
            .init(text: "い", phraseId: 1146, start: 185.70, end: 185.76),
            .init(text: "ね", phraseId: 1146, start: 185.76, end: 185.88),
            .init(text: "。", phraseId: 1146, start: 185.88, end: 186.06),
        ]
        let raw: [Int?] = [0, 1, 1, 0, 1, 1, 1, 1, 1]
        let speakers = Aligner.smoothSpeakers(tokens: tokens, speakers: raw)
        #expect(speakers == raw)
        #expect(Aligner.utterances(tokens: tokens, speakers: speakers).map(\.text)
                == ["一応経過報告させていただきますと", "はい", "それから毎日続いてまして", "すごいね。"])
    }

    @Test func 複数語を含むASRトークンの境界は補完しない() {
        let texts = ["11日目じ", "ゃあもう10分の1そ", "うなんですよ。"]
        let times = [187.26, 188.76, 190.20, 190.80]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1220, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 0]) == [0, 0, 0])
    }

    @Test(arguments: [
        ["読", "みやすい", "し"],
        ["一応", "経過報告", "をさせていただきます"],
        ["続いてまし", "て", "すごいです"],
    ])
    func 語途中と文中の複数語と一文字は従来通り吸収する(_ texts: [String]) {
        let times = [0.0, 2.0, 2.5, 5.0]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 0]) == [0, 0, 0])
    }

    // 2026-09-06_1727.wav の再処理ログ。発話前の間を含む長い1文字が、どの話者区間にも当たらず不明になっていた
    @Test func 語の途中を切る長い不明の島は多数派へ付ける() {
        let texts = ["欲", "し", "い", "な", "と", "。"]
        let times = [765.90, 767.82, 767.94, 768.06, 768.18, 768.36, 768.72]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1636, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0, 0, 0, 0, 0]) == [0, 0, 0, 0, 0, 0])
        // 「で、」も同じ。句読点は直前の話者に付くので不明のまま島に含まれる
        let lead = [TimedToken(text: "で", phraseId: 817, start: 586.20, end: 588.72), TimedToken(text: "、", phraseId: 817, start: 588.72, end: 588.84),
                    TimedToken(text: "具体的には", phraseId: 817, start: 588.84, end: 589.62)]
        #expect(Aligner.smoothSpeakers(tokens: lead, speakers: [nil, nil, 0]) == [0, 0, 0])
    }

    @Test func 語として完結する長い不明の島は不明のまま残す() {
        let tokens = [TimedToken(text: "はい", phraseId: 1, start: 0, end: 2.0), TimedToken(text: "続いてます", phraseId: 1, start: 2.0, end: 3)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0]) == [nil, 0])
    }

    @Test func 不明話者は語境界でも吸収し凍結済みは変えない() {
        let tokens = [TimedToken(text: "はい", phraseId: 1, start: 0, end: 0.3), TimedToken(text: "続いてます", phraseId: 1, start: 0.3, end: 3)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0]) == [0, 0])
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0], frozenCount: 1) == [nil, 0])
    }

    @Test func 絵文字や句読点を含む前文でもUTF16の境界がずれない() {
        let tokens = [TimedToken(text: "😀続いてまして", phraseId: 1, start: 0, end: 3), TimedToken(text: " すごいね。 ", phraseId: 1, start: 3, end: 3.8)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1]) == [0, 1])
    }

    // 2026-09-06_1416_2.wav の再処理ログ(24.60〜26.82秒)。相槌が重なり、音声側の区間が交互に出る場面。
    // 「代表」(25.62〜25.92)は多数派(1)の区間 25.44〜25.92 に収まるのに、窓判定は 0 に倒れていた
    private static let overlapTokens: [TimedToken] = {
        let texts = ["は", "い", "管", "理", "の", "プ", "ロ", "代", "表", "の", "松", "村", "で", "す", "。"]
        let times = [24.60, 24.78, 24.90, 25.14, 25.32, 25.44, 25.56, 25.62, 25.80, 25.92, 26.10, 26.28, 26.46, 26.64, 26.70, 26.82]
        return texts.enumerated().map { TimedToken(text: $0.element, phraseId: 81, start: times[$0.offset], end: times[$0.offset + 1]) }
    }()
    private static let overlapSegments = [
        SpeakerSegment(speaker: 0, start: 20.32, end: 24.96), SpeakerSegment(speaker: 1, start: 24.96, end: 25.20),
        SpeakerSegment(speaker: 0, start: 25.04, end: 25.44), SpeakerSegment(speaker: 1, start: 25.44, end: 25.92),
        SpeakerSegment(speaker: 0, start: 25.92, end: 26.40), SpeakerSegment(speaker: 1, start: 26.40, end: 26.88),
    ]
    private static let overlapRaw: [Int?] = [0, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1]

    @Test func 実録の多数派に覆われた文中の1語は吸収する() {
        let speakers = Aligner.smoothSpeakers(tokens: Self.overlapTokens, speakers: Self.overlapRaw, segments: Self.overlapSegments)
        #expect(speakers == Array(repeating: 1, count: Self.overlapTokens.count))
        #expect(Aligner.utterances(tokens: Self.overlapTokens, speakers: speakers).map(\.text) == ["はい管理のプロ代表の松村です。"])
    }

    @Test func 音声区間がなくても前後が多数派の代表は吸収する() {
        #expect(Aligner.smoothSpeakers(tokens: Self.overlapTokens, speakers: Self.overlapRaw)[7...8] == [1, 1])
    }

    /// 主話者(1)が喋り続ける最中に、相手(0)の1語が文字として出た形。主話者の区間が島を覆う
    private static func coveredIsland(_ word: String) -> (tokens: [TimedToken], raw: [Int?], segments: [SpeakerSegment]) {
        let texts = ["今日", "は", "、", word, "資料", "を", "説明", "し", "ます", "。"]
        let tokens = texts.enumerated().map {
            TimedToken(text: $0.element, phraseId: 1, start: Double($0.offset) * 0.2, end: Double($0.offset + 1) * 0.2)
        }
        let raw: [Int?] = [1, 1, 1, 0, 1, 1, 1, 1, 1, 1]
        let segments = [SpeakerSegment(speaker: 1, start: 0, end: 2.2), SpeakerSegment(speaker: 0, start: 0.5, end: 0.9)]
        return (tokens, raw, segments)
    }

    @Test(arguments: ["はい", "うん", "なるほど", "確かに", "そうですね"])
    func 多数派に覆われていても相槌の語彙は残す(_ word: String) {
        let island = Self.coveredIsland(word)
        let speakers = Aligner.smoothSpeakers(tokens: island.tokens, speakers: island.raw, segments: island.segments)
        #expect(speakers == island.raw, "\(word) が吸収された")
    }

    @Test(arguments: ["代表", "反対"])
    func 多数派に覆われた語彙にない1語は吸収する(_ word: String) {
        let island = Self.coveredIsland(word)
        let speakers = Aligner.smoothSpeakers(tokens: island.tokens, speakers: island.raw, segments: island.segments)
        #expect(speakers == Array(repeating: 1, count: island.tokens.count), "\(word) が残った")
        // 音声区間がなくても、同じフレーズの前後が多数派なら一般語は戻す
        #expect(Aligner.smoothSpeakers(tokens: island.tokens, speakers: island.raw)[3] == 1)
    }

    @Test func 多数派の声が途切れても相槌は残し文中の一般語は吸収する() {
        // 2026-09-05_1529.wav の「はい」と同じ形。多数派(0)の区間が島の前で切れ、後で再開する
        let tokens: [TimedToken] = [
            .init(text: "一応経過報告させていただきますと", phraseId: 1146, start: 180.12, end: 182.82),
            .init(text: "は", phraseId: 1146, start: 182.82, end: 183.06),
            .init(text: "い", phraseId: 1146, start: 183.06, end: 183.18),
            .init(text: "それから毎日続いてまして", phraseId: 1146, start: 183.18, end: 185.22),
        ]
        let segments = [
            SpeakerSegment(speaker: 0, start: 180.48, end: 182.88), SpeakerSegment(speaker: 1, start: 182.72, end: 183.28),
            SpeakerSegment(speaker: 0, start: 183.36, end: 185.36),
        ]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 1, 0], segments: segments) == [0, 1, 1, 0])
        // プリセット外の1語は、前後の主話者の連続性を優先する
        let noun = tokens.enumerated().map { i, t in i == 1 ? TimedToken(text: "代", phraseId: 1146, start: t.start, end: t.end)
            : i == 2 ? TimedToken(text: "表", phraseId: 1146, start: t.start, end: t.end) : t }
        #expect(Aligner.smoothSpeakers(tokens: noun, speakers: [0, 1, 1, 0], segments: segments) == [0, 0, 0, 0])
    }
}
