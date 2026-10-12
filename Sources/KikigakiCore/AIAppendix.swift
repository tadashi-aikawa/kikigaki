import Foundation

/// 元の依頼を固定したまま送る追記。snapshotは送信時点の会話を保持する。
public struct AIAppendix: Codable, Equatable, Sendable {
    public let number: Int
    public let requestID: UUID
    public let snapshot: AIContextSnapshot
    public let question: String
    public let capturedAt: Date
    public let audioCutoffSeconds: Double
    public let tentativeTail: AITentativeTail?
    public let sentAt: Date
    public var forwardedRequestID: UUID?

    public init(number: Int, requestID: UUID, snapshot: AIContextSnapshot, question: String,
                capturedAt: Date, audioCutoffSeconds: Double, tentativeTail: AITentativeTail?, sentAt: Date) {
        self.number = number; self.requestID = requestID; self.snapshot = snapshot; self.question = question
        self.capturedAt = capturedAt; self.audioCutoffSeconds = audioCutoffSeconds
        self.tentativeTail = tentativeTail; self.sentAt = sentAt
    }

    public func validate(for request: AIRequest) throws {
        guard number > 0, requestID == request.id, snapshot.meetingID == request.envelope.meetingID,
              snapshot.streamID == request.envelope.participant.streamID,
              snapshot.sessionGeneration == request.envelope.participant.sessionGeneration,
              snapshot.readStartLine > 0, snapshot.readStartLine <= snapshot.lines.count + 1,
              audioCutoffSeconds.isFinite, audioCutoffSeconds >= 0,
              capturedAt.timeIntervalSince1970.isFinite, sentAt.timeIntervalSince1970.isFinite,
              !snapshot.lines.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) else { throw AIError.mismatch }
        try AIValidation.text(question, limit: AILimits.questionBytes)
        guard snapshot.fileURL.path == URL(fileURLWithPath: request.envelope.transcriptPath)
            .deletingLastPathComponent().appendingPathComponent(snapshot.id.uuidString + ".md").path else { throw AIError.mismatch }
        if let tail = tentativeTail {
            guard tail.status == "tentative", tail.startSeconds.isFinite, tail.endSeconds.isFinite,
                  tail.startSeconds >= 0, tail.endSeconds >= tail.startSeconds,
                  tail.endSeconds <= audioCutoffSeconds else { throw AIError.mismatch }
            try AIValidation.text(tail.text, limit: AILimits.questionBytes, nonempty: true)
        }
    }

    public func prompt(for request: AIRequest) throws -> String {
        try validate(for: request)
        let p = request.envelope.participant
        let participant = AIParticipantContext(streamID: p.streamID, requestID: p.requestID,
            sessionGeneration: p.sessionGeneration, participantName: p.participantName,
            cliPath: p.cliPath, sessionPath: p.sessionPath, requestToken: p.requestToken,
            question: question.isEmpty && p.trigger == .scheduled ? p.userQuestion : question,
            capturedAt: capturedAt, audioCutoffSeconds: audioCutoffSeconds, tentativeTail: tentativeTail,
            workAllowed: p.workAllowed, trigger: p.trigger, profile: p.profile, profileSlot: p.profileSlot,
            minutesPath: p.minutesPath, boardHeading: p.boardHeading)
        // 保存用snapshot.linesをペインへ載せず、通常のenvelopeと同じ範囲参照だけを渡す。
        let delivery = Delivery(number: number, context: try AIEnvelope(snapshot: snapshot, participant: participant),
            question: question, capturedAt: capturedAt, audioCutoffSeconds: audioCutoffSeconds, tentativeTail: tentativeTail)
        let json = String(decoding: try AIJSON.encode(delivery), as: UTF8.self).replacingOccurrences(of: "`", with: "\\u0060")
        return "$kikigaki\nKIKIGAKI_APPENDIX\n```json\n\(json)\n```\n"
            + "依頼 \(requestID.uuidString) への追記 \(number) です。新しい依頼ではありません。"
            + "context.transcript_path の read_start_line から read_line_count 行と、question、tentative_tail を読み、現在の作業に反映してください。"
            + "元の依頼の作業許可を守り、進行の段を戻さず、accept を重ねて返さないでください。"
            + "返事には反映した追記番号を --appendices 1,2 の形で添えてください。"
            + "元の依頼へ返送済みなら追記への返送・作業をせず、KIKIGAKIの新しい依頼を待ってください。\n"
            + "返送CLI: \(p.cliPath) / session: \(p.sessionPath) / request: \(requestID.uuidString)"
    }

    private struct Delivery: Encodable {
        let number: Int
        let context: AIEnvelope
        let question: String
        let capturedAt: Date
        let audioCutoffSeconds: Double
        let tentativeTail: AITentativeTail?
        enum CodingKeys: String, CodingKey {
            case number, context, question
            case capturedAt = "captured_at", audioCutoffSeconds = "audio_cutoff_seconds", tentativeTail = "tentative_tail"
        }
    }
}

extension AIQuestion {
    public var appendices: [AIAppendix] { savedAppendices ?? [] }
    public func hasApplied(_ appendix: AIAppendix) -> Bool {
        guard let result else { return false }
        return (result.appliedAppendices ?? []).contains(appendix.number) && appendix.sentAt <= result.recordedAt
    }
    public var unreflectedAppendices: [AIAppendix] {
        guard result != nil else { return [] }
        return appendices.filter { !hasApplied($0) && $0.forwardedRequestID == nil }
    }
    public mutating func addAppendix(_ appendix: AIAppendix) throws {
        try appendix.validate(for: request)
        guard sendAttemptedAt != nil, appendix.number == appendices.count + 1 else { throw AIError.invalidTransition }
        savedAppendices = appendices + [appendix]
    }
    public mutating func forwardAppendices(_ numbers: [Int], to id: UUID) throws {
        guard result != nil else { throw AIError.invalidTransition }
        savedAppendices = appendices.map { value in
            var copy = value
            if numbers.contains(copy.number), !hasApplied(copy), copy.forwardedRequestID == nil { copy.forwardedRequestID = id }
            return copy
        }
    }
}
