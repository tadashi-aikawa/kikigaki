import Foundation

/// 文字起こしのトークン時刻と話者判別の区間を突き合わせ、話者ごとの発話行にまとめる。
/// プロト(fluidaudio-sandbox の LiveScribe/Aligner.swift)からの移植。判断の根拠は各関数のコメント
public enum Aligner {
    /// 発話行を分ける無音の長さ(秒)。同じ話者でもこれ以上空けば別の行にする
    public static let utteranceGapSeconds = 1.0
    /// フレーズを切る無音の長さ(秒)
    public static let phraseGapSeconds = 0.35
    /// `speaker(at:)` の窓の半幅(秒)。この先まで区間が判定済みなら、窓判定は後から変わらない
    public static let windowHalfSeconds = 0.5
    /// 長い語頭の付け替えで、後続話者の区間が語頭の末尾を覆うべき長さ(秒)
    static let headTailSeconds = 0.12

    /// 時刻 t の話者を決める。t の前後 `halfWindow` 秒の窓と各話者区間の重なり長を話者ごとに合計し、
    /// 最大の話者を採る(窓なしの点判定だと 0.3 秒程度の細切れ区間に引きずられて話者が飛び飛びになる)。
    /// 重なりが無ければ nil
    public static func speaker(at t: Double, segments: [SpeakerSegment], halfWindow: Double = windowHalfSeconds) -> Int? {
        var overlap: [Int: Double] = [:]
        let lo = t - halfWindow, hi = t + halfWindow
        for s in segments {
            let o = min(hi, s.end) - max(lo, s.start)
            guard o > 0 else { continue }
            overlap[s.speaker, default: 0] += o
        }
        return argmax(overlap)
    }

    /// 重み最大の話者。同点は番号の小さい話者に倒す。Swift の Dictionary はインスタンスごとに
    /// 反復順が変わるので、`max(by:)` に同点を任せると呼ぶたびに答えが変わる(実測: 同じ入力で
    /// 表示と保存の話者が食い違った)
    public static func argmax(_ weights: [Int: Double]) -> Int? {
        weights.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }.first?.key
    }

    /// 各トークンの話者を決める。`frozen` に入っている先頭部分はそのまま使い(確定済みの行を後から
    /// 塗り替えないため)、残りだけ区間から判定する。
    ///
    /// トークンごとに窓判定で区間から引き、長い1文字の語頭と語内の境界を補正する。その後、話し手の声が
    /// 続く中で重なった別話者へ割れた短い島を両隣の話者へ戻す(`SpeakerIslands`)。
    /// フレーズの多数派へ短い別話者の塊を吸収する補正は置かない。吸収を外した比較と採用の経緯:
    /// docs/speaker-assignment.md。島の補正の段階の比較と採用も同じ文書にある
    ///
    /// 島は補正前のラベルで判定するので、凍結境界の手前も補正前のラベルを計算し直す
    public static func speakers(for tokens: [TimedToken], segments: [SpeakerSegment], frozen: [Int?] = []) -> [Int?] {
        let frozenCount = min(frozen.count, tokens.count)
        let recompute = SpeakerIslands.recomputeStart(tokens: tokens, frozenCount: frozenCount)
        var speakers = Array(frozen.prefix(recompute))
        let observed = SpeechTail.speakers(tokens: tokens, segments: segments, skippingPrefix: recompute)
        speakers.append(contentsOf: observed.dropFirst(recompute))
        let base = wordSpeakers(tokens: tokens, speakers: speakers, frozenCount: recompute, segments: segments)
        let islanded = SpeakerIslands.apply(tokens: tokens, base: base, segments: segments,
                                            frozen: Array(frozen.prefix(frozenCount)))
        return attachPunctuation(tokens: tokens, speakers: islanded, frozenCount: frozenCount)
    }

    /// 窓判定の観測値を回帰テストへ渡せるよう、音声区間との突き合わせと分ける。
    /// `segments` は長い語頭の付け替えだけが読む
    static func smoothSpeakers(tokens: [TimedToken], speakers initial: [Int?], frozenCount: Int = 0,
                               segments: [SpeakerSegment] = []) -> [Int?] {
        attachPunctuation(tokens: tokens,
                          speakers: wordSpeakers(tokens: tokens, speakers: initial, frozenCount: frozenCount, segments: segments),
                          frozenCount: frozenCount)
    }

    /// 語内の境界の補正。`frozenCount` より前は書き換えない
    static func wordSpeakers(tokens: [TimedToken], speakers initial: [Int?], frozenCount: Int,
                             segments: [SpeakerSegment]) -> [Int?] {
        var speakers = initial
        for phrase in phraseRanges(tokens) {
            // 全体が凍結済みのフレーズは語内補正が書き込まない(`word.lowerBound >= frozenCount`)。
            // 語境界の解析(NLTokenizer)だけが毎回走るので飛ばす。長い会議の録音中に効く
            if phrase.upperBound <= frozenCount { continue }
            let words = WordBoundaries(tokens: Array(tokens[phrase])).tokenRanges
                .map { ($0.lowerBound + phrase.lowerBound)..<($0.upperBound + phrase.lowerBound) }
            for word in words {
                guard word.lowerBound >= frozenCount,
                      word.allSatisfy({ initial[$0] != nil && tokens[$0].duration.isFinite && tokens[$0].duration > 0 }) else { continue }
                var counts: [Int: Int] = [:]
                for k in word {
                    counts[initial[k]!, default: 0] += tokens[k].text.filter { $0.isLetter || $0.isNumber }.count
                }
                let total = counts.values.reduce(0, +)
                // ASRの語頭は前の発話や無音を含んで長くなる。ここだけは時間ではなく文字数を使う。
                if let winner = counts.first(where: { $0.value * 2 > total })?.key {
                    for k in word { speakers[k] = winner }
                    continue
                }
                // 同点は語末などへ決め打ちしない。元の境界を残す。長い語頭だけは例外
                if let following = longHeadSpeaker(word: word, speakers: initial, tokens: tokens, segments: segments) {
                    speakers[word.lowerBound] = following
                }
            }
        }
        return speakers
    }

    /// 句読点だけのトークンは直前のトークンの話者に付ける(凍結済みは触らない)。句点は直前の文の
    /// 一部で、時刻が次の発話の頭に食い込むと別話者に判定され「。」だけの行になる(実録で確認)
    static func attachPunctuation(tokens: [TimedToken], speakers initial: [Int?], frozenCount: Int) -> [Int?] {
        var speakers = initial
        for i in speakers.indices where i >= frozenCount && i > 0 && isPunctuationOnly(tokens[i]) {
            speakers[i] = speakers[i - 1]
        }
        return speakers
    }

    /// 語の先頭が長い1文字で、その1文字だけが別の既知話者のとき、語の残りの話者を返す。
    /// 付け替えるのは語頭の1文字だけで、語の残りは変えない。
    ///
    /// 「思 / い通り行きます。」「自 / 己肯定ですよ。」は原音で全体が同じ話者と確認した。
    /// 区間データでは、どちらも語頭の時間の前半に別話者の区間があり、後続話者の区間が語頭の末尾から
    /// 続く。前半は文字にならなかった別話者の声で、語頭の文字自体は末尾で発音されたと推測する
    /// (原音で確かめたのは話者の正解だけ)。前半が無音なら `SpeechTail` が直すが、別話者の声が続くと直せない。
    ///
    /// 独立した短い返答を奪わないよう、次の全てを満たす場合に限る。
    /// - 語頭と後続が同じ語。NLTokenizer の語で両端がASRトークンの境界と一致する
    /// - 語頭は既知の話者。不明を新しく補わない
    /// - 語の残りが全て同じ既知話者
    /// - 後続話者の区間が、語頭の末尾 `headTailSeconds` 以上を途切れず覆う
    static func longHeadSpeaker(word: Range<Int>, speakers: [Int?], tokens: [TimedToken],
                                segments: [SpeakerSegment]) -> Int? {
        let head = word.lowerBound
        guard word.count >= 2, SpeechTail.isLongSingle(tokens[head]), let own = speakers[head],
              let following = speakers[head + 1], following != own,
              word.dropFirst().allSatisfy({ speakers[$0] == following }) else { return nil }
        let end = tokens[head].end
        var covered = end - headTailSeconds
        for segment in segments.filter({ $0.speaker == following && $0.end > covered }).sorted(by: { $0.start < $1.start }) {
            guard segment.start <= covered else { break }
            covered = max(covered, segment.end)
        }
        return covered >= end ? following : nil
    }

    /// 句読点・空白だけのトークンか
    static func isPunctuationOnly(_ token: TimedToken) -> Bool {
        let trimmed = token.text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { "。、！？!?,.".contains($0) }
    }

    /// エンジンの結果境界(phraseId の変化)をフレーズの切れ目として数える最小の無音(秒)。
    /// Apple の確定結果の境界は語の途中にも落ちる(「読 / みやすい」「わ / かりました」)。無音を
    /// ほぼ挟まない境界は発話の区切りではないので、語内補正の対象フレーズを切らない。
    /// プロトでは「0.4秒未満の1トークンだけ次へ寄せる」救済だったが、1文字が0.4秒を超える
    /// 喋り方で救済から漏れて1文字の行が残った(タダシの実録で確認)
    public static let resultBoundaryGapSeconds = 0.2

    /// フレーズの切れ目: 直前との間が `gapSeconds` 以上空く / 直前が文末の句点 /
    /// エンジンのフレーズ id が変わり、かつ直前との間が `resultBoundaryGapSeconds` 以上空く
    public static func phraseRanges(_ tokens: [TimedToken], gapSeconds: Double = phraseGapSeconds) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for i in 1..<max(tokens.count, 1) {
            let prev = tokens[i - 1]
            let gap = tokens[i].start - prev.end
            let boundary =
                gap >= gapSeconds
                || endsSentence(prev)
                || (tokens[i].phraseId != prev.phraseId && gap >= resultBoundaryGapSeconds)
            if boundary {
                ranges.append(start..<i)
                start = i
            }
        }
        if start < tokens.count { ranges.append(start..<tokens.count) }
        return ranges
    }

    /// 文末の句点・感嘆符・疑問符で終わるトークンか
    static func endsSentence(_ token: TimedToken) -> Bool {
        token.text.last.map { "。！？!?".contains($0) } == true
    }

    /// トークン列と話者列を発話行にまとめる。同じ話者でもトークン間が `gap` 秒以上空けば行を分ける
    public static func utterances(tokens: [TimedToken], speakers: [Int?], gap: Double = utteranceGapSeconds) -> [Utterance] {
        utteranceTokenRanges(tokens: tokens, speakers: speakers, gap: gap).map { range in
            Utterance(speaker: speakers[range.lowerBound], start: tokens[range.lowerBound].start,
                      end: tokens[range.upperBound - 1].end,
                      text: tokens[range].map(\.text).joined().trimmingCharacters(in: .whitespaces))
        }
    }

    /// 表示と固定待ちの判定で同じ行境界を使う。時刻が重なるトークンも添字で区別する。
    static func utteranceTokenRanges(tokens: [TimedToken], speakers: [Int?], gap: Double = utteranceGapSeconds) -> [Range<Int>] {
        let count = min(tokens.count, speakers.count)
        guard count > 0 else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        for index in 1..<count {
            if speakers[index] != speakers[index - 1] || !(tokens[index].start - tokens[index - 1].end < gap) {
                result.append(start..<index)
                start = index
            }
        }
        result.append(start..<count)
        return result
    }
}
