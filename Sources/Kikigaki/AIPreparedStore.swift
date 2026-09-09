import Foundation
import KikigakiCore
import KikigakiAIIO

/// 会議に紐づかないAIセッションの台帳と起動。会議の登録簿とはファイルを分けるので、
/// 片方が壊れてももう片方の機能は止まらない。
@MainActor
final class AIPreparedStore {
    private(set) var ledger = AIPreparedLedger()
    private(set) var warning: String?
    /// 起動中のプロファイル。同じプロファイルの送信操作と排他にする
    private(set) var launching: Set<Int> = []
    /// 会議側がその枠を使っているか。準備の起動と送信を同じ枠で重ねないためにアプリが差し込む
    var isSlotBusy: ((Int) -> Bool)?
    /// paneごとの表題。台帳へは保存せず、一覧を出すたびに引き直す
    private(set) var titles: [String: String] = [:]
    var onChange: (() -> Void)?

    private let files: AIFileStore
    private let root: URL
    private let makeHerdr: () throws -> AIHerdr
    private static let fileName = "ai-prepared.json"

    init(directory: URL, makeHerdr: @escaping () throws -> AIHerdr = { AIHerdr(executable: try AIProcessRunner.executable("herdr")) }) {
        root = directory; files = AIFileStore(root: directory); self.makeHerdr = makeHerdr
    }

    /// 台帳が読めないときは準備の操作を無効にする。1件も無い状態とは区別して伝える。
    var isUsable: Bool { !ledgerBroken }
    private var ledgerBroken = false
    var warningText: String { warning ?? "" }

    func load() {
        do { ledger = try AIJSON.decode(AIPreparedLedger.self, from: files.read([Self.fileName])) }
        catch AIFileError.missing { ledger = AIPreparedLedger() }
        catch { warning = "準備済みAIセッションの台帳を読めません"; ledgerBroken = true }
        onChange?()
    }

    private func save() throws { try files.write(AIJSON.encode(ledger), to: [Self.fileName]) }

    // MARK: - 一覧

    var unbound: [AIPreparedSession] { ledger.unbound }
    func available(for config: ResolvedAIConfig, contextRoot: URL? = nil) -> [AIPreparedSession] {
        ledger.available(for: config, contextRoot: contextRoot)
    }
    func stale(for config: ResolvedAIConfig, contextRoot: URL? = nil) -> [AIPreparedSession] {
        ledger.stale(for: config, contextRoot: contextRoot)
    }

    /// 紐づけ済みも含めて台帳から引く。表題は保存していないので、呼ばれるたびに解決する。
    func label(id: UUID, includingName: Bool = true) -> String? {
        ledger.sessions.first { $0.id == id }.map { label($0, includingName: includingName) }
    }

    /// 「議事録 · Kikigaki 議事録抽出 · 13:05起動」。表題が取れない間は名前と時刻だけにする。
    func label(_ session: AIPreparedSession, includingName: Bool = true) -> String {
        var parts: [String] = includingName ? [session.profileName] : []
        if let pane = session.connection?.paneID, let title = titles[pane], !title.isEmpty { parts.append(title) }
        parts.append(Self.clock.string(from: session.startedAt) + "起動")
        return parts.joined(separator: " · ")
    }
    static let clock: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "HH:mm"; return value
    }()

    /// 表題と生存を引き直す。消えていた未紐づけは落とす。herdrへ繋がらないときは落とさない。
    func refresh() async {
        guard let herdr = try? makeHerdr() else { return }
        // 引けなければ何も落とさない。消えたことと、herdrへ繋がらないことを混同しない。
        guard let panes = try? await herdr.panes() else {
            warning = "herdrへ繋がらないため、準備済みの状態を確認できません"; onChange?(); return
        }
        if warning == "herdrへ繋がらないため、準備済みの状態を確認できません" { warning = nil }
        titles = panes.reduce(into: [:]) { $0[$1.paneID] = $1.title }
        let removed = ledger.removeMissing(alivePaneIDs: Set(panes.map(\.paneID)))
        if !removed.isEmpty { try? save() }
        onChange?()
    }

    // MARK: - 起動

    /// 会議に紐づけずに起こす。フック・サンドボックス許可・返送許可は会議用と同じに付ける。
    /// フックの置き場は仮の会議IDで作った枝で、起動引数へ焼き付くため紐づけても動かない。
    func prepare(profile: ResolvedAIConfig, helper: URL, outputDirectory: URL, now: Date = Date()) async {
        // 同じ枠で送信が動いている間は起こさない。別の枠の送信は止めない。
        guard isUsable, !launching.contains(profile.slot), isSlotBusy?(profile.slot) != true else { return }
        launching.insert(profile.slot); onChange?()
        defer { launching.remove(profile.slot); onChange?() }
        let context = UUID()
        var session = AIPreparedSession(profileSlot: profile.slot, profileName: profile.name, startedAt: now,
            config: profile, token: UUID().uuidString + UUID().uuidString,
            contextRoot: outputDirectory, contextMeetingID: context)
        do {
            let record = AISessionRecord(meetingID: context, generation: 1, provider: profile.cli, token: session.token)
            let store = AIFileStore(root: outputDirectory)
            let base = [".kikigaki-context", context.uuidString, "ai"]
            try store.write(AIJSON.encode(record), to: base + ["sessions", "1.json"], replacing: false)
            let launch = try AILaunchConfiguration(config: profile, helper: helper, outputDirectory: outputDirectory,
                meetingID: context, sessionURL: session.sessionURL, generation: 1, token: session.token,
                contextWide: true)
            let herdr = try makeHerdr()
            let format = DateFormatter(); format.dateFormat = "HH:mm"
            let created = try await herdr.create(cwd: profile.cwd, label: "KIKIGAKI \(profile.name) 準備 \(format.string(from: now))",
                                                 provider: profile.cli)
            session.connection = created
            var stored = record; stored.connection = created
            try store.write(AIJSON.encode(stored), to: base + ["sessions", "1.json"])
            do { try await herdr.label(created, participant: profile.participantName) }
            catch { warning = "herdrの表示名を設定できません" }
            do {
                try await herdr.start(created, executable: launch.executable, arguments: launch.arguments,
                                      customCommand: profile.command != nil, generation: 1)
            } catch AIHerdrError.server("agent_not_ready") { warning = "初回設定をherdrで確認してください" }
            var next = ledger
            try next.add(session)
            try files.write(AIJSON.encode(next), to: [Self.fileName])
            ledger = next
            warning = nil
        } catch {
            warning = "AIセッションを準備できません。herdrのペインと設定を確認してください"
        }
    }

    // MARK: - 紐づけ

    /// 会議側へ接続を書き終えてから呼ぶ。逆順にすると、台帳では使用済みなのに
    /// 会議側に接続が無い行が残る。
    func bind(_ id: UUID, to meetingID: UUID, config: ResolvedAIConfig) throws {
        // **保存してから公開する。** 先に台帳を書き換えると、保存に失敗した紐づけが
        // 候補から消えたまま残り、再起動で未紐づけへ戻る。
        var next = ledger
        try next.bind(id, to: meetingID, config: config)
        try files.write(AIJSON.encode(next), to: [Self.fileName])
        ledger = next
        onChange?()
    }

    /// 取り止めた会議の紐づけを未紐づけへ戻す。次の会議でまた選べるようにする。
    /// - Returns: 戻せたら true。保存に失敗したら false(呼び手は会議の実体を消さない)
    @discardableResult
    func unbindAll(meetingID: UUID) -> Bool {
        var next = ledger
        let restored = next.unbindAll(meetingID: meetingID)
        guard !restored.isEmpty else { return true }
        do {
            try files.write(AIJSON.encode(next), to: [Self.fileName])
            ledger = next
            onChange?()
            return true
        } catch {
            warning = "準備済みAIセッションの紐づけを戻せません"
            onChange?()
            return false
        }
    }

    func discard(_ id: UUID) {
        do {
            var next = ledger
            try next.discard(id)
            try files.write(AIJSON.encode(next), to: [Self.fileName])
            ledger = next; warning = nil
        } catch { warning = "準備済みAIセッションを破棄できません" }
        onChange?()
    }

    func showPane(_ id: UUID) async {
        guard let target = ledger.sessions.first(where: { $0.id == id })?.connection,
              let herdr = try? makeHerdr() else { return }
        do { try await herdr.show(target) } catch { warning = "herdrのペインを開けません"; onChange?() }
    }
}
