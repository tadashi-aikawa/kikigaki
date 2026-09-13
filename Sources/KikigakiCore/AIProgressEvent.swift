import Foundation

/// AIが段へ入ったことだけを伝える1回の自己申告。accept・replyの代わりにはならず、
/// 作業の完了・正しさ・文脈の受領を意味しない。1 requestの段ごとに最初の1件だけを採る。
public struct AIProgressEvent: Codable, Equatable, Sendable {
    /// 申告できる段。送信・読込はアプリとCLIの観測が正本なので申告を受けない。
    public enum Phase: String, Codable, CaseIterable, Sendable {
        case editing, replying
    }

    public static let totalRange = 1...999
    public let schemaVersion: Int
    public let eventID: String
    public let kind: String
    public let meetingID: UUID
    public let requestID: UUID
    public let sessionGeneration: Int
    public let snapshotID: UUID
    public let recordedAt: Date
    public let phase: Phase
    /// 分かっている場合の編集箇所の総数。進捗率ではないので、件数の消化は表示しない。
    /// 返答の申告には添えられない。
    public let total: Int?
    /// 段ごとに1ファイル。後から届く返答の申告が編集の申告を消さない。
    public var filename: String { "\(requestID.uuidString).progress.\(phase.rawValue).json" }
    public static func filename(requestID: UUID, phase: Phase) -> String {
        "\(requestID.uuidString).progress.\(phase.rawValue).json"
    }

    public init(request: AIRequest, phase: Phase, recordedAt: Date, total: Int? = nil) throws {
        schemaVersion = 1; kind = "progress"; self.phase = phase
        eventID = "\(request.id.uuidString)/progress/\(phase.rawValue)"; requestID = request.id
        meetingID = request.envelope.meetingID; snapshotID = request.envelope.snapshotID
        sessionGeneration = request.envelope.participant.sessionGeneration
        self.recordedAt = recordedAt; self.total = total
        try validate(for: request)
    }

    public func validate(for request: AIRequest) throws {
        try request.validate()
        guard schemaVersion == 1, kind == "progress",
              meetingID == request.envelope.meetingID, requestID == request.id,
              snapshotID == request.envelope.snapshotID,
              sessionGeneration == request.envelope.participant.sessionGeneration,
              eventID == "\(requestID.uuidString)/progress/\(phase.rawValue)",
              recordedAt.timeIntervalSince1970.isFinite else { throw AIError.mismatch }
        // 総数は編集の申告にしか意味がない。返答に添えられた数は受け取らない。
        if let total {
            guard phase == .editing, Self.totalRange.contains(total) else { throw AIError.invalid("progress total") }
        }
    }

    /// 再試行でCLIが採った保存時刻の差は同一性に含めない。
    public func sameContent(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion && kind == other.kind && eventID == other.eventID
            && meetingID == other.meetingID && requestID == other.requestID
            && snapshotID == other.snapshotID && sessionGeneration == other.sessionGeneration
            && phase == other.phase && total == other.total
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", kind, meetingID = "meeting_id"
        case requestID = "request_id", snapshotID = "snapshot_id", sessionGeneration = "session_generation"
        case recordedAt = "recorded_at", phase, total
    }
}
