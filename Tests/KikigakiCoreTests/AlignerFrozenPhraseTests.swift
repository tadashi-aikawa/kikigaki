import Testing

@testable import KikigakiCore

/// 録音中の再判定で、全体が凍結済みのフレーズを解析ごと飛ばしても結果が変わらないことを見る。
@Suite struct AlignerFrozenPhraseTests {
    /// 3フレーズ。無音 0.5 秒で区切られ、各フレーズに多数派へ吸収される短い島がある
    private static let texts = [
        "読", "みやすい", "し",
        "一応", "経過報告", "をさせていただきます",
        "続いてまし", "て", "すごいです",
    ]
    private static let times: [(Double, Double)] = [
        (0, 2), (2, 2.5), (2.5, 5),
        (5.5, 7.5), (7.5, 8), (8, 10.5),
        (11, 13), (13, 13.5), (13.5, 16),
    ]
    private let tokens = zip(Self.texts, Self.times).map {
        TimedToken(text: $0.0, phraseId: 1, start: $0.1.0, end: $0.1.1)
    }
    /// 窓判定の観測値。フレーズごとに真ん中のトークンだけ別話者に見えている
    private let raw: [Int?] = [0, 1, 0, 1, 0, 1, 0, 1, 0]
    /// フレーズの切れ目(トークン添字)
    private let boundaries = [0, 3, 6, 9]

    @Test func 凍結なしでは各フレーズの短い島を多数派へ吸収する() {
        #expect(Aligner.phraseRanges(tokens) == [0..<3, 3..<6, 6..<9])
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: raw) == [0, 0, 0, 1, 1, 1, 0, 0, 0])
    }

    @Test func 凍結がフレーズの切れ目にあれば凍結の有無で結果が変わらない() {
        let all = Aligner.smoothSpeakers(tokens: tokens, speakers: raw)
        for frozenCount in boundaries {
            // 凍結済みの部分は前回の判定結果が `initial` に入っている
            let initial = Array(all.prefix(frozenCount)) + raw.dropFirst(frozenCount)
            #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: initial, frozenCount: frozenCount) == all,
                    "凍結 \(frozenCount) トークンで結果が変わった")
        }
    }

    @Test func 凍結済みフレーズの話者は塗り替えない() {
        // 先頭フレーズだけ、吸収していない観測値のまま凍結する
        let initial: [Int?] = raw
        let result = Aligner.smoothSpeakers(tokens: tokens, speakers: initial, frozenCount: 3)
        #expect(Array(result.prefix(3)) == [0, 1, 0])
        #expect(Array(result.dropFirst(3)) == [1, 1, 1, 0, 0, 0])
    }

    @Test func 凍結の切れ目をまたぐフレーズは従来通り処理する() {
        // 2番目のフレーズの途中(添字4)まで凍結。凍結後の島は多数派へ吸収される
        let initial = Array(([0, 0, 0, 1, 0] as [Int?])) + raw.dropFirst(5)
        let result = Aligner.smoothSpeakers(tokens: tokens, speakers: initial, frozenCount: 5)
        #expect(Array(result.prefix(5)) == [0, 0, 0, 1, 0])
        #expect(Array(result.dropFirst(5)) == [1, 0, 0, 0])
    }
}
