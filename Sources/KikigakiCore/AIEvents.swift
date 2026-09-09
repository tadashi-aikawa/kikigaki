import Foundation

public enum AIQuestionState: String, Codable, Sendable {
    case prepared, submitted, accepted, needsInput = "needs_input", answered, failed
    case deliveryUnknown = "delivery_unknown", cancelled
}

/// requestは送信前に固定する。問いの表示はその時点の末尾発話をコピーし、改名後も書き換えない。
public struct AIRequest: Codable, Equatable, Sendable {
    public let envelope: AIEnvelope
    public let number: Int
    public let displayQuestion: String
    public let timeRange: AIContextTimeRange?
    /// 声の問いに使った確定済み末尾発話の位置。表示名や停止後の再分割に依存しない。
    public let voiceUtteranceStart: Double?
    public var id: UUID { envelope.participant.requestID }
    public var trigger: AIParticipantContext.Trigger? { envelope.participant.trigger }
    public var automaticLabel: String { trigger == .scheduled ? " · 自動" : "" }

    public init(envelope: AIEnvelope, number: Int, voiceQuestion: String = "", snapshot: AIContextSnapshot? = nil,
                voiceUtteranceStart: Double? = nil) throws {
        self.envelope = envelope; self.number = number
        if let snapshot {
            guard try AIEnvelope(snapshot: snapshot, participant: envelope.participant) == envelope else { throw AIError.mismatch }
        }
        timeRange = snapshot?.timeRange
        self.voiceUtteranceStart = envelope.participant.questionSource == .voice ? voiceUtteranceStart : nil
        displayQuestion = envelope.participant.questionSource == .typed ? envelope.participant.question : voiceQuestion
        try validate()
    }

    public func validate() throws {
        try envelope.validate()
        try timeRange?.validate()
        guard number > 0 else { throw AIError.invalid("question number") }
        try AIValidation.text(displayQuestion, limit: AILimits.questionBytes)
        if let start = voiceUtteranceStart {
            guard envelope.participant.questionSource == .voice, start.isFinite, start >= 0,
                  start <= envelope.participant.audioCutoffSeconds else { throw AIError.invalid("voice utterance start") }
        }
        if envelope.participant.questionSource == .typed, displayQuestion != envelope.participant.question {
            throw AIError.mismatch
        }
    }

    /// 再分割で同じ開始位置がなくなったら、その位置以下の最も近い発話へ置く。
    /// 旧requestや確定行がない問いは、従来の送信時刻で配置する。
    public func voiceAnchorIndex(in utterances: [Utterance]) -> Int? {
        guard envelope.participant.questionSource == .voice, let start = voiceUtteranceStart else { return nil }
        return utterances.indices.filter { utterances[$0].kind == .voice && utterances[$0].start <= start }.max {
            utterances[$0].start == utterances[$1].start ? $0 < $1 : utterances[$0].start < utterances[$1].start
        }
    }
}

public struct AIReceiveEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case accept, answered, needsInput = "needs_input", failed
    }
    public let schemaVersion: Int
    public let eventID: String
    public let meetingID: UUID
    public let requestID: UUID
    public let sessionGeneration: Int
    public let snapshotID: UUID
    public let kind: Kind
    public let recordedAt: Date
    public let contextReceived: Bool
    public let body: String?
    public let reason: String?
    public var filename: String { "\(requestID.uuidString).\(kind == .accept ? "accept" : "result").json" }

    public init(request: AIRequest, kind: Kind, recordedAt: Date, body: String? = nil, reason: String? = nil) throws {
        schemaVersion = 1; eventID = "\(request.id.uuidString)/\(kind == .accept ? "accept" : "result")"
        meetingID = request.envelope.meetingID; requestID = request.id
        sessionGeneration = request.envelope.participant.sessionGeneration; snapshotID = request.envelope.snapshotID
        self.kind = kind; self.recordedAt = recordedAt; self.body = body; self.reason = reason
        contextReceived = reason != "context_missing" && reason != "read_failed"
        try validate(for: request)
    }

    public func validate(for request: AIRequest) throws {
        try request.validate()
        guard schemaVersion == 1, meetingID == request.envelope.meetingID, requestID == request.id,
              sessionGeneration == request.envelope.participant.sessionGeneration, snapshotID == request.envelope.snapshotID,
              eventID == "\(requestID.uuidString)/\(kind == .accept ? "accept" : "result")",
              recordedAt.timeIntervalSince1970.isFinite else { throw AIError.mismatch }
        guard contextReceived == (reason != "context_missing" && reason != "read_failed") else { throw AIError.invalid("context_received") }
        switch kind {
        case .accept:
            guard body == nil, reason == nil, contextReceived else { throw AIError.invalid("accept") }
        case .answered:
            guard reason == nil else { throw AIError.invalid("answer reason") }
        case .needsInput:
            guard reason == "clarification" || reason == "context_missing" else { throw AIError.invalid("clarification reason") }
        case .failed:
            guard let reason, AIValidation.singleLine(reason), reason != "context_missing", reason.utf8.count <= 128 else {
                throw AIError.invalid("failure reason")
            }
        }
        if kind != .accept {
            guard let body else { throw AIError.invalid("body") }
            try AIValidation.text(body, limit: AILimits.bodyBytes, nonempty: true)
        }
    }

    /// 再試行でCLIが採った保存時刻の差は同一性に含めない。
    public func sameContent(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion && eventID == other.eventID && meetingID == other.meetingID
            && requestID == other.requestID && sessionGeneration == other.sessionGeneration
            && snapshotID == other.snapshotID && kind == other.kind && contextReceived == other.contextReceived
            && body == other.body && reason == other.reason
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", meetingID = "meeting_id", requestID = "request_id"
        case sessionGeneration = "session_generation", snapshotID = "snapshot_id", kind, recordedAt = "recorded_at"
        case contextReceived = "context_received", body, reason
    }
}

public struct AIQuestion: Codable, Equatable, Sendable {
    public let request: AIRequest
    public private(set) var state: AIQuestionState = .prepared
    public private(set) var sendAttemptedAt: Date?
    public private(set) var acceptance: AIReceiveEvent?
    public private(set) var result: AIReceiveEvent?
    public private(set) var cancelledAt: Date?
    public private(set) var failure: String?
    public private(set) var resultReceivedAt: Date?
    public private(set) var resultOrder: Int?
    public private(set) var isUnread = false
    public private(set) var answeredByRequestID: UUID?
    public var contextReceived: Bool { acceptance != nil || result?.contextReceived == true }
    public var isAwaitingResult: Bool { sendAttemptedAt != nil && result == nil && state != .cancelled && state != .failed }

    public init(request: AIRequest) throws { try request.validate(); self.request = request }

    /// 外部入力より先に呼び、永続化する。クラッシュ時は送達不明として回収できる。
    public mutating func beginSending(at date: Date) throws {
        guard state == .prepared, sendAttemptedAt == nil else { throw AIError.invalidTransition }
        sendAttemptedAt = date; state = .deliveryUnknown
    }

    public mutating func submitted() throws {
        guard sendAttemptedAt != nil else { throw AIError.invalidTransition }
        if state == .deliveryUnknown { state = .submitted }
    }

    public mutating func failBeforeSending(_ reason: String) throws {
        guard state == .prepared, sendAttemptedAt == nil else { throw AIError.invalidTransition }
        try AIValidation.text(reason, limit: AILimits.bodyBytes, nonempty: true)
        state = .failed; failure = reason
    }

    public mutating func cancel(at date: Date) throws {
        guard result == nil, state != .failed else { throw AIError.invalidTransition }
        if cancelledAt == nil { cancelledAt = date }
        state = .cancelled
    }

    @discardableResult
    public mutating func receive(_ event: AIReceiveEvent, at date: Date, order: Int) throws -> Bool {
        try event.validate(for: request)
        guard sendAttemptedAt != nil else { throw AIError.invalidTransition }
        let previous = event.kind == .accept ? acceptance : result
        if let previous {
            guard previous.sameContent(as: event) else { throw AIError.conflict }
            return false
        }
        if event.kind == .accept {
            acceptance = event
            if result == nil, cancelledAt == nil { state = .accepted }
        } else {
            guard order > 0 else { throw AIError.invalid("event order") }
            result = event; resultReceivedAt = date; resultOrder = order
            isUnread = !(request.trigger == .scheduled && event.kind == .answered)
            if cancelledAt == nil {
                switch event.kind {
                case .answered: state = .answered
                case .needsInput: state = .needsInput
                case .failed: state = .failed
                case .accept: break
                }
            }
        }
        return true
    }

    public mutating func markRead() { isUnread = false }

    /// 失敗・取消に終わった返答は、同じ確認へ送り直せるよう参照を付け替える。
    /// 付け替えないと、失敗した返答の再送が「返答済み」として拒否される。
    mutating func linkFollowup(_ id: UUID, replacing: Bool = false) throws {
        guard state == .needsInput, answeredByRequestID == nil || replacing else { throw AIError.invalidTransition }
        answeredByRequestID = id
    }
    /// 確認質問が返答済みかどうか。**失敗・取消で終わった返答は返答済みとして数えない。**
    /// 送り直せる状態なのに「返答済み」と見えると、返答の導線も件数も消えてしまう。
    /// 表示・件数・自動送信の抑止はすべてこの判定を通す。
    public static func isAnswered(_ parent: AIQuestion, in questions: [AIQuestion]) -> Bool {
        guard let id = parent.answeredByRequestID else { return false }
        guard let child = questions.first(where: { $0.request.id == id }) else { return true }
        return child.state != .failed && child.state != .cancelled
    }

    /// state.json回収用。破損した保存状態を受信済み・送信可能として扱わない。
    public func validate() throws {
        try request.validate()
        if let acceptance { try acceptance.validate(for: request) }
        if let result { try result.validate(for: request) }
        guard acceptance == nil || acceptance?.kind == .accept,
              result == nil || result?.kind != .accept,
              result == nil || sendAttemptedAt != nil,
              acceptance == nil || sendAttemptedAt != nil,
              (result == nil) == (resultReceivedAt == nil), (result == nil) == (resultOrder == nil),
              resultOrder == nil || resultOrder! > 0,
              !isUnread || result != nil,
              [sendAttemptedAt, cancelledAt, resultReceivedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              answeredByRequestID == nil || result?.kind == .needsInput else { throw AIError.invalid("question state") }
        if cancelledAt != nil {
            guard state == .cancelled else { throw AIError.invalid("cancelled state") }
        } else if let result {
            let expected: AIQuestionState = result.kind == .answered ? .answered : result.kind == .needsInput ? .needsInput : .failed
            guard state == expected else { throw AIError.invalid("result state") }
        } else if acceptance != nil {
            guard state == .accepted else { throw AIError.invalid("accepted state") }
        } else if sendAttemptedAt != nil {
            guard state == .submitted || state == .deliveryUnknown else { throw AIError.invalid("send state") }
        } else {
            guard state == .prepared || (state == .failed && failure != nil) else { throw AIError.invalid("unsent state") }
        }
        if let failure {
            try AIValidation.text(failure, limit: AILimits.bodyBytes, nonempty: true)
            guard state == .failed, result == nil, sendAttemptedAt == nil else { throw AIError.invalid("failure") }
        }
    }
}

/// 回収済み集合は会議単位。取消・旧世代のresultも元の質問にだけ保存する。
public struct AIConversation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let meetingID: UUID
    public private(set) var questions: [AIQuestion] = []
    private var nextEventOrder = 1
    public init(meetingID: UUID) { self.meetingID = meetingID; schemaVersion = 1 }

    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", meetingID = "meeting_id", questions, nextEventOrder = "next_event_order" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        questions = try container.decode([AIQuestion].self, forKey: .questions)
        nextEventOrder = try container.decode(Int.self, forKey: .nextEventOrder)
        guard schemaVersion == 1, nextEventOrder > 0 else { throw AIError.invalid("conversation version/order") }
        var ids = Set<UUID>(), orders = Set<Int>()
        for (index, question) in questions.enumerated() {
            try question.validate()
            guard question.request.envelope.meetingID == meetingID, question.request.number == index + 1,
                  ids.insert(question.request.id).inserted else { throw AIError.mismatch }
            if let order = question.resultOrder {
                guard order < nextEventOrder, orders.insert(order).inserted else { throw AIError.invalid("event order") }
            }
            if let parentID = question.request.envelope.participant.inReplyToRequestID {
                guard let parent = questions.prefix(index).first(where: { $0.request.id == parentID }),
                      parent.result?.kind == .needsInput,
                      parent.result?.eventID == question.request.envelope.participant.inReplyToEventID,
                      // 確認への返答は元質問と同じ宛先へ返す。別のAIへ送ると、返答を見ていない
                      // 相手が答え、元質問まで返答済みになる。
                      parent.request.envelope.participant.profileSlot == question.request.envelope.participant.profileSlot,
                      // 付け替えられた古い返答は失敗・取消で終わっているものだけを認める。
                      question.sendAttemptedAt == nil || parent.answeredByRequestID == question.request.id
                        || question.state == .failed || question.state == .cancelled else { throw AIError.mismatch }
            }
            if let childID = question.answeredByRequestID {
                guard questions.contains(where: { $0.request.id == childID && $0.sendAttemptedAt != nil
                    && $0.request.envelope.participant.inReplyToRequestID == question.request.id }) else { throw AIError.mismatch }
            }
        }
    }

    public mutating func append(_ request: AIRequest) throws {
        guard request.envelope.meetingID == meetingID, request.number == questions.count + 1 else { throw AIError.mismatch }
        guard !questions.contains(where: { $0.request.id == request.id }) else { throw AIError.conflict }
        let question = try AIQuestion(request: request)
        if let parentID = request.envelope.participant.inReplyToRequestID {
            guard let index = questions.firstIndex(where: { $0.request.id == parentID }),
                  questions[index].result?.eventID == request.envelope.participant.inReplyToEventID,
                  // 確認への返答は元質問と同じ宛先へ返す。
                  questions[index].request.envelope.participant.profileSlot == request.envelope.participant.profileSlot,
                  questions[index].state == .needsInput,
                  !AIQuestion.isAnswered(questions[index], in: questions) else { throw AIError.mismatch }
        }
        questions.append(question)
    }

    public mutating func update(_ requestID: UUID, _ operation: (inout AIQuestion) throws -> Void) throws {
        guard let index = questions.firstIndex(where: { $0.request.id == requestID }) else { throw AIError.mismatch }
        var copy = questions[index]
        try operation(&copy)
        guard copy.request == questions[index].request else { throw AIError.mismatch }
        try copy.validate()
        // 準備だけ、起動失敗、未送信取消では確認を返答済みにしない。
        if questions[index].sendAttemptedAt == nil, copy.sendAttemptedAt != nil,
           let parentID = copy.request.envelope.participant.inReplyToRequestID {
            guard let parentIndex = questions.firstIndex(where: { $0.request.id == parentID }) else { throw AIError.mismatch }
            var parent = questions[parentIndex]
            try parent.linkFollowup(requestID, replacing: !AIQuestion.isAnswered(parent, in: questions))
            questions[parentIndex] = parent
        }
        questions[index] = copy
    }

    @discardableResult
    public mutating func receive(_ event: AIReceiveEvent, at date: Date) throws -> Bool {
        guard nextEventOrder < Int.max else { throw AIError.tooLarge }
        var inserted = false
        let order = nextEventOrder
        try update(event.requestID) { inserted = try $0.receive(event, at: date, order: order) }
        if inserted { nextEventOrder += 1 }
        return inserted
    }
}

/// プロバイダの完了フックに質問の確定結果を作らせない。
public enum AIConnectionStatus: Sendable { case idle, working, blocked, unknown, disconnected }
public enum AIReturnStatus {
    public static func isUnconfirmed(question: AIQuestion, connection: AIConnectionStatus, idleSince: Date?,
                                     now: Date, hasRunningBackgroundTasks: Bool, grace: TimeInterval = 5) -> Bool {
        guard question.isAwaitingResult, connection == .idle, !hasRunningBackgroundTasks,
              let idleSince, let sentAt = question.sendAttemptedAt,
              grace.isFinite, grace >= 0 else { return false }
        return now.timeIntervalSince(max(idleSince, sentAt)) >= grace
    }
}
