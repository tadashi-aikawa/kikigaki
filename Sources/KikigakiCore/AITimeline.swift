import Foundation

/// AIの送信と返事を、人の発話と同じ列へ並べるための位置と表示値を決める。
/// AIはUtteranceにしないので `TranscriptEntries.merge` へは混ぜず、ここで位置だけを解決する。
/// AppKit型・色・フォント・時刻の書式は持たない。時刻はDateのまま返す。
public enum AITimeline {
    /// 置き場所。afterUtteranceは声の送信だけが使い、解決できなければ日時順へ落とす。
    public enum Anchor: Equatable, Sendable {
        case afterUtterance(Int)
        case at(Date)
        /// 返事待ち。送信時刻の位置ではなく常に末尾側へ置く。上へ跳ねさせないための規則。
        case tail
    }

    public enum ReplyState: Equatable, Sendable { case waiting, answered, needsInput }

    public enum Kind: Equatable, Sendable {
        /// 細い1行。automatic は定期自動送信。
        case sendLine(automatic: Bool)
        /// 人側の送信行。問い欄へ入力した手動送信と、確認への返答だけが使う。
        case sendRow
        case reply(ReplyState)
        case failure(reason: String)
    }

    public struct Item: Equatable, Sendable {
        public let requestID: UUID
        public let number: Int
        public let participantName: String
        public let automatic: Bool
        public let kind: Kind
        public let anchor: Anchor
        /// 直前に置く発話の添字。-1は全ての発話より前。
        public let slot: Int
        /// 送信は送信時刻、返事は到着時刻。返事待ちはnil。
        public let date: Date?
        /// 送信の行では送信文そのもの。返事の行では上へ添える1行引用で、手動typedのときだけ非空。
        public let question: String
        public let parentNumber: Int?
        public let body: String
        public let notes: [String]
        public let isUnread: Bool
        public let needsAnswer: Bool

        public var isSend: Bool {
            switch kind {
            case .sendLine, .sendRow: return true
            case .reply, .failure: return false
            }
        }
        /// 行ビューの再利用キー。返事待ちと返事、失敗の帯は同じ `/reply` を使い、
        /// 到着で行が生まれ直して高さが跳ねることを防ぐ。
        public var rowID: String { requestID.uuidString + (isSend ? "/send" : "/reply") }
    }

    /// 表示順に並べた要素を返す。`slot` の昇順で、同じslotの中もこの順で置ける。
    /// generationは現在のAIセッション世代で、旧接続からの返事の注記だけに使う。
    public static func items(conversation: AIConversation?, utterances: [Utterance],
                             timeline: MeetingTimeline, generation: Int = 1) -> [Item] {
        guard let conversation else { return [] }
        let dates = utterances.map { TranscriptRenderer.date(for: $0, timeline: timeline) }
        var built: [(item: Item, rank: Int, sortDate: Date, side: Int)] = []
        for question in conversation.questions {
            let request = question.request
            let participant = request.envelope.participant
            let automatic = request.trigger == .scheduled
            let sendDate = question.sendAttemptedAt ?? participant.capturedAt
            let parentNumber = participant.inReplyToRequestID.flatMap { id in
                conversation.questions.first { $0.request.id == id }?.request.number
            }

            // 送信の形は question_source だけでは決まらない。自動送信はtypedだが細い1行にする。
            let sendKind: Kind = automatic ? .sendLine(automatic: true)
                : participant.questionSource == .voice ? .sendLine(automatic: false) : .sendRow
            let voiceIndex = request.voiceAnchorIndex(in: utterances)
            let sendAnchor: Anchor = voiceIndex.map { .afterUtterance($0) } ?? .at(sendDate)
            var sendNotes = ["対象: \(request.envelope.readLineCount)発言"]
            if !participant.workAllowed { sendNotes.append("作業許可なし") }
            if participant.tentativeTail != nil { sendNotes.append("暫定末尾を含む") }
            switch question.state {
            case .deliveryUnknown where question.sendAttemptedAt != nil: sendNotes.append("送達不明")
            case .prepared: sendNotes.append("送信準備中")
            case .cancelled where question.result == nil: sendNotes.append("取消")
            default: break
            }
            built.append((Item(requestID: request.id, number: request.number, participantName: participant.participantName,
                               automatic: automatic, kind: sendKind, anchor: sendAnchor,
                               slot: slot(for: sendAnchor, dates: dates), date: sendDate,
                               question: request.displayQuestion, parentNumber: parentNumber, body: "",
                               notes: sendNotes, isUnread: false, needsAnswer: false),
                          rank: rank(sendAnchor), sortDate: sendDate, side: 0))

            guard let reply = replyKind(question) else { continue }
            let arrival = question.resultReceivedAt
            let anchor: Anchor = reply == .reply(.waiting) ? .tail : .at(arrival ?? sendDate)
            var notes: [String] = []
            if question.cancelledAt != nil { notes.append("取消後の返事") }
            if participant.sessionGeneration < generation { notes.append("旧接続からの返事") }
            if question.answeredByRequestID != nil { notes.append("返答済み") }
            // 引用は手動typedの送信だけに添える。声は発話そのものが送信文で、自動は毎回同じ定型文になる。
            let quote = sendKind == .sendRow ? request.displayQuestion : ""
            built.append((Item(requestID: request.id, number: request.number, participantName: participant.participantName,
                               automatic: automatic, kind: reply, anchor: anchor,
                               slot: slot(for: anchor, dates: dates),
                               date: reply == .reply(.waiting) ? nil : arrival,
                               question: quote, parentNumber: parentNumber, body: question.result?.body ?? "",
                               notes: notes, isUnread: question.isUnread,
                               needsAnswer: question.state == .needsInput && question.answeredByRequestID == nil),
                          rank: rank(anchor), sortDate: arrival ?? sendDate, side: 1))
        }
        // 同じslotの中は afterUtterance → 日時順 → 末尾。同着は送信を先にし、最後はrequest番号で決める。
        return built.enumerated().sorted { left, right in
            let (a, b) = (left.element, right.element)
            if a.item.slot != b.item.slot { return a.item.slot < b.item.slot }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.rank != 0, a.sortDate != b.sortDate { return a.sortDate < b.sortDate }
            if a.rank != 2, a.side != b.side { return a.side < b.side }
            if a.item.number != b.item.number { return a.item.number < b.item.number }
            return left.offset < right.offset
        }.map(\.element.item)
    }

    private static func replyKind(_ question: AIQuestion) -> Kind? {
        if question.state == .failed {
            let text = question.failure ?? question.result?.body ?? question.result?.reason ?? ""
            let line = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return .failure(reason: line ?? "原因不明")
        }
        if let result = question.result { return .reply(result.kind == .needsInput ? .needsInput : .answered) }
        // 送達不明は成否が分からないので「考え中…」を出さない。送信の行の注記に留める。
        guard question.isAwaitingResult, question.state != .deliveryUnknown else { return nil }
        return .reply(.waiting)
    }

    private static func rank(_ anchor: Anchor) -> Int {
        switch anchor {
        case .afterUtterance: return 0
        case .at: return 1
        case .tail: return 2
        }
    }

    private static func slot(for anchor: Anchor, dates: [Date]) -> Int {
        switch anchor {
        case let .afterUtterance(index): return index
        case let .at(date): return (dates.lastIndex { $0 <= date }) ?? -1
        case .tail: return dates.count - 1
        }
    }
}
