/// 発話行ゲージ専用の表示情報。保存する Utterance には混ぜない。
public struct UtteranceProgress: Equatable, Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case tentative, fastFinal, accurateFinal, speakerFixed

        public var label: String {
            switch self {
            case .tentative: "暫定"
            case .fastFinal: "速報の確定"
            case .accurateFinal: "高精度の確定"
            case .speakerFixed: "話者固定"
            }
        }

        public var tooltip: String {
            self == .speakerFixed ? "話者固定。停止時に全体を再判定します" : label
        }
    }

    public let steps: [Stage]
    /// LiveTranscript.utterances と同じ添字。nil は最終段に到達してゲージを消した行。
    public let rows: [Stage?]
    /// 通常行とは別の暫定末尾。文字がないときは nil。
    public let tentative: Stage?
}
