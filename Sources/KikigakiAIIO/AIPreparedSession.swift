import Foundation
import KikigakiCore

/// 会議に紐づかないAIセッション。KIKIGAKIが従来どおり起こすので、
/// フック・サンドボックス許可・返送コマンド許可はすべて付いた状態で待つ。
public struct AIPreparedSession: Codable, Equatable, Sendable {
    /// 紐づけ先。会議側の `ai/sessions/<slot>/<generation>.json` が正本で、こちらは履歴
    public struct Binding: Codable, Equatable, Sendable {
        public let meetingID: UUID
        public let profileSlot: Int
        public init(meetingID: UUID, profileSlot: Int) {
            self.meetingID = meetingID; self.profileSlot = profileSlot
        }
    }
    public let id: UUID
    public let profileSlot: Int
    public let profileName: String
    public let startedAt: Date
    /// 起動に使った設定の固定値。紐づけの等価性検証にこれを使う
    public let config: ResolvedAIConfig
    public let token: String
    /// フックの置き場。会議のものではないので、仮の会議IDで作った `.kikigaki-context` の枝を使う。
    /// 起動引数に焼き付くので、紐づけてもここは動かない。紐づけた会議はこの置き場を読みにいく
    public let contextRoot: URL
    public let contextMeetingID: UUID
    public var connection: AIHerdrConnection?
    public private(set) var bound: Binding?

    public init(id: UUID = UUID(), profileSlot: Int, profileName: String, startedAt: Date,
                config: ResolvedAIConfig, token: String, contextRoot: URL, contextMeetingID: UUID,
                connection: AIHerdrConnection? = nil, bound: Binding? = nil) {
        self.id = id; self.profileSlot = profileSlot; self.profileName = profileName
        self.startedAt = startedAt; self.config = config; self.token = token
        self.contextRoot = contextRoot; self.contextMeetingID = contextMeetingID
        self.connection = connection; self.bound = bound
    }
    /// この準備済みセッションのsession record。起動時のnotifyが指す先
    public var sessionURL: URL {
        contextRoot.appendingPathComponent(".kikigaki-context")
            .appendingPathComponent(contextMeetingID.uuidString)
            .appendingPathComponent("ai/sessions/1.json")
    }

    public var isUnbound: Bool { bound == nil }
    /// 一覧と紐づけに出せる状態。起動が終わって接続先が判っているものだけ
    public var isReady: Bool { isUnbound && connection != nil }

    /// 会議開始時に固定した設定と同じ設定で起こされたか。
    /// 準備してから設定を変えた場合に、別の設定のセッションを黙って紐づけないための判定。
    public func matches(_ other: ResolvedAIConfig) -> Bool { config == other }

    public mutating func bind(to meetingID: UUID, config: ResolvedAIConfig) throws {
        guard isUnbound else { throw AIError.conflict }
        guard connection != nil else { throw AIError.invalid("prepared session has no connection") }
        guard matches(config) else { throw AIError.mismatch }
        bound = Binding(meetingID: meetingID, profileSlot: profileSlot)
    }

    public func validate() throws {
        guard profileSlot > 0, config.slot == profileSlot,
              // 長さは設定の解析側でだけ見る。宛名から補った名前は制限の対象外。
              !profileName.trimmingCharacters(in: .whitespaces).isEmpty,
              !token.isEmpty, token.utf8.count <= 256,
              startedAt.timeIntervalSince1970.isFinite else { throw AIError.invalid("prepared session") }
        if let connection, connection.provider != config.cli { throw AIError.mismatch }
        // 紐づけ先の枠は起こしたときの枠と同じでなければならない。設定の等価性が枠も含むため。
        if let bound, bound.profileSlot != profileSlot { throw AIError.mismatch }
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileSlot = "profile_slot", profileName = "profile_name"
        case startedAt = "started_at", config, token, connection, bound
        case contextRoot = "context_root", contextMeetingID = "context_meeting_id"
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        profileSlot = try values.decode(Int.self, forKey: .profileSlot)
        profileName = try values.decode(String.self, forKey: .profileName)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        config = try values.decode(ResolvedAIConfig.self, forKey: .config)
        token = try values.decode(String.self, forKey: .token)
        contextRoot = try values.decode(URL.self, forKey: .contextRoot)
        contextMeetingID = try values.decode(UUID.self, forKey: .contextMeetingID)
        connection = try values.decodeIfPresent(AIHerdrConnection.self, forKey: .connection)
        bound = try values.decodeIfPresent(Binding.self, forKey: .bound)
        try validate()
    }
}

/// 準備済みセッションの台帳。会議の登録簿とは別ファイルにして、
/// 片方が壊れてももう片方の機能を止めない。値型なので保存はアプリ側が行う。
public struct AIPreparedLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public private(set) var sessions: [AIPreparedSession]

    public init(sessions: [AIPreparedSession] = []) {
        schemaVersion = Self.currentSchemaVersion; self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", sessions }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        sessions = try values.decode([AIPreparedSession].self, forKey: .sessions)
        guard schemaVersion == Self.currentSchemaVersion else { throw AIError.invalid("prepared ledger version") }
        var ids = Set<UUID>()
        for session in sessions {
            try session.validate()
            guard ids.insert(session.id).inserted else { throw AIError.conflict }
        }
    }

    /// 一覧に出す未紐づけ。古い順に並べる
    public var unbound: [AIPreparedSession] {
        sessions.filter(\.isUnbound).sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt }
    }

    /// そのプロファイルへ紐づけられる候補。古い順で、先頭が既定の選択になる。
    /// 設定が変わったものは候補にしない。
    public func available(for config: ResolvedAIConfig) -> [AIPreparedSession] {
        unbound.filter { $0.isReady && $0.profileSlot == config.slot && $0.matches(config) }
    }

    /// 同じ枠の未紐づけだが、準備後に設定が変わって使えないもの。一覧で理由を示すために分ける。
    public func stale(for config: ResolvedAIConfig) -> [AIPreparedSession] {
        unbound.filter { $0.profileSlot == config.slot && !$0.matches(config) }
    }

    public mutating func add(_ session: AIPreparedSession) throws {
        try session.validate()
        guard !sessions.contains(where: { $0.id == session.id }) else { throw AIError.conflict }
        sessions.append(session)
    }

    public mutating func update(_ id: UUID, _ body: (inout AIPreparedSession) throws -> Void) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw AIError.mismatch }
        var copy = sessions[index]
        try body(&copy)
        guard copy.id == id, copy.profileSlot == sessions[index].profileSlot,
              copy.config == sessions[index].config else { throw AIError.mismatch }
        try copy.validate()
        sessions[index] = copy
    }

    /// 会議側へ接続を書き終えてから呼ぶ。逆順にすると、台帳では使用済みなのに
    /// 会議側に接続が無い行が残る。
    public mutating func bind(_ id: UUID, to meetingID: UUID, config: ResolvedAIConfig) throws {
        try update(id) { try $0.bind(to: meetingID, config: config) }
    }

    public mutating func discard(_ id: UUID) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw AIError.mismatch }
        sessions.remove(at: index)
    }

    /// ペインが消えていた未紐づけを落とす。生存を確かめられなかったものは残す。
    /// 紐づけ済みは履歴なので、ペインの有無に関わらず残す。
    @discardableResult
    public mutating func removeMissing(alivePaneIDs: Set<String>) -> [UUID] {
        let removed = sessions.filter { session in
            guard session.isUnbound, let pane = session.connection?.paneID else { return false }
            return !alivePaneIDs.contains(pane)
        }.map(\.id)
        sessions.removeAll { removed.contains($0.id) }
        return removed
    }
}
