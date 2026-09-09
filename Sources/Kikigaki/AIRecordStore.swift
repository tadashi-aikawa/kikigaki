import Foundation
import KikigakiCore
import KikigakiAIIO

/// 会議開始時に固定したAI設定。版2でプロファイルの配列になった。
struct AIMeetingManifest: Codable {
    static let currentSchemaVersion = 2
    let schemaVersion: Int
    let meetingID: UUID
    let markdownURL: URL
    let profiles: [ResolvedAIConfig]
    /// 既定のプロファイル。版1のmanifestは1つ目の新規起動プロファイルとして読む。
    /// 復号も生成も空の配列を作らないので、添字で参照してよい
    var config: ResolvedAIConfig { profiles[0] }

    init(schemaVersion: Int = AIMeetingManifest.currentSchemaVersion, meetingID: UUID, markdownURL: URL, profiles: [ResolvedAIConfig]) {
        self.schemaVersion = schemaVersion; self.meetingID = meetingID
        self.markdownURL = markdownURL; self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, meetingID, markdownURL, profiles, config }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        meetingID = try values.decode(UUID.self, forKey: .meetingID)
        markdownURL = try values.decode(URL.self, forKey: .markdownURL)
        switch schemaVersion {
        case 1: profiles = [try values.decode(ResolvedAIConfig.self, forKey: .config)]
        case 2: profiles = try values.decode([ResolvedAIConfig].self, forKey: .profiles)
        default: throw AIError.invalid("manifest version")
        }
        guard !profiles.isEmpty, Set(profiles.map(\.slot)).count == profiles.count else { throw AIError.invalid("manifest profiles") }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(meetingID, forKey: .meetingID)
        try values.encode(markdownURL, forKey: .markdownURL)
        try values.encode(profiles, forKey: .profiles)
    }
}
struct AIRegistration: Codable, Equatable {
    let meetingID: UUID
    let outputDirectory: URL
}

/// アプリ寿命の会議登録簿。過去会議の回収は既知の基点だけを読み、外部CLIを再起動しない。
@MainActor
final class AIRecordStore {
    @MainActor final class Record {
        fileprivate(set) var manifest: AIMeetingManifest
        let controller: AIConversationController
        let recovered: Bool
        var archive: MeetingArchive?
        var savedConversation: AIConversation?
        var saveResult: MeetingArchive.SaveResult?
        var saveWarning: String?
        var hasUnpersistedChanges = true
        init(manifest: AIMeetingManifest, controller: AIConversationController, recovered: Bool) {
            self.manifest = manifest; self.controller = controller; self.recovered = recovered
        }
        var needsRecovery: Bool {
            let questions = controller.conversation.questions
            return hasUnpersistedChanges || questions.contains {
                $0.sendAttemptedAt != nil
                    && ($0.result == nil || ($0.state == .needsInput && !AIQuestion.isAnswered($0, in: questions)))
            }
        }
    }
    private(set) var records: [UUID: Record] = [:]
    private(set) var warnings: [String] = []
    var onChange: (() -> Void)?
    /// 会議IDと、返事が届いたプロファイルの枠
    var onNewResult: ((UUID, Int) -> Void)?
    private let registry: AIFileStore
    private let makeHerdr: () throws -> AIHerdr
    private var unresolved: [AIRegistration] = []
    private var registryHealthy = true
    private var recovering = false
    init(directory: URL, makeHerdr: @escaping () throws -> AIHerdr = { AIHerdr(executable: try AIProcessRunner.executable("herdr")) }) {
        registry = AIFileStore(root: directory); self.makeHerdr = makeHerdr
    }
    func recover() {
        guard !recovering, records.isEmpty else { return }
        recovering = true
        defer { recovering = false }
        do {
            let entries = try AIJSON.decode([AIRegistration].self, from: registry.read(["ai-roots.json"]))
            guard Set(entries.map(\.meetingID)).count == entries.count else { throw AIError.conflict }
            for entry in entries {
                do {
                    let files = AIFileStore(root: entry.outputDirectory), base = Self.base(entry.meetingID)
                    let manifest = try AIJSON.decode(AIMeetingManifest.self, from: files.read(base + ["manifest.json"]))
                    try validate(manifest, registration: entry)
                    let conversation = try AIJSON.decode(AIConversation.self, from: files.read(base + ["state.json"]))
                    // 回収用には実行できないadapterを渡す。herdr未導入でも記録を読める。
                    let controller = try AIConversationController(meetingID: entry.meetingID, outputDirectory: entry.outputDirectory,
                        herdr: AIHerdr(run: { _, _ in throw AIHerdrError.notReady }), recovered: conversation)
                    let record = Record(manifest: manifest, controller: controller, recovered: true)
                    records[entry.meetingID] = record
                    do {
                        let archive = try AIJSON.decode(MeetingArchive.self, from: files.read(base + ["archive.json"]))
                        try validate(archive, manifest: manifest)
                        record.archive = archive
                    } catch { record.saveWarning = "保存用の会議データを読めません。返事は受信箱に保持します" }
                    bind(record)
                    try controller.watch()
                    changed(record)
                } catch { records[entry.meetingID] = nil; unresolved.append(entry); warnings.append("会議 \(entry.meetingID) の保存先を回収できません") }
            }
            recovering = false
            try persistRegistry()
        } catch AIFileError.missing { }
        catch { registryHealthy = false; warnings.append("AI会議の登録簿を読めません") }
        onChange?()
    }
    func begin(meetingID: UUID, markdownURL: URL, config: ResolvedAIConfig) throws -> Record {
        try begin(meetingID: meetingID, markdownURL: markdownURL, profiles: [config])
    }
    func begin(meetingID: UUID, markdownURL: URL, profiles: [ResolvedAIConfig]) throws -> Record {
        guard registryHealthy, !profiles.isEmpty else { throw AIError.invalid("registry unavailable") }
        if let existing = records[meetingID] { return existing }
        let root = markdownURL.deletingLastPathComponent()
        let manifest = AIMeetingManifest(meetingID: meetingID, markdownURL: markdownURL, profiles: profiles)
        let controller = try AIConversationController(meetingID: meetingID, outputDirectory: root, herdr: makeHerdr())
        let record = Record(manifest: manifest, controller: controller, recovered: false)
        try AIFileStore(root: root).write(AIJSON.encode(manifest), to: Self.base(meetingID) + ["manifest.json"], replacing: false)
        // 登録簿が保存できなければ、起動・送信へ進めない。
        records[meetingID] = record
        do { try persistRegistry() } catch { records[meetingID] = nil; throw error }
        bind(record); try controller.watch()
        return record
    }
    /// 取り止めた会議を登録簿から外す。置き場を消す前に呼ぶ。
    /// 残すと監視が続き、再起動時に無い manifest を回収しようとして失敗する。
    /// - Returns: 外せたら true。保存に失敗したら元へ戻して false(呼び手は実体を消さない)
    @discardableResult
    func discard(meetingID: UUID) -> Bool {
        guard let record = records[meetingID] else { return true }
        record.controller.stopWatching()
        records[meetingID] = nil
        do { try persistRegistry() } catch {
            // 登録簿を書けないなら、実体を消させない。消すと回収できない登録だけが残る。
            records[meetingID] = record
            try? record.controller.resumeWatching()
            warnings.append("AI会議の登録簿を保存できません")
            onChange?()
            return false
        }
        onChange?()
        return true
    }

    /// 稼働中のpane ID。準備済みセッションの生存確認に使う。
    func alivePaneIDs() async -> Set<String>? {
        guard let herdr = try? makeHerdr() else { return nil }
        return try? await herdr.alivePaneIDs()
    }

    /// プロファイルの定義を固定値の記録へ足す。requestが参照する定義を残すため、
    /// 既存のプロファイルは書き換えず、新しいslotの追加だけを許す。
    func register(_ profile: ResolvedAIConfig, for record: Record) throws {
        guard !record.recovered, !record.manifest.profiles.contains(where: { $0.slot == profile.slot }) else { return }
        let updated = AIMeetingManifest(meetingID: record.manifest.meetingID, markdownURL: record.manifest.markdownURL,
            profiles: record.manifest.profiles + [profile])
        try AIFileStore(root: record.manifest.markdownURL.deletingLastPathComponent())
            .write(AIJSON.encode(updated), to: Self.base(record.manifest.meetingID) + ["manifest.json"])
        record.manifest = updated
    }

    func save(_ archive: inout MeetingArchive, for meetingID: UUID) -> MeetingArchive.SaveResult {
        guard let record = records[meetingID] else { return archive.save() }
        record.archive = archive; record.hasUnpersistedChanges = true
        persistArchive(record)
        if let updated = record.archive { archive = updated }
        do { try persistRegistry() } catch { warnings.append("AI会議の登録簿を保存できません") }
        return record.saveResult ?? .init(utterances: archive.original.utterances, message: record.saveWarning ?? "保存できません", succeeded: false)
    }
    func retrySaves() {
        for record in records.values where record.hasUnpersistedChanges {
            if record.archive == nil {
                do {
                    let archive = try AIJSON.decode(MeetingArchive.self, from: AIFileStore(root: record.controller.outputDirectory)
                        .read(Self.base(record.manifest.meetingID) + ["archive.json"]))
                    try validate(archive, manifest: record.manifest); record.archive = archive
                } catch { record.saveWarning = "保存用の会議データを読めません。返事は受信箱に保持します" }
            }
            persistArchive(record)
        }
        do { try persistRegistry() } catch { warnings.append("AI会議の登録簿を保存できません") }
        warnings = Array(Set(warnings)).sorted()
        onChange?()
    }
    private func bind(_ record: Record) {
        record.controller.onChange = { [weak self, weak record] in
            guard let self, let record else { return }; changed(record)
        }
        record.controller.onResult = { [weak self, weak record] slot in
            guard let self, let record, !record.recovered else { return }
            onNewResult?(record.manifest.meetingID, slot)
        }
    }
    private func changed(_ record: Record) {
        if record.savedConversation != record.controller.conversation {
            record.hasUnpersistedChanges = true
            if record.archive != nil { persistArchive(record) }
        }
        do { try persistRegistry() } catch { warnings.append("AI会議の登録簿を保存できません") }
        warnings = Array(Set(warnings)).sorted()
        onChange?()
    }
    private func persistArchive(_ record: Record) {
        guard var archive = record.archive else { return }
        do {
            try validate(archive, manifest: record.manifest)
            archive.original.ai = record.controller.conversation
            let files = AIFileStore(root: archive.markdownURL.deletingLastPathComponent())
            let path = Self.base(record.manifest.meetingID) + ["archive.json"]
            // Markdownの前に原データ。失敗時は既存Markdownへ手を付けない。
            try files.write(AIJSON.encode(archive), to: path)
            let result = archive.save()
            record.archive = archive; record.saveResult = result
            try files.write(AIJSON.encode(archive), to: path)
            record.hasUnpersistedChanges = !result.succeeded || !result.rawSucceeded
            record.saveWarning = record.hasUnpersistedChanges ? result.message : nil
            if !record.hasUnpersistedChanges { record.savedConversation = record.controller.conversation }
        } catch { record.hasUnpersistedChanges = true; record.saveResult = nil; record.saveWarning = "会議データの保存に失敗。返事は受信箱に保持します" }
    }
    private func persistRegistry() throws {
        guard registryHealthy else { throw AIError.invalid("registry unavailable") }
        guard !recovering else { return }
        let active = records.values.filter(\.needsRecovery).map {
            AIRegistration(meetingID: $0.manifest.meetingID, outputDirectory: $0.controller.outputDirectory)
        }
        let entries = (unresolved + active).sorted { $0.meetingID.uuidString < $1.meetingID.uuidString }
        try registry.write(AIJSON.encode(entries), to: ["ai-roots.json"])
    }
    private func validate(_ manifest: AIMeetingManifest, registration: AIRegistration) throws {
        guard (1...AIMeetingManifest.currentSchemaVersion).contains(manifest.schemaVersion),
              manifest.meetingID == registration.meetingID,
              manifest.markdownURL.isFileURL, manifest.markdownURL.pathExtension == "md",
              manifest.markdownURL.deletingLastPathComponent().path == registration.outputDirectory.path else { throw AIError.mismatch }
    }
    private func validate(_ archive: MeetingArchive, manifest: AIMeetingManifest) throws {
        guard archive.markdownURL == manifest.markdownURL, archive.original.duration.isFinite, archive.original.duration >= 0,
              archive.original.utterances.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              archive.original.pauses.allSatisfy({ $0.audioTime.isFinite && $0.duration.isFinite && $0.audioTime >= 0 && $0.duration >= 0 }) else { throw AIError.invalid("archive") }
    }
    private static func base(_ id: UUID) -> [String] { [".kikigaki-context", id.uuidString, "ai"] }
}
