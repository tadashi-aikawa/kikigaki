import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO

@Suite struct AIPreparedSessionTests {
    private let home = URL(fileURLWithPath: "/home/person")
    private let base = Date(timeIntervalSince1970: 1_788_759_600)

    private func profile(_ toml: String, slot: Int = 1) throws -> ResolvedAIConfig {
        let profiles = ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: home).aiProfiles
        return try #require(profiles.first { $0.slot == slot })
    }
    private func minutes(effort: String = "high") throws -> ResolvedAIConfig {
        try profile("[[ai]]\nname = \"議事録\"\ncli = \"claude\"\neffort = \"\(effort)\"")
    }
    private func session(_ config: ResolvedAIConfig, at offset: Double = 0, pane: String = "w1:p1",
                         id: UUID = UUID()) -> AIPreparedSession {
        AIPreparedSession(id: id, profileSlot: config.slot, profileName: config.name,
            startedAt: base.addingTimeInterval(offset), config: config, token: "hook-secret",
            contextRoot: URL(fileURLWithPath: "/out"), contextMeetingID: UUID(),
            connection: .init(workspaceID: String(pane.prefix(2)), paneID: pane, provider: config.cli))
    }

    // MARK: - 状態

    @Test func 未紐づけは古い順に並び紐づけると一覧から外れる() throws {
        let config = try minutes()
        let old = session(config, at: 0, pane: "w1:p1")
        let recent = session(config, at: 600, pane: "w2:p1")
        var ledger = AIPreparedLedger()
        try ledger.add(recent)
        try ledger.add(old)
        #expect(ledger.unbound.map(\.id) == [old.id, recent.id])
        // 既定の選択は最も古い1件。連続する会議では用意した順に使う。
        #expect(ledger.available(for: config).first?.id == old.id)

        let meeting = UUID()
        try ledger.bind(old.id, to: meeting, config: config)
        #expect(ledger.unbound.map(\.id) == [recent.id])
        #expect(ledger.sessions.count == 2)
        let boundRow = try #require(ledger.sessions.first { $0.id == old.id })
        #expect(boundRow.bound == .init(meetingID: meeting, profileSlot: 1) && !boundRow.isUnbound)
    }

    @Test func 二重の紐づけと接続の無いものを拒否する() throws {
        let config = try minutes()
        var ledger = AIPreparedLedger()
        let ready = session(config)
        try ledger.add(ready)
        try ledger.bind(ready.id, to: UUID(), config: config)
        #expect(throws: AIError.conflict) { try ledger.bind(ready.id, to: UUID(), config: config) }

        var pending = session(config, pane: "w3:p1")
        pending.connection = nil
        var second = AIPreparedLedger()
        try second.add(pending)
        // 起動が終わっていないものは一覧にも候補にも出さない。
        #expect(second.unbound.count == 1 && second.available(for: config).isEmpty)
        #expect(throws: AIError.self) { try second.bind(pending.id, to: UUID(), config: config) }
    }

    @Test func 同じidの二重登録と知らないidの操作を拒否する() throws {
        let config = try minutes()
        let one = session(config)
        var ledger = AIPreparedLedger()
        try ledger.add(one)
        #expect(throws: AIError.conflict) { try ledger.add(one) }
        #expect(throws: AIError.mismatch) { try ledger.discard(UUID()) }
        #expect(throws: AIError.mismatch) { try ledger.bind(UUID(), to: UUID(), config: config) }
        try ledger.discard(one.id)
        #expect(ledger.sessions.isEmpty)
    }

    // MARK: - 設定の等価性

    @Test func 準備後に設定が変わったものは候補にせず理由を分けて出す() throws {
        let prepared = try minutes(effort: "high")
        var ledger = AIPreparedLedger()
        try ledger.add(session(prepared))
        // 会議開始時に固定した設定が変わっていれば、黙って紐づけない。
        let changed = try minutes(effort: "max")
        #expect(ledger.available(for: changed).isEmpty)
        #expect(ledger.stale(for: changed).count == 1)
        #expect(throws: AIError.mismatch) {
            try ledger.bind(ledger.sessions[0].id, to: UUID(), config: changed)
        }
        // 同じ設定なら通る。
        #expect(ledger.available(for: prepared).count == 1)
        #expect(ledger.stale(for: prepared).isEmpty)
    }

    @Test func 別の枠のプロファイルは候補にしない() throws {
        let list = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"

        [[ai]]
        name = "相談"
        """), home: home).aiProfiles
        var ledger = AIPreparedLedger()
        try ledger.add(session(list[0]))
        #expect(ledger.available(for: list[0]).count == 1)
        #expect(ledger.available(for: list[1]).isEmpty && ledger.stale(for: list[1]).isEmpty)
    }

    // MARK: - 生存確認

    @Test func 消えたペインの未紐づけだけ落とす() throws {
        let config = try minutes()
        let alive = session(config, at: 0, pane: "w1:p1")
        let gone = session(config, at: 10, pane: "w2:p1")
        let used = session(config, at: 20, pane: "w3:p1")
        var ledger = AIPreparedLedger()
        try ledger.add(alive); try ledger.add(gone); try ledger.add(used)
        try ledger.bind(used.id, to: UUID(), config: config)

        let removed = ledger.removeMissing(alivePaneIDs: ["w1:p1"])
        #expect(removed == [gone.id])
        // 紐づけ済みは履歴なので、ペインが無くても残す。
        let remaining: Set<UUID> = Set(ledger.sessions.map(\.id))
        #expect(remaining == Set([alive.id, used.id]))
    }

    // MARK: - 保存の往復

    @Test func 台帳をJSONで往復できる() throws {
        let config = try minutes()
        var ledger = AIPreparedLedger()
        try ledger.add(session(config, at: 0, pane: "w1:p1"))
        try ledger.add(session(config, at: 60, pane: "w2:p1"))
        try ledger.bind(ledger.sessions[0].id, to: UUID(), config: config)
        let decoded = try AIJSON.decode(AIPreparedLedger.self, from: AIJSON.encode(ledger))
        #expect(decoded == ledger)
        #expect(decoded.unbound.count == 1)
    }

    @Test func 壊れた台帳を拒否する() throws {
        #expect(throws: (any Error).self) {
            try AIJSON.decode(AIPreparedLedger.self, from: Data("{\"schema_version\":2,\"sessions\":[]}".utf8))
        }
        // 同じidが2件あれば読まない。
        let config = try minutes()
        let one = session(config)
        let doubled = try AIJSON.encode(AIPreparedLedger(sessions: [one, one]))
        #expect(throws: (any Error).self) { try AIJSON.decode(AIPreparedLedger.self, from: doubled) }
    }

    @Test func 枠と紐づけ先の食い違いを拒否する() throws {
        let config = try minutes()
        let mismatched = AIPreparedSession(profileSlot: 2, profileName: "議事録", startedAt: base,
            config: config, token: "t", contextRoot: URL(fileURLWithPath: "/out"), contextMeetingID: UUID(),
            connection: nil)
        // config.slot は1なのに枠が2。
        #expect(throws: AIError.self) { try mismatched.validate() }
        let wrongBinding = AIPreparedSession(profileSlot: 1, profileName: "議事録", startedAt: base,
            config: config, token: "t", contextRoot: URL(fileURLWithPath: "/out"), contextMeetingID: UUID(),
            connection: nil, bound: .init(meetingID: UUID(), profileSlot: 3))
        #expect(throws: AIError.self) { try wrongBinding.validate() }
        let wrongProvider = AIPreparedSession(profileSlot: 1, profileName: "議事録", startedAt: base,
            config: config, token: "t", contextRoot: URL(fileURLWithPath: "/out"), contextMeetingID: UUID(),
            connection: .init(workspaceID: "w", paneID: "w:p", provider: .codex))
        #expect(throws: AIError.mismatch) { try wrongProvider.validate() }
    }
}
