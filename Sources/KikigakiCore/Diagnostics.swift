import Foundation

/// 調査用の stderr 出力の文言。出力先と有効・無効の判定をここに集め、判定そのものからは切り離す。
/// 既存の診断ログを読む手順が CLAUDE.md にあるので、文字列の形は変えない
public struct Diagnostics: Sendable {
    /// 停止直前の録音中表示。最終結果との差を調べる用
    public let showsLive: Bool
    /// 録音中の表示更新ごとの全文。会話本文を含む
    public let showsLiveTrace: Bool
    /// 停止時のフレーズ分割と話者判定の変化
    public let showsPhrases: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        showsLive = environment["KIKIGAKI_DEBUG_LIVE"] != nil
        showsLiveTrace = environment["KIKIGAKI_DEBUG_LIVE_TRACE"] != nil
        showsPhrases = environment["KIKIGAKI_DEBUG_PHRASES"] != nil
    }

    public func liveLines(_ utterances: [Utterance], names: SpeakerNames) -> [String] {
        guard showsLive else { return [] }
        return ["[live]\n" + TranscriptRenderer.text(utterances, names: names)]
    }

    public func liveTraceLines(_ utterances: [Utterance], names: SpeakerNames, elapsed: Double) -> [String] {
        guard showsLiveTrace else { return [] }
        return [String(format: "[live at=%.2f]\n", elapsed) + TranscriptRenderer.text(utterances, names: names)]
    }

    /// 省略候補の通知。環境変数によらず出す(省略は原文と突き合わせて確かめるものなので、
    /// 何を落としたかは常に残す)
    public func backchannelLines(tokens: [TimedToken], candidates: [Range<Int>]) -> [String] {
        candidates.map { range in
            "[backchannel] " + String(format: "%.2f-%.2f", tokens[range.lowerBound].start, tokens[range.upperBound - 1].end)
                + " " + tokens[range].map(\.text).joined()
        }
    }

    /// 区間と、フレーズごとの「生の判定(区間からの窓判定)→多数決後の判定」と時刻
    public func phraseLines(tokens: [TimedToken], segments: [SpeakerSegment], speakers: [Int?]) -> [String] {
        guard showsPhrases else { return [] }
        var lines = segments.sorted(by: { $0.start < $1.start }).map { segment in
            "[segment] \(segment.speaker) " + String(format: "%.3f-%.3f", segment.start, segment.end)
        }
        let raw = tokens.map { Aligner.speaker(at: $0.midpoint, segments: segments) }
        for r in Aligner.phraseRanges(tokens) {
            let desc = r.map { i in
                "\(tokens[i].text)[\(raw[i].map(String.init) ?? "?")→\(speakers[i].map(String.init) ?? "?") "
                    + String(format: "%.2f-%.2f", tokens[i].start, tokens[i].end) + "]"
            }.joined(separator: " ")
            lines.append("[phrase id=\(tokens[r.lowerBound].phraseId)] \(desc)")
        }
        return lines
    }
}
