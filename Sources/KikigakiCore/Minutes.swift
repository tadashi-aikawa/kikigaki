import Foundation

/// 保存済みrequestの復号にも使う版1の契約。後から厳格化すると会議全体が読めなくなる。
/// ファイルの実在やsymlink先を同一性へ混ぜず、通知の再試行はSwiftの文字列としての等価性で扱う。
public enum MinutesPath {
    public static let maximumBytes = 1024
    public static let bodyBytes = 4 * 1024 * 1024

    public static func validate(_ path: String) throws {
        guard path.utf8.count <= maximumBytes else { throw AIError.tooLarge }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), parts.count > 1, parts.first == "",
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !isManagedComponent($0) }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
              (path as NSString).pathExtension.lowercased() == "md" else { throw AIError.invalid("minutes path") }
    }
    private static func isManagedComponent(_ part: Substring) -> Bool {
        part.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 } == Array(".kikigaki-context".utf8)
    }
}

/// accept/resultと独立した1 request・1パスの通知。作業完了や文脈受領を意味しない。
public struct AIMinutesEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: String
    public let kind: String
    public let meetingID: UUID
    public let requestID: UUID
    public let sessionGeneration: Int
    public let snapshotID: UUID
    public let recordedAt: Date
    public let minutesPath: String
    public var filename: String { "\(requestID.uuidString).minutes.json" }
    public var position: MinutesEventPosition { .init(recordedAt: recordedAt, eventID: eventID) }

    public init(request: AIRequest, path: String, recordedAt: Date) throws {
        schemaVersion = 1; kind = "minutes"
        eventID = "\(request.id.uuidString)/minutes"; requestID = request.id
        meetingID = request.envelope.meetingID; snapshotID = request.envelope.snapshotID
        sessionGeneration = request.envelope.participant.sessionGeneration
        self.recordedAt = recordedAt; minutesPath = path
        try validate(for: request)
    }

    public func validate(for request: AIRequest) throws {
        try request.validate()
        guard schemaVersion == 1, kind == "minutes", meetingID == request.envelope.meetingID,
              requestID == request.id, snapshotID == request.envelope.snapshotID,
              sessionGeneration == request.envelope.participant.sessionGeneration,
              eventID == "\(requestID.uuidString)/minutes", recordedAt.timeIntervalSince1970.isFinite else { throw AIError.mismatch }
        try MinutesPath.validate(minutesPath)
    }

    public func sameContent(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion && kind == other.kind && eventID == other.eventID
            && meetingID == other.meetingID && requestID == other.requestID
            && snapshotID == other.snapshotID && sessionGeneration == other.sessionGeneration
            && minutesPath == other.minutesPath
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", kind, meetingID = "meeting_id"
        case requestID = "request_id", snapshotID = "snapshot_id", sessionGeneration = "session_generation"
        case recordedAt = "recorded_at", minutesPath = "minutes_path"
    }
}

public struct MinutesEventPosition: Codable, Equatable, Comparable, Sendable {
    public let recordedAt: Date
    public let eventID: String
    public init(recordedAt: Date, eventID: String) { self.recordedAt = recordedAt; self.eventID = eventID }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.recordedAt == rhs.recordedAt ? lhs.eventID < rhs.eventID : lhs.recordedAt < rhs.recordedAt
    }
    public func validate() throws {
        let parts = eventID.split(separator: "/", omittingEmptySubsequences: false)
        guard recordedAt.timeIntervalSince1970.isFinite, parts.count == 2, parts[1] == "minutes",
              let id = UUID(uuidString: String(parts[0])), id.uuidString == parts[0] else { throw AIError.invalid("minutes position") }
    }
    enum CodingKeys: String, CodingKey { case recordedAt = "recorded_at", eventID = "event_id" }
}

/// 表示対象と人が指定した書き先を分離する。AIの通知で別のAIの書き先を変えてはならない。
public struct MinutesState: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case human, ai }
    public let schemaVersion: Int
    public let meetingID: UUID
    public private(set) var minutesPath: String?
    public private(set) var humanMinutesPath: String?
    public private(set) var targetChangedAt: Date?
    public private(set) var targetSource: Source?
    public private(set) var lastEvent: MinutesEventPosition?
    public private(set) var revision: Int

    public init(meetingID: UUID) { schemaVersion = 1; self.meetingID = meetingID; revision = 0 }

    public mutating func select(_ path: String?, at date: Date) throws {
        if let path { try MinutesPath.validate(path) }
        guard date.timeIntervalSince1970.isFinite else { throw AIError.invalid("minutes date") }
        minutesPath = path; humanMinutesPath = path
        targetSource = path == nil ? nil : .human; targetChangedAt = date
    }

    /// 到達点以下は再適用せず、人の操作より古い通知は回収だけ行う。
    /// 時刻が同じ通知同士はID順、人の操作と同時刻の通知は裁定どおり適用する。
    @discardableResult
    public mutating func receive(_ event: AIMinutesEvent, for request: AIRequest, changeTarget: Bool = true) throws -> Bool {
        try event.validate(for: request)
        guard event.meetingID == meetingID else { throw AIError.mismatch }
        guard lastEvent.map({ $0 < event.position }) ?? true else { return false }
        lastEvent = event.position
        if changeTarget && (targetChangedAt.map({ event.recordedAt >= $0 }) ?? true) {
            minutesPath = event.minutesPath; targetSource = .ai; targetChangedAt = event.recordedAt
        }
        return true
    }

    public mutating func advanceRevision() throws {
        guard revision < Int.max else { throw AIError.tooLarge }
        revision += 1
    }

    public func validate() throws {
        guard schemaVersion == 1, revision >= 0,
              (minutesPath == nil) == (targetSource == nil),
              minutesPath == nil || targetChangedAt != nil,
              humanMinutesPath == nil || targetChangedAt != nil,
              targetSource != .human || minutesPath == humanMinutesPath,
              targetChangedAt?.timeIntervalSince1970.isFinite ?? true else { throw AIError.invalid("minutes state") }
        if let minutesPath { try MinutesPath.validate(minutesPath) }
        if let humanMinutesPath { try MinutesPath.validate(humanMinutesPath) }
        try lastEvent?.validate()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", meetingID = "meeting_id", minutesPath = "minutes_path"
        case humanMinutesPath = "human_minutes_path", targetChangedAt = "target_changed_at"
        case targetSource = "target_source", lastEvent = "last_event", revision
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        meetingID = try values.decode(UUID.self, forKey: .meetingID)
        minutesPath = try values.contains(.minutesPath) ? values.decode(String.self, forKey: .minutesPath) : nil
        humanMinutesPath = try values.contains(.humanMinutesPath) ? values.decode(String.self, forKey: .humanMinutesPath) : nil
        targetChangedAt = try values.contains(.targetChangedAt) ? values.decode(Date.self, forKey: .targetChangedAt) : nil
        targetSource = try values.contains(.targetSource) ? values.decode(Source.self, forKey: .targetSource) : nil
        lastEvent = try values.contains(.lastEvent) ? values.decode(MinutesEventPosition.self, forKey: .lastEvent) : nil
        revision = try values.decode(Int.self, forKey: .revision)
        try validate()
    }
}
