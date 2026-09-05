import Foundation

/// 文字起こしのトークン時刻と話者判別の区間を突き合わせ、話者ごとの発話行にまとめる。
/// プロト(fluidaudio-sandbox の LiveScribe/Aligner.swift)からの移植。判断の根拠は各関数のコメント
public enum Aligner {
    /// 発話行を分ける無音の長さ(秒)。同じ話者でもこれ以上空けば別の行にする
    public static let utteranceGapSeconds = 1.0
    /// フレーズを切る無音の長さ(秒)
    public static let phraseGapSeconds = 0.35
    /// フレーズ内で別話者がこの長さ以上続く塊は、相槌・割り込みとして多数決から独立させる(秒)。
    /// Apple のトークンは単語級で1個でも 0.5 秒を超えるため、本当の発話交代とみなせる 1.5 秒に
    /// しないと語の分断が残る(実測)
    public static let keepIslandSeconds = 1.5

    /// 時刻 t の話者を決める。t の前後 `halfWindow` 秒の窓と各話者区間の重なり長を話者ごとに合計し、
    /// 最大の話者を採る(窓なしの点判定だと 0.3 秒程度の細切れ区間に引きずられて話者が飛び飛びになる)。
    /// 重なりが無ければ nil
    public static func speaker(at t: Double, segments: [SpeakerSegment], halfWindow: Double = 0.5) -> Int? {
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
    /// 判定は2段階。まずトークンごとに区間から引き、次にフレーズ単位で多数決を取って揃える。
    /// トークン単位のままだと、相槌の重なりや話者区間の数百msのずれが語の途中に切れ目を作る
    /// (「い / や本当に」のような分断。タダシの実録で確認)。フレーズの中で別話者が `keepIslandSeconds`
    /// 以上続く塊だけは相槌・割り込みとして独立させる
    public static func speakers(
        for tokens: [TimedToken], segments: [SpeakerSegment], frozen: [Int?] = [],
        gapSeconds: Double = phraseGapSeconds, keepIslandSeconds: Double = keepIslandSeconds
    ) -> [Int?] {
        var speakers = Array(frozen.prefix(tokens.count))
        for tok in tokens.dropFirst(speakers.count) {
            speakers.append(speaker(at: tok.midpoint, segments: segments))
        }
        for phrase in phraseRanges(tokens, gapSeconds: gapSeconds) {
            // トークンの長さで重み付けした多数決
            var weight: [Int: Double] = [:]
            for i in phrase {
                if let s = speakers[i] { weight[s, default: 0] += max(tokens[i].duration, 0.04) }
            }
            guard let major = argmax(weight) else { continue }
            // 多数派と違う短い塊を多数派に揃える(凍結済みは触らない)
            var i = phrase.lowerBound
            while i < phrase.upperBound {
                var j = i
                while j < phrase.upperBound && speakers[j] == speakers[i] { j += 1 }
                if speakers[i] != major {
                    let span = tokens[j - 1].end - tokens[i].start
                    if span < keepIslandSeconds {
                        for k in i..<j where k >= frozen.count { speakers[k] = major }
                    }
                }
                i = j
            }
        }
        return speakers
    }

    /// フレーズの切れ目: エンジンのフレーズ id が変わる / 直前との間が `gapSeconds` 以上空く / 直前が文末の句点
    public static func phraseRanges(_ tokens: [TimedToken], gapSeconds: Double = phraseGapSeconds) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for i in 1..<max(tokens.count, 1) {
            let prev = tokens[i - 1]
            let boundary =
                tokens[i].phraseId != prev.phraseId
                || tokens[i].start - prev.end >= gapSeconds
                || endsSentence(prev)
            if boundary {
                ranges.append(start..<i)
                start = i
            }
        }
        if start < tokens.count { ranges.append(start..<tokens.count) }
        // エンジンの結果境界が語の途中に落ちて1トークンだけ取り残されることがある(「ま / あ結局」)。
        // 短い1トークンのフレーズは、無音を挟まない次のフレーズへ寄せる。ただし句点で終わる
        // トークンは文の終わりなので寄せない(「はい。」の直後に別話者が続くと多数決で塗り替わる)
        var merged: [Range<Int>] = []
        var i = 0
        while i < ranges.count {
            var r = ranges[i]
            while r.count == 1, i + 1 < ranges.count,
                tokens[r.lowerBound].duration < 0.4,
                !endsSentence(tokens[r.upperBound - 1]),
                tokens[ranges[i + 1].lowerBound].start - tokens[r.upperBound - 1].end < 0.2
            {
                i += 1
                r = r.lowerBound..<ranges[i].upperBound
            }
            merged.append(r)
            i += 1
        }
        return merged
    }

    /// 文末の句点・感嘆符・疑問符で終わるトークンか
    static func endsSentence(_ token: TimedToken) -> Bool {
        token.text.last.map { "。！？!?".contains($0) } == true
    }

    /// トークン列と話者列を発話行にまとめる。同じ話者でもトークン間が `gap` 秒以上空けば行を分ける
    public static func utterances(tokens: [TimedToken], speakers: [Int?], gap: Double = utteranceGapSeconds) -> [Utterance] {
        var result: [Utterance] = []
        for (tok, spk) in zip(tokens, speakers) {
            if var last = result.last, last.speaker == spk, tok.start - last.end < gap {
                last.text += tok.text
                last.end = tok.end
                result[result.count - 1] = last
            } else {
                result.append(Utterance(speaker: spk, start: tok.start, end: tok.end, text: tok.text))
            }
        }
        for i in result.indices {
            result[i].text = result[i].text.trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
