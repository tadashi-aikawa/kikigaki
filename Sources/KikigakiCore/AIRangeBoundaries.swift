import Foundation

/// 自動送信先の現streamが読んだ末尾。添字は0始まり、nilは境界なし。
/// 停止時の再分割・省略で添字が変わるため、受領した音声位置を表示配列へ写し直す。
public struct AIRangeBoundaries: Equatable, Sendable {
    public let answered: Int?
    public let accepted: Int?
    public init(answered: Int? = nil, accepted: Int? = nil) {
        self.answered = answered; self.accepted = accepted
    }

    public static func resolve(history: AIStreamHistory, questions: [AIQuestion], utterances: [Utterance]) -> Self {
        let current = questions.filter {
            let p = $0.request.envelope.participant
            return $0.request.envelope.meetingID == history.meetingID
                && p.streamID == history.streamID && p.sessionGeneration == history.sessionGeneration
        }
        func end(_ question: AIQuestion?) -> Int? {
            guard let envelope = question?.request.envelope, envelope.totalLineCount > 0 else { return nil }
            return utterances.lastIndex { $0.start <= envelope.participant.audioCutoffSeconds }
        }
        let answered = end(current.filter { $0.result?.kind == .answered && $0.contextReceived }
            .max { ($0.resultOrder ?? 0) < ($1.resultOrder ?? 0) })
        let accepted = end(current.filter { $0.acceptance != nil && $0.isAwaitingResult }
            .max { $0.request.number < $1.request.number })
        // 同じ位置・返事済みより古い受領は二重に描かない。
        return Self(answered: answered, accepted: accepted.flatMap { value in
            answered.map { value > $0 ? value : nil } ?? value
        })
    }
}
