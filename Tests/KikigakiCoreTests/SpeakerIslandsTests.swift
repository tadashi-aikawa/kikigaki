import Testing

@testable import KikigakiCore

/// 島の補正の段階。採用前の比較用で、既定は `off`。設計: docs/speaker-overlap-islands.md
@Suite struct SpeakerIslandsTests {
    // MARK: - 実録

    /// 9/26 等倍の記録 `2026-09-26_1146` の 65〜79秒。0=司会, 1=堀田, 2=イチロー。
    /// 本文が全てイチローの発話というのはタダシの指摘と区間からの推測で、原音で全文を確かめたものではない
    static let recordedTokens: [TimedToken] = [
        ("ま", 65.16, 65.52), ("あ", 65.52, 65.64), ("い", 65.64, 65.76), ("い", 65.76, 65.88), ("も", 65.88, 66),
        ("の", 66, 66.06), ("に", 66.06, 66.18), ("な", 66.18, 66.3), ("っ", 66.3, 66.42), ("て", 66.42, 66.48),
        ("い", 66.48, 66.6), ("る", 66.6, 66.66), ("そ", 66.66, 67.26), ("う", 67.26, 67.32), ("い", 67.32, 67.38),
        ("う", 67.38, 67.44), ("も", 67.44, 67.56), ("ん", 67.56, 67.68), ("だ", 67.68, 67.74), ("と", 67.74, 67.86),
        ("思", 67.86, 68.04), ("う", 68.04, 68.1), ("ん", 68.1, 68.22), ("で", 68.22, 68.28), ("す", 68.28, 68.34),
        ("よ", 68.34, 68.4), ("。", 68.4, 68.58), ("だ", 68.58, 69.66), ("か", 69.66, 69.72), ("ら", 69.72, 69.84),
        ("感", 69.84, 69.96), ("触", 69.96, 70.14), ("と", 70.14, 70.26), ("ま", 70.26, 70.44), ("評", 70.44, 70.62),
        ("価", 70.62, 70.74), ("は", 70.74, 70.86), ("違", 70.86, 70.92), ("う", 70.92, 71.04), ("。", 71.04, 71.16),
        ("ま", 71.16, 71.22), ("さ", 71.22, 71.4), ("っ", 71.4, 71.46), ("き", 71.46, 71.52), ("の", 71.52, 71.58),
        ("話", 71.58, 71.76), ("で", 71.76, 71.94), ("少", 71.94, 72.18), ("し", 72.18, 72.3), ("か", 72.3, 72.48),
        ("ぶ", 72.48, 72.54), ("り", 72.54, 72.66), ("ま", 72.66, 72.72), ("す", 72.72, 72.78), ("け", 72.78, 72.9),
        ("ど", 72.9, 73.02), ("、", 73.02, 73.14), ("そ", 73.14, 74.16), ("う", 74.16, 74.22), ("い", 74.22, 74.28),
        ("う", 74.28, 74.34), ("も", 74.34, 74.46), ("ん", 74.46, 74.52), ("だ", 74.52, 74.64), ("と", 74.64, 74.76),
        ("思", 74.76, 74.94), ("う", 74.94, 75.06), ("ん", 75.06, 75.12), ("で", 75.12, 75.18), ("す", 75.18, 75.24),
        ("よ", 75.24, 75.36), ("ね", 75.36, 75.42), ("。", 75.42, 75.54), ("で", 75.54, 76.14), ("、", 76.14, 76.32),
        ("あ", 76.32, 76.38), ("と", 76.38, 76.5), ("僕", 76.5, 76.74), ("自", 76.74, 77.22), ("己", 77.22, 77.4),
        ("肯", 77.4, 77.64), ("定", 77.64, 77.82), ("感", 77.82, 78.06), ("っ", 78.06, 78.3), ("て", 78.3, 78.36),
        ("い", 78.36, 78.48), ("う", 78.48, 78.54), ("言", 78.54, 78.78), ("葉", 78.78, 78.96),
    ].map { TimedToken(text: $0.0, phraseId: 435, start: $0.1, end: $0.2) }

    static let recordedSegments: [SpeakerSegment] = [
        (2, 58.03, 64.83), (1, 64.8, 65.07), (2, 65.51, 66.72), (1, 66.4, 67.1), (2, 67.04, 68.67), (1, 68.44, 69.82),
        (2, 69.44, 73.16), (1, 71.13, 72.59), (1, 72.78, 73.16), (2, 73.86, 75.52), (1, 74.98, 75.94), (2, 76.01, 79.28),
        (1, 79.11, 79.41),
    ].map { SpeakerSegment(speaker: $0.0, start: $0.1, end: $0.2) }

    /// 堀田(1)に付いた行の本文
    static func otherLines(_ islands: SpeakerIslands) -> [String] {
        let speakers = Aligner.speakers(for: recordedTokens, segments: recordedSegments, islands: islands)
        return Aligner.utterances(tokens: recordedTokens, speakers: speakers).filter { $0.speaker == 1 }.map(\.text)
    }

    @Test func 実録の被りの断片が段階ごとに減る() {
        #expect(Self.otherLines(.off) == ["る", "だ", "話で少", "よね。で、"])
        #expect(Self.otherLines(.cut) == ["だ", "よね。で、"])
        #expect(Self.otherLines(.phrase) == ["だ", "よね。で、"])
        #expect(Self.otherLines(.cross) == [])
    }

    @Test func 補正は話者だけを変え本文と時刻を変えない() {
        for islands in SpeakerIslands.allCases {
            let speakers = Aligner.speakers(for: Self.recordedTokens, segments: Self.recordedSegments, islands: islands)
            #expect(SpeakerTrial.preservesText(tokens: Self.recordedTokens, speakers: speakers))
            let utterances = Aligner.utterances(tokens: Self.recordedTokens, speakers: speakers)
            #expect(utterances.first?.start == Self.recordedTokens.first?.start)
            #expect(utterances.last?.end == Self.recordedTokens.last?.end)
        }
    }

    @Test(arguments: SpeakerIslands.allCases)
    func 実録を順に凍結しても停止時の一括判定と一致する(islands: SpeakerIslands) {
        let result = Self.staged(tokens: Self.recordedTokens, segments: Self.recordedSegments, islands: islands)
        #expect(result.frozen == Array(result.final.prefix(result.frozen.count)))
        // `cross` は最後のフレーズが後続を待つので、凍結はその手前まで
        #expect(result.frozen.count > Self.recordedTokens.count / 3)
    }

    // MARK: - 保護と既知の制約

    /// 1 と 2 の区間、トークンを組み立てる。トークンは同じフレーズ id で、間は0
    static func tokens(_ values: [(String, Double, Double)]) -> [TimedToken] {
        values.map { TimedToken(text: $0.0, phraseId: 1, start: $0.1, end: $0.2) }
    }

    static func segments(_ values: [(Int, Double, Double)]) -> [SpeakerSegment] {
        values.map { SpeakerSegment(speaker: $0.0, start: $0.1, end: $0.2) }
    }

    static func assigned(_ tokens: [TimedToken], _ segments: [SpeakerSegment], _ islands: SpeakerIslands) -> [Int?] {
        Aligner.speakers(for: tokens, segments: segments, islands: islands)
    }

    @Test func 話し手が黙っている間の返答は戻さない() {
        // 0が話し、黙った間に1が「はい、」、0が再開する。0の声は「はい、」に重ならない
        let tokens = Self.tokens([("それで、", 0, 1.2), ("はい、", 1.2, 2.0), ("次に", 2.0, 3.0)])
        let segments = Self.segments([(0, 0, 1.2), (1, 1.2, 2.0), (0, 2.0, 3.0)])
        for islands in SpeakerIslands.allCases {
            #expect(Self.assigned(tokens, segments, islands) == [0, 1, 0], "\(islands)")
        }
    }

    @Test func 既知の制約_話し手の声に重なった実際の返答も戻す() {
        // 1が実際に「はい、」と言い、0も話し続けていた。区間だけでは被りの相槌と区別できない
        let tokens = Self.tokens([("それで、", 0, 1.2), ("はい、", 1.2, 2.0), ("次に", 2.0, 3.0)])
        let segments = Self.segments([(0, 0, 1.25), (1, 1.1, 2.1), (0, 1.9, 3.0)])
        #expect(Self.assigned(tokens, segments, .off) == [0, 1, 0])
        // 語を切らない島なので `cut` は戻さない
        #expect(Self.assigned(tokens, segments, .cut) == [0, 1, 0])
        for islands in [SpeakerIslands.phrase, .cross] {
            withKnownIssue("\(islands.rawValue) は話し手の声に重なった返答を話し手へ戻す") {
                #expect(Self.assigned(tokens, segments, islands) == [0, 1, 0])
            }
        }
    }

    @Test func 長い島と不明と第三話者は戻さない() {
        let long = Self.tokens([("それで、", 0, 1.0), ("はい、", 1.0, 2.6), ("次に", 2.6, 3.6)])
        let longSegments = Self.segments([(0, 0, 1.05), (0, 1.7, 1.9), (0, 2.55, 3.6), (1, 0.9, 2.7)])
        #expect(Self.assigned(long, longSegments, .cross) == Self.assigned(long, longSegments, .off))
        #expect(Self.assigned(long, longSegments, .off)[1] == 1)

        let tokens = Self.tokens([("それで、", 0, 1.2), ("はい、", 1.2, 2.0), ("次に", 2.0, 3.0)])
        // 島の区間が無く不明
        let unknown = Self.segments([(0, 0, 1.0), (0, 2.2, 3.0)])
        #expect(Self.assigned(tokens, unknown, .off)[1] == nil)
        #expect(Self.assigned(tokens, unknown, .cross)[1] == nil)
        // 両隣の話者が違う
        let third = Self.segments([(0, 0, 1.25), (1, 1.1, 2.1), (2, 1.9, 3.0), (0, 1.15, 1.3)])
        #expect(Self.assigned(tokens, third, .off) == [0, 1, 2])
        #expect(Self.assigned(tokens, third, .cross) == [0, 1, 2])
    }

    @Test func crossは間のある境界を越えない() {
        // 文末で区切られた2フレーズ。島「はい。」の後に0.4秒の間
        let paused = Self.tokens([("それで。", 0, 1.2), ("はい。", 1.2, 2.0), ("次に", 2.4, 3.4)])
        let segments = Self.segments([(0, 0, 1.25), (1, 1.1, 2.1), (0, 1.9, 3.4)])
        #expect(Self.assigned(paused, segments, .cross)[1] == 1)
        // 間が無ければ越える
        let joined = Self.tokens([("それで。", 0, 1.2), ("はい。", 1.2, 2.0), ("次に", 2.0, 3.0)])
        let joinedSegments = Self.segments([(0, 0, 1.25), (1, 1.1, 2.1), (0, 1.9, 3.0)])
        #expect(Self.assigned(joined, joinedSegments, .phrase)[1] == 1)
        #expect(Self.assigned(joined, joinedSegments, .cross)[1] == 0)
    }

    // MARK: - 凍結

    /// 1トークンずつ届き、届いた分は高精度側で確定済みとして、録音中の判定とフレーズ固定を順に当てる
    static func staged(tokens: [TimedToken], segments: [SpeakerSegment], islands: SpeakerIslands)
        -> (frozen: [Int?], final: [Int?], counts: [Int]) {
        var frozen: [Int?] = []
        var counts: [Int] = []
        for n in 1...tokens.count {
            let visible = Array(tokens.prefix(n))
            let judged = visible.last!.end + 0.6
            let clipped = segments.compactMap { segment in
                segment.start < judged ? SpeakerSegment(speaker: segment.speaker, start: segment.start, end: min(segment.end, judged)) : nil
            }
            let speakers = Aligner.speakers(for: visible, segments: clipped, frozen: frozen, islands: islands)
            frozen = SpeakerFreeze.advanceByPhrase(frozen: frozen, speakers: speakers, tokens: visible,
                                                   accurateFinalCount: n, judgedUntil: judged, islands: islands)
            counts.append(frozen.count)
        }
        return (frozen, Aligner.speakers(for: tokens, segments: segments, islands: islands), counts)
    }

    @Test func 島を交互に戻しても凍結済みの補正後ラベルを隣の根拠にしない() {
        // 0 1 0 1 0 0 0 の交互。1文ずつのフレーズで、真ん中の0も1の声が重なる短い島
        let tokens = Self.tokens([("東京。", 0, 1), ("大阪。", 1, 2), ("京都。", 2, 3), ("奈良。", 3, 4),
                                  ("神戸。", 4, 5), ("横浜。", 5, 6), ("札幌。", 6, 7)])
        let segments = Self.segments([(0, 0, 1.15), (0, 1.85, 3.0), (0, 3.85, 7), (1, 0.9, 2.1), (1, 2.9, 4.1)])
        #expect(Self.assigned(tokens, segments, .off) == [0, 1, 0, 1, 0, 0, 0])
        // 一括では3つの島がそれぞれ補正前のラベルで判定され、真ん中の0も1へ戻る
        let final = Self.assigned(tokens, segments, .cross)
        #expect(final == [0, 0, 1, 0, 0, 0, 0])
        let result = Self.staged(tokens: tokens, segments: segments, islands: .cross)
        // 「大阪。」まで凍結した後に「京都。」を判定する描画がある
        #expect(result.counts.contains(2))
        #expect(result.frozen == Array(final.prefix(result.frozen.count)))
        #expect(result.frozen.count >= 3)
    }

    @Test func crossの右の隣が語内補正で変わる間は凍結しない() {
        // 「大阪。」の島の右の隣「思」は、「ま」が届いた時点では語「思い」が1対1の同点で0のまま。
        // 「す。」が届くと丁寧語尾が繋がって語「思います」の過半数が1になり、「思」も1になる。
        // 「ま」は島の終端から1.5秒を超えて始まるので、右の隣のフレーズの確定を待たないと、その時点で凍結してしまう
        let tokens = Self.tokens([("東京", 0, 0.9), ("大阪。", 0.9, 1.9), ("思", 1.9, 2.65), ("い", 2.65, 3.43),
                                  ("ま", 3.43, 3.55), ("す。", 3.55, 3.7), ("では", 3.7, 4.7), ("次に。", 4.7, 5.7)])
        let segments = Self.segments([(0, 0, 1.0), (0, 1.8, 2.9), (1, 0.85, 1.85), (1, 2.85, 6)])
        #expect(Self.assigned(tokens, segments, .off) == [0, 1, 1, 1, 1, 1, 1, 1])
        #expect(Self.assigned(Array(tokens.prefix(5)), segments, .cross)[1] == 0)
        let final = Self.assigned(tokens, segments, .cross)
        #expect(final[1] == 1)
        let result = Self.staged(tokens: tokens, segments: segments, islands: .cross)
        #expect(result.frozen == Array(final.prefix(result.frozen.count)))
        #expect(result.frozen.count >= 2)
    }

    @Test func 凍結済みの前半が戻っていない島の後半だけを戻さない() {
        let tokens = Self.recordedTokens
        let off = Aligner.speakers(for: tokens, segments: Self.recordedSegments)
        let cross = Aligner.speakers(for: tokens, segments: Self.recordedSegments, islands: .cross)
        // 「よね。で、」の「よね。」までを戻さないまま凍結した入力
        guard let yo = tokens.indices.first(where: { tokens[$0].text == "よ" && tokens[$0].start > 75 }) else {
            Issue.record("「よ」が見つからない"); return
        }
        let de = yo + 3
        #expect(cross[yo] == 2 && cross[de] == 2 && off[yo] == 1 && off[de] == 1)
        let frozen = Array(off.prefix(de))
        let partial = Aligner.speakers(for: tokens, segments: Self.recordedSegments, frozen: frozen, islands: .cross)
        #expect(partial[de] == 1)
        // 前半が戻っていれば後半も戻す
        let corrected = Array(cross.prefix(de))
        #expect(Aligner.speakers(for: tokens, segments: Self.recordedSegments, frozen: corrected, islands: .cross)[de] == 2)
    }

    @Test func 既定のoffは凍結の条件も変えない() {
        let tokens = Self.recordedTokens
        let speakers = Aligner.speakers(for: tokens, segments: Self.recordedSegments)
        let judged = tokens.last!.end + 1
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: tokens.count,
                                              judgedUntil: judged)
                == SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: tokens.count,
                                                 judgedUntil: judged, islands: .phrase))
    }

    @Test func 試験の段階は環境変数で選び不正な値は止める() throws {
        #expect(try SpeakerTrial.Settings(environment: [:]).islands == .off)
        #expect(try SpeakerTrial.Settings(environment: ["KIKIGAKI_TRIAL_ISLAND": "cross"]).islands == .cross)
        #expect(throws: SpeakerTrial.Settings.Invalid.self) {
            try SpeakerTrial.Settings(environment: ["KIKIGAKI_TRIAL_ISLAND": "strong"])
        }
    }

    @Test func 変更箇所は全ての有意文字が正解区間の中の場合だけ正解区間と数える() {
        let tokens = Self.tokens([("あ", 0, 1), ("い", 1, 2), ("う", 2, 3)])
        let within = SpeakerTrial.Expectation(start: 0, end: 1.2, speaker: 0)
        let changes = SpeakerTrial.changes(tokens: tokens, base: [1, 1, 1], speakers: [0, 0, 0], expectations: [within])
        #expect(changes.count == 1)
        #expect(changes[0].inExpectation == false && changes[0].partlyInExpectation)
        let whole = SpeakerTrial.Expectation(start: 0, end: 3, speaker: 0)
        #expect(SpeakerTrial.changes(tokens: tokens, base: [1, 1, 1], speakers: [0, 0, 0], expectations: [whole])[0].inExpectation)
    }
}
