import Foundation

/// 送信時に固定した未回答の確認。別会議のIDを返送の対象へ混ぜない。
public struct AIUnansweredQuestion: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let eventID: String
    public let number: Int
    public let body: String
    public let askedAt: Date
    init(question: AIQuestion) {
        requestID = question.request.id; eventID = question.result!.eventID
        number = question.request.number; body = question.result!.body!; askedAt = question.result!.recordedAt
    }
    public func validate() throws {
        guard eventID == "\(requestID.uuidString)/result", number > 0,
              askedAt.timeIntervalSince1970.isFinite else { throw AIError.mismatch }
        try AIValidation.text(body, limit: AILimits.bodyBytes, nonempty: true)
    }
    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", eventID = "event_id", number, body, askedAt = "asked_at"
    }
}

public struct AIAnswerEvidence: Codable, Equatable, Sendable {
    public let speaker: String
    public let time: String
    public let quote: String
    public init(speaker: String, time: String, quote: String) throws {
        self.speaker = speaker; self.time = time; self.quote = quote
        try validate()
    }
    public func validate() throws {
        guard AIValidation.singleLine(speaker), speaker.utf8.count <= 256,
              AIContextTimeRange.timestamp("[\(time)]") == time, time.utf8.count == 8,
              AIValidation.singleLine(quote) else { throw AIError.invalid("answer evidence") }
        try AIValidation.text(quote, limit: 4096, nonempty: true)
    }
    public var answerLine: String {
        let short = quote.count > 80 ? String(quote.prefix(80)) + "…" : quote
        return "答え: \(speaker) \(time)「\(short)」"
    }
}

/// resultを上書きせず、確認の解消だけを独立したイベントで記録する。
public struct AIResolutionEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: String
    public let meetingID: UUID
    public let requestID: UUID
    public let sessionGeneration: Int
    public let snapshotID: UUID
    public let questionRequestID: UUID
    public let questionEventID: String
    public let recordedAt: Date
    public let evidence: AIAnswerEvidence
    public var filename: String { "\(questionRequestID.uuidString).resolve.json" }
    public init(request: AIRequest, questionRequestID: UUID, evidence: AIAnswerEvidence, recordedAt: Date) throws {
        schemaVersion = 1; meetingID = request.envelope.meetingID; requestID = request.id
        sessionGeneration = request.envelope.participant.sessionGeneration; snapshotID = request.envelope.snapshotID
        self.questionRequestID = questionRequestID; questionEventID = "\(questionRequestID.uuidString)/result"
        eventID = "\(questionRequestID.uuidString)/resolve"
        self.evidence = evidence; self.recordedAt = recordedAt
        try validate(for: request)
    }
    public func validate(for request: AIRequest) throws {
        try request.validate(); try evidence.validate()
        guard schemaVersion == 1, meetingID == request.envelope.meetingID, requestID == request.id,
              sessionGeneration == request.envelope.participant.sessionGeneration, snapshotID == request.envelope.snapshotID,
              eventID == "\(questionRequestID.uuidString)/resolve", recordedAt.timeIntervalSince1970.isFinite,
              request.envelope.participant.unansweredQuestions.contains(where: {
                  $0.requestID == questionRequestID && $0.eventID == questionEventID
              }) else { throw AIError.mismatch }
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", meetingID = "meeting_id", requestID = "request_id"
        case sessionGeneration = "session_generation", snapshotID = "snapshot_id"
        case questionRequestID = "question_request_id", questionEventID = "question_event_id", recordedAt = "recorded_at", evidence
    }
}

public struct AIQuestionResolution: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case voice, manual }
    public let source: Source
    public let recordedAt: Date
    public let event: AIResolutionEvent?
    public init(source: Source, recordedAt: Date, event: AIResolutionEvent? = nil) {
        self.source = source; self.recordedAt = recordedAt; self.event = event
    }
    public var label: String { source == .voice ? "声で返答済み" : "返答済み" }
}

extension AIConversation {
    public var unansweredQuestions: [AIUnansweredQuestion] {
        questions.filter { $0.state == .needsInput && !AIQuestion.isAnswered($0, in: questions) }
            .map(AIUnansweredQuestion.init)
    }

    @discardableResult
    public mutating func receive(_ event: AIResolutionEvent) throws -> Bool {
        guard let sender = questions.first(where: { $0.request.id == event.requestID }), sender.sendAttemptedAt != nil,
              let target = questions.first(where: { $0.request.id == event.questionRequestID }) else { throw AIError.mismatch }
        try event.validate(for: sender.request)
        guard meetingID == event.meetingID, target.result?.eventID == event.questionEventID else { throw AIError.mismatch }
        if target.resolution?.source == .voice { return false }
        guard target.state == .needsInput, !AIQuestion.isAnswered(target, in: questions) else { throw AIError.invalidTransition }
        try update(target.request.id) { try $0.resolve(.init(source: .voice, recordedAt: event.recordedAt, event: event)) }
        return true
    }

    public mutating func resolveManually(_ id: UUID, at date: Date) throws {
        guard let target = questions.first(where: { $0.request.id == id }), target.state == .needsInput,
              !AIQuestion.isAnswered(target, in: questions) else { throw AIError.invalidTransition }
        try update(id) { try $0.resolve(.init(source: .manual, recordedAt: date)) }
    }
}
