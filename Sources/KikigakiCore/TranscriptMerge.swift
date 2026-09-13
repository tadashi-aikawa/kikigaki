import Foundation

/// 高精度の文字起こしへ、その先の速報を継ぎ足す。
///
/// Apple Speech は確定した文字を訂正しないため、速報を保存へ残すと粗いまま固定される。
/// 高精度が確定させた範囲までは高精度を使い、その先だけ速報で埋めると、画面は速く出て、
/// 高精度が追いついた箇所から正しい文字へ入れ替わる。
public enum TranscriptMerge {
    public struct Snapshot: Sendable {
        public let tokens: [TimedToken]
        /// 表示の通常行へ出す個数。速報側の確定を含む
        public let finalCount: Int
        /// 話者を凍結できる個数。差し替わる速報は含めない
        public let accurateFinalCount: Int

        public init(tokens: [TimedToken], finalCount: Int, accurateFinalCount: Int) {
            self.tokens = tokens
            self.finalCount = finalCount
            self.accurateFinalCount = accurateFinalCount
        }
    }

    /// - Parameters:
    ///   - accurate: 高精度側のトークン列(確定 + 暫定)
    ///   - accurateFinalCount: `accurate` の先頭から確定結果に属する個数
    ///   - fast: 速報側のトークン列(確定 + 暫定)
    ///   - fastFinalCount: `fast` の先頭から確定結果に属する個数
    /// - Returns: 表示・AIへ渡すトークン列と、先頭から確定扱いにできる個数
    public static func combine(accurate: [TimedToken], accurateFinalCount: Int,
                               fast: [TimedToken], fastFinalCount: Int) -> Snapshot {
        let confirmed = min(max(0, accurateFinalCount), accurate.count)
        let base = Array(accurate.prefix(confirmed))
        // 高精度が確定させた終端。速報側はここより後に始まるトークンだけ使い、同じ音声を二重に出さない
        let boundary = base.last?.end
        var tokens = base
        var finalCount = confirmed
        let fastFinal = min(max(0, fastFinalCount), fast.count)
        for (index, token) in fast.enumerated() {
            guard boundary.map({ token.start >= $0 }) ?? true else { continue }
            // エンジンのIDは正数。負数側へ移し、長時間の会議でも高精度側と衝突させない。
            tokens.append(TimedToken(text: token.text, phraseId: ~token.phraseId,
                                     start: token.start, end: token.end))
            if index < fastFinal { finalCount += 1 }
        }
        // 速報の確定の後ろに速報の暫定が並ぶ。確定の個数は先頭からの連続数として数え直す
        return Snapshot(tokens: tokens, finalCount: min(finalCount, tokens.count), accurateFinalCount: confirmed)
    }
}
