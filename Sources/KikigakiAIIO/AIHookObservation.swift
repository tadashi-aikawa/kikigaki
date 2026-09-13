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
    /// 編集系ツールの呼び出し直前の観測だけに入る。旧版の観測には無いので省略可にする。
    public let toolName: String?
    public var filename: String { "notify-\(eventID).json" }
    /// 編集の補助観測。到達の根拠にできるのは編集だけで、受領・返答の根拠にはしない。
    public var observesEditing: Bool { toolName != nil }
    /// Claudeのフックで編集を観測する対象。ここに無いツールは段を進めない。
    public static let editingTools = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

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
            toolName = nil
        } else if json["hook_event_name"] as? String == "PreToolUse" {
            // 編集系ツールの呼び出し直前。matcherを絞っていても、届いた種別をここで確かめる。
            guard let tool = try identifier("tool_name"), Self.editingTools.contains(tool) else { throw AIError.invalid("hook tool") }
            sessionID = try identifier("session_id"); turnID = nil
            runningBackgroundTasks = false; toolName = tool
        } else {
            guard json["hook_event_name"] as? String == "Stop" else { throw AIError.invalid("hook type") }
            sessionID = try identifier("session_id"); turnID = try identifier("prompt_id")
            if let tasks = json["background_tasks"] {
                guard let tasks = tasks as? [[String: Any]] else { throw AIError.invalid("background tasks") }
                runningBackgroundTasks = tasks.contains { $0["status"] as? String == "running" }
            } else { runningBackgroundTasks = false }
            toolName = nil
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
              recordedAt.timeIntervalSince1970.isFinite,
              toolName == nil || (provider == .claude && Self.editingTools.contains(toolName!)) else { throw AIError.mismatch }
    }
    public func sameContent(as other: Self) -> Bool {
        eventID == other.eventID && meetingID == other.meetingID && generation == other.generation && provider == other.provider
            && sessionID == other.sessionID && turnID == other.turnID && runningBackgroundTasks == other.runningBackgroundTasks
            && toolName == other.toolName
    }
}
