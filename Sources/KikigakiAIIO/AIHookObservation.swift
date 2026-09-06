import CryptoKit
import Foundation
import KikigakiCore

/// フックは診断用の観測。本文や入力メッセージを保存せず、質問のresultを生成しない。
public struct AIHookObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: String
    public let meetingID: UUID
    public let generation: Int
    public let provider: AIProvider
    public let sessionID: String?
    public let turnID: String?
    public let recordedAt: Date
    public let runningBackgroundTasks: Bool
    public var filename: String { "notify-\(eventID).json" }

    public init(payload: Data, session: AISessionRecord, now: Date) throws {
        guard payload.count <= AILimits.eventBytes,
              let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw AIError.invalid("hook payload") }
        func identifier(_ key: String) throws -> String? {
            guard let value = json[key] else { return nil }
            guard let text = value as? String, !text.isEmpty, text.utf8.count <= 512,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw AIError.invalid("hook identifier") }
            return text
        }
        schemaVersion = 1; meetingID = session.meetingID; generation = session.generation; provider = session.provider; recordedAt = now
        if provider == .codex {
            guard json["type"] as? String == "agent-turn-complete" else { throw AIError.invalid("hook type") }
            sessionID = try identifier("thread-id"); turnID = try identifier("turn-id"); runningBackgroundTasks = false
        } else {
            guard json["hook_event_name"] as? String == "Stop" else { throw AIError.invalid("hook type") }
            sessionID = try identifier("session_id"); turnID = try identifier("prompt_id")
            if let tasks = json["background_tasks"] {
                guard let tasks = tasks as? [[String: Any]] else { throw AIError.invalid("background tasks") }
                runningBackgroundTasks = tasks.contains { $0["status"] as? String == "running" }
            } else { runningBackgroundTasks = false }
        }
        // Codexはthread+turn、Claudeはpromptが複数Stopで共通になり得るためpayloadのdigest。
        let identity: Data
        if provider == .codex, let sessionID, let turnID { identity = try JSONEncoder().encode([provider.rawValue, sessionID, turnID]) }
        else { identity = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) }
        eventID = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    public func validate(session: AISessionRecord) throws {
        guard schemaVersion == 1, meetingID == session.meetingID, generation == session.generation, provider == session.provider,
              eventID.count == 64, eventID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              recordedAt.timeIntervalSince1970.isFinite else { throw AIError.mismatch }
    }
    public func sameContent(as other: Self) -> Bool {
        eventID == other.eventID && meetingID == other.meetingID && generation == other.generation && provider == other.provider
            && sessionID == other.sessionID && turnID == other.turnID && runningBackgroundTasks == other.runningBackgroundTasks
    }
}
