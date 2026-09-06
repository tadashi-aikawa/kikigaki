import Foundation

public enum AILimits {
    public static let eventBytes = 1_048_576
    public static let bodyBytes = 262_144
    public static let questionBytes = 32_768
}

public enum AIError: Error, Equatable {
    case invalid(String)
    case mismatch
    case conflict
    case invalidTransition
    case unsafeFile
    case tooLarge
}

enum AIValidation {
    static func singleLine(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
    }
    static func absolutePath(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") }
    static func text(_ value: String, limit: Int, nonempty: Bool = false) throws {
        guard value.utf8.count <= limit else { throw AIError.tooLarge }
        guard !value.contains("\0"), !nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalid("text")
        }
    }
}

/// wire JSONの日時はISO8601。フックの生JSONはadapterで別に解釈する。
public enum AIJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw AIError.invalid("date") }
            return date
        }
        return try decoder.decode(type, from: data)
    }
}

public struct AITentativeTail: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let status: String
    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text; self.startSeconds = startSeconds; self.endSeconds = endSeconds; status = "tentative"
    }
    enum CodingKeys: String, CodingKey {
        case text, status
        case startSeconds = "start_seconds", endSeconds = "end_seconds"
    }
}

public struct AIParticipantContext: Codable, Equatable, Sendable {
    public enum QuestionSource: String, Codable, Sendable { case voice, typed }
    public let schemaVersion: Int
    public let mode: String
    public let streamID: UUID
    public let requestID: UUID
    public let sessionGeneration: Int
    public let participantName: String
    public let cliPath: String
    public let sessionPath: String
    public let requestToken: String
    public let question: String
    public let questionSource: QuestionSource
    public let workAllowed: Bool
    public let capturedAt: Date
    public let audioCutoffSeconds: Double
    public let tentativeTail: AITentativeTail?
    public let inReplyToRequestID: UUID?
    public let inReplyToEventID: String?

    public init(streamID: UUID, requestID: UUID, sessionGeneration: Int, participantName: String,
                cliPath: String, sessionPath: String, requestToken: String, question: String,
                capturedAt: Date, audioCutoffSeconds: Double, tentativeTail: AITentativeTail? = nil,
                inReplyToRequestID: UUID? = nil, inReplyToEventID: String? = nil, workAllowed: Bool = true) {
        schemaVersion = 1; mode = "meeting"; self.streamID = streamID; self.requestID = requestID
        self.sessionGeneration = sessionGeneration; self.participantName = participantName
        self.cliPath = cliPath; self.sessionPath = sessionPath; self.requestToken = requestToken
        self.question = question; questionSource = question.isEmpty ? .voice : .typed
        self.workAllowed = workAllowed
        self.capturedAt = capturedAt; self.audioCutoffSeconds = audioCutoffSeconds
        self.tentativeTail = tentativeTail; self.inReplyToRequestID = inReplyToRequestID
        self.inReplyToEventID = inReplyToEventID
    }

    public func validate() throws {
        guard schemaVersion == 1, mode == "meeting", sessionGeneration > 0,
              AIValidation.singleLine(participantName), AIValidation.absolutePath(cliPath),
              AIValidation.absolutePath(sessionPath), AIValidation.singleLine(requestToken),
              requestToken.utf8.count <= 256, audioCutoffSeconds.isFinite, audioCutoffSeconds >= 0,
              capturedAt.timeIntervalSince1970.isFinite,
              questionSource == (question.isEmpty ? .voice : .typed),
              (inReplyToRequestID == nil) == (inReplyToEventID == nil) else { throw AIError.invalid("participant") }
        try AIValidation.text(question, limit: AILimits.questionBytes)
        if let id = inReplyToRequestID, inReplyToEventID != "\(id.uuidString)/result" {
            throw AIError.invalid("in_reply_to_event_id")
        }
        if let tail = tentativeTail {
            guard tail.status == "tentative", tail.startSeconds.isFinite, tail.endSeconds.isFinite,
                  tail.startSeconds >= 0, tail.endSeconds >= tail.startSeconds,
                  tail.endSeconds <= audioCutoffSeconds else { throw AIError.invalid("tentative_tail") }
            try AIValidation.text(tail.text, limit: AILimits.questionBytes, nonempty: true)
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", mode, streamID = "stream_id", requestID = "request_id"
        case sessionGeneration = "session_generation", participantName = "participant_name"
        case cliPath = "cli_path", sessionPath = "session_path", requestToken = "request_token"
        case question, questionSource = "question_source", capturedAt = "captured_at", workAllowed = "work_allowed"
        case audioCutoffSeconds = "audio_cutoff_seconds", tentativeTail = "tentative_tail"
        case inReplyToRequestID = "in_reply_to_request_id", inReplyToEventID = "in_reply_to_event_id"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        mode = try values.decode(String.self, forKey: .mode)
        streamID = try values.decode(UUID.self, forKey: .streamID)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        sessionGeneration = try values.decode(Int.self, forKey: .sessionGeneration)
        participantName = try values.decode(String.self, forKey: .participantName)
        cliPath = try values.decode(String.self, forKey: .cliPath)
        sessionPath = try values.decode(String.self, forKey: .sessionPath)
        requestToken = try values.decode(String.self, forKey: .requestToken)
        question = try values.decode(String.self, forKey: .question)
        questionSource = try values.decode(QuestionSource.self, forKey: .questionSource)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        audioCutoffSeconds = try values.decode(Double.self, forKey: .audioCutoffSeconds)
        tentativeTail = try values.decodeIfPresent(AITentativeTail.self, forKey: .tentativeTail)
        inReplyToRequestID = try values.decodeIfPresent(UUID.self, forKey: .inReplyToRequestID)
        inReplyToEventID = try values.decodeIfPresent(String.self, forKey: .inReplyToEventID)
        // 未指定だけ旧契約のtrue。null・文字列・数値を作業許可へ読み替えない。
        workAllowed = try values.contains(.workAllowed) ? values.decode(Bool.self, forKey: .workAllowed) : true
        try validate()
    }
}

public struct AIEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let meetingID: UUID
    public let snapshotID: UUID
    public let sequence: Int
    public let previousSnapshotID: UUID?
    public let kind: AIContextSnapshot.Kind
    public let transcriptPath: String
    public let readStartLine: Int
    public let readLineCount: Int
    public let totalLineCount: Int
    public let participant: AIParticipantContext

    public init(snapshot: AIContextSnapshot, participant: AIParticipantContext) throws {
        guard snapshot.readStartLine >= 1, snapshot.readStartLine <= snapshot.lines.count + 1,
              !snapshot.lines.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) else {
            throw AIError.invalid("snapshot range")
        }
        guard snapshot.streamID == participant.streamID, snapshot.sessionGeneration == participant.sessionGeneration else {
            throw AIError.mismatch
        }
        schemaVersion = 1; meetingID = snapshot.meetingID; snapshotID = snapshot.id
        sequence = snapshot.sequence; previousSnapshotID = snapshot.previousSnapshotID; kind = snapshot.kind
        transcriptPath = snapshot.fileURL.path; readStartLine = snapshot.readStartLine
        readLineCount = snapshot.readLineCount; totalLineCount = snapshot.lines.count; self.participant = participant
        try validate()
    }

    public func validate() throws {
        try participant.validate()
        guard schemaVersion == 1, sequence > 0, AIValidation.absolutePath(transcriptPath),
              totalLineCount >= 0, totalLineCount < Int.max, readStartLine >= 1,
              readStartLine <= totalLineCount + 1, readLineCount >= 0,
              readLineCount == totalLineCount - (readStartLine - 1),
              kind != .full || (readStartLine == 1 && previousSnapshotID == nil),
              kind != .update || (previousSnapshotID != nil && previousSnapshotID != snapshotID) else {
            throw AIError.invalid("envelope")
        }
        guard totalLineCount > 0 || participant.questionSource == .typed || participant.tentativeTail != nil else {
            throw AIError.invalid("empty question and context")
        }
        let snapshotURL = URL(fileURLWithPath: transcriptPath)
        let meetingURL = snapshotURL.deletingLastPathComponent()
        guard snapshotURL.lastPathComponent == snapshotID.uuidString + ".md",
              meetingURL.lastPathComponent == meetingID.uuidString,
              meetingURL.deletingLastPathComponent().lastPathComponent == ".kikigaki-context",
              transcriptPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              participant.sessionPath == meetingURL.appendingPathComponent("ai/sessions/\(participant.sessionGeneration).json").path else {
            throw AIError.invalid("context paths")
        }
    }

    public func validatePaths(outputDirectory: URL) throws {
        try validate()
        guard outputDirectory.isFileURL,
              transcriptPath == outputDirectory.appendingPathComponent(".kikigaki-context")
                .appendingPathComponent(meetingID.uuidString).appendingPathComponent(snapshotID.uuidString + ".md").path else {
            throw AIError.mismatch
        }
    }

    public func prompt(address: String = "迅雷へ", extraPrompt: String = "") throws -> String {
        try validate()
        guard AIValidation.singleLine(address) else { throw AIError.invalid("address") }
        try AIValidation.text(extraPrompt, limit: AILimits.questionBytes)
        let json = String(decoding: try AIJSON.encode(self), as: UTF8.self).replacingOccurrences(of: "`", with: "\\u0060")
        return "$kikigaki\n\(address)\n\nKIKIGAKI_CONTEXT\n```json\n\(json)\n```"
            + (extraPrompt.isEmpty ? "" : "\n\n追加プロンプト:\n\(extraPrompt)")
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", meetingID = "meeting_id", snapshotID = "snapshot_id", sequence
        case previousSnapshotID = "previous_snapshot_id", kind, transcriptPath = "transcript_path"
        case readStartLine = "read_start_line", readLineCount = "read_line_count", totalLineCount = "total_line_count", participant
    }
}

public struct AIContextSnapshot: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case full, update }
    public let id: UUID
    public let meetingID: UUID
    public let streamID: UUID
    public let sessionGeneration: Int
    public let sequence: Int
    public let previousSnapshotID: UUID?
    public let kind: Kind
    public let fileURL: URL
    public let readStartLine: Int
    public let lines: [String]
    public var readLineCount: Int {
        guard readStartLine >= 1, readStartLine <= lines.count + 1 else { return 0 }
        return lines.count - (readStartLine - 1)
    }
    public var contents: Data { Data((lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n").utf8) }

    /// 指定範囲の端の時刻だけを採る。欠損時に範囲内の別の行で補わない。
    public var timeRange: AIContextTimeRange? {
        guard readLineCount > 0,
              let first = AIContextTimeRange.timestamp(lines[readStartLine - 1]),
              let last = AIContextTimeRange.timestamp(lines[lines.count - 1]) else { return nil }
        return AIContextTimeRange(start: first, end: last)
    }
}

public struct AIContextTimeRange: Codable, Equatable, Sendable {
    public let start: String
    public let end: String

    static func timestamp(_ line: String) -> String? {
        let bytes = Array(line.utf8.prefix(10))
        guard bytes.count == 10, bytes[0] == 91, bytes[9] == 93,
              bytes[3] == 58, bytes[6] == 58,
              [1, 2, 4, 5, 7, 8].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        let numbers: [Int] = [1, 4, 7].map { index in
            let tens = Int(bytes[index]) - 48
            let units = Int(bytes[index + 1]) - 48
            return tens * 10 + units
        }
        guard numbers[0] < 24, numbers[1] < 60, numbers[2] < 60 else { return nil }
        return String(decoding: bytes[1...8], as: UTF8.self)
    }

    func validate() throws {
        guard start.utf8.count == 8, end.utf8.count == 8,
              Self.timestamp("[\(start)]") != nil, Self.timestamp("[\(end)]") != nil else {
            throw AIError.invalid("context time range")
        }
    }
}

/// 手動HandoffHistoryとは独立。prepareは番号を予約し、acknowledgeだけが受領基準を進める。
/// ファイル保存・送信に失敗しても予約番号を再利用しない。新世代は新しい値として作る。
public struct AIStreamHistory: Sendable {
    public let meetingID: UUID
    public let streamID: UUID
    public let sessionGeneration: Int
    public private(set) var received: AIContextSnapshot?
    public private(set) var lastPrepared: AIContextSnapshot?
    private var issued: [UUID: AIContextSnapshot] = [:]

    public init(meetingID: UUID, streamID: UUID = UUID(), sessionGeneration: Int = 1) throws {
        guard sessionGeneration > 0 else { throw AIError.invalid("generation") }
        self.meetingID = meetingID; self.streamID = streamID; self.sessionGeneration = sessionGeneration
    }

    public mutating func prepare(lines: [String], outputDirectory: URL, snapshotID: UUID = UUID(), full: Bool = false) throws -> AIContextSnapshot {
        guard outputDirectory.isFileURL, !lines.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) else {
            throw AIError.invalid("snapshot")
        }
        if !full, let received, lastPrepared?.id == received.id, lines == received.lines { return received }
        guard issued[snapshotID] == nil, (lastPrepared?.sequence ?? 0) < Int.max else { throw AIError.conflict }
        let isFull = full || received == nil || lastPrepared?.id != received?.id
        var common = 0
        if !isFull, let received {
            while common < min(lines.count, received.lines.count), lines[common] == received.lines[common] { common += 1 }
        }
        let snapshot = AIContextSnapshot(id: snapshotID, meetingID: meetingID, streamID: streamID,
            sessionGeneration: sessionGeneration, sequence: (lastPrepared?.sequence ?? 0) + 1,
            previousSnapshotID: isFull ? nil : received?.id, kind: isFull ? .full : .update,
            fileURL: outputDirectory.appendingPathComponent(".kikigaki-context").appendingPathComponent(meetingID.uuidString)
                .appendingPathComponent(snapshotID.uuidString + ".md"), readStartLine: common + 1, lines: lines)
        issued[snapshotID] = snapshot; lastPrepared = snapshot
        return snapshot
    }

    public mutating func acknowledge(snapshotID: UUID, streamID: UUID, sessionGeneration: Int) throws {
        guard streamID == self.streamID, sessionGeneration == self.sessionGeneration,
              let snapshot = issued[snapshotID] else { throw AIError.mismatch }
        if snapshot.sequence > (received?.sequence ?? 0) { received = snapshot }
    }
}
