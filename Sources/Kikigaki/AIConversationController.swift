import Foundation
import KikigakiCore
import KikigakiAIIO

/// 1会議の直列トランザクション。外部起動と送信の前に意図を保存し、
/// 保存が成功するまで公開状態を変えない。回収用インスタンスには送信権限を与えない。
///
/// 会話・受信箱・保存は会議に1つのまま持ち、接続とstream履歴だけをプロファイルごとの
/// チャネルへ分ける。`AIConversation` が `request.number == index + 1` を復号時に検証しており、
/// 保存用archiveも1つの会話を前提にしているため、会話まで分けると通し番号・Markdown生成・
/// 登録簿の再設計が連鎖する。受信箱はrequest ID単位なので、そもそも分ける必要がない。
@MainActor
final class AIConversationController {
    /// プロファイル1つぶんの接続と配信履歴。世代と受領基準はここに閉じる。
    final class Channel {
        let slot: Int
        var history: AIStreamHistory
        var session: AISessionRecord?
        var connection: AIHerdrConnection?
        var connectionStatus: AIConnectionStatus = .unknown
        var configuration: ResolvedAIConfig?
        var snapshots: Set<UUID> = []
        var connecting = false
        var launchingAttempted = false
        var inputAttempted = false
        var isSending = false
        var idleSince: Date?
        var hookBackgroundRunning = false
        var warning: String?
        var preparedSessionName: String?
        /// フック観測の置き場と、その通知が名乗る世代。準備済みセッションを引き継いだ枠は、
        /// 起動時に焼き付いた仮の会議の置き場へ、常に第1世代として落ちる
        var hookContext: (root: URL, meetingID: UUID, generation: Int)?
        var generation: Int { history.sessionGeneration }
        init(slot: Int, meetingID: UUID) throws {
            self.slot = slot
            history = try AIStreamHistory(meetingID: meetingID)
        }
    }

    let meetingID: UUID
    let outputDirectory: URL
    let minutes: MinutesStore
    private(set) var conversation: AIConversation
    private var recoveredRangeHistories: [Int: AIStreamHistory] = [:]
    private(set) var invalidInboxFiles: [String] = []
    private var lastScanReturnStatus: [UUID: Bool] = [:]
    var onChange: (() -> Void)?
    /// 明示的なreplay検証だけで、受信直前に人のパス指定を再現する。
    var beforeMinutesScanForReplay: (() -> Void)?
    /// 返事が届いた枠。通知音は返答元のプロファイルの設定で決める
    var onResult: ((Int) -> Void)?
    private var channels: [Int: Channel] = [:]
    private var profiles: [Int: ResolvedAIConfig] = [:]
    private let files: AIFileStore
    private let herdr: AIHerdr
    private let allowsSending: Bool
    private var monitor: AIInboxMonitor?
    private var polling: Set<Int> = []
    /// 受信箱の走査で起きた失敗。プロファイルに属さないので会議単位で持つ
    private var scanWarning: String?
    /// 既定のチャネル。プロファイル未指定の呼び出しと旧requestの帰属先
    private(set) var defaultSlot = 1

    private var base: [String] { [".kikigaki-context", meetingID.uuidString, "ai"] }

    init(meetingID: UUID, outputDirectory: URL, herdr: AIHerdr, recovered: AIConversation? = nil,
         minutes: MinutesStore) throws {
        self.meetingID = meetingID; self.outputDirectory = outputDirectory; self.herdr = herdr
        self.minutes = minutes
        guard self.minutes.meetingID == meetingID else { throw AIError.mismatch }
        files = AIFileStore(root: outputDirectory); allowsSending = recovered == nil
        conversation = recovered ?? AIConversation(meetingID: meetingID)
        guard conversation.meetingID == meetingID else { throw AIError.mismatch }
        // Codableの公開入口を通し、呼び手が作った値も復元と同じ整合検証を受ける。
        _ = try AIJSON.decode(AIConversation.self, from: AIJSON.encode(conversation))
        for q in conversation.questions { try q.request.envelope.validatePaths(outputDirectory: outputDirectory) }
        channels[defaultSlot] = try Channel(slot: defaultSlot, meetingID: meetingID)
        if recovered != nil {
            let perSlot = Dictionary(grouping: conversation.questions) { $0.request.envelope.participant.profileSlot ?? defaultSlot }
            for question in perSlot.values.compactMap({ $0.last }) {
                let participant = question.request.envelope.participant
                let slot = participant.profileSlot ?? defaultSlot
                let savedGeneration = try? AIJSON.decode(Int.self, from: files.read(base + ["sessions", "\(slot)", "generation.json"]))
                // 作り直したあと一度も送っていない場合、旧requestの範囲を復活させない。
                guard (savedGeneration ?? participant.sessionGeneration) <= participant.sessionGeneration else { continue }
                recoveredRangeHistories[slot] = try AIStreamHistory(meetingID: meetingID,
                    streamID: participant.streamID, sessionGeneration: participant.sessionGeneration)
            }
        }
    }

    // MARK: - チャネル

    func rangeBoundaries(slot: Int?, utterances: [Utterance]) -> AIRangeBoundaries {
        guard let slot else { return AIRangeBoundaries() }
        let questions = conversation.questions.filter { self.slot(of: $0.request) == slot }
        // 回収時は送信用historyを復元しない。保存済みrequestの現stream識別子だけを使う。
        let history: AIStreamHistory?
        if allowsSending { history = channels[slot]?.history }
        else { history = recoveredRangeHistories[slot] }
        guard let history else { return AIRangeBoundaries() }
        return AIRangeBoundaries.resolve(history: history, questions: questions, utterances: utterances)
    }

    private func channel(_ slot: Int) throws -> Channel {
        if let existing = channels[slot] { return existing }
        let created = try Channel(slot: slot, meetingID: meetingID)
        channels[slot] = created
        return created
    }
    /// 会議で使うプロファイルを登録する。送信のたびに同じ値であることを検証する。
    func register(_ profiles: [ResolvedAIConfig]) throws {
        for profile in profiles {
            if let known = self.profiles[profile.slot], known != profile { throw AIError.mismatch }
            self.profiles[profile.slot] = profile
            _ = try channel(profile.slot)
        }
        if let first = profiles.first, self.profiles[defaultSlot] == nil { defaultSlot = first.slot }
    }
    private func slot(of request: AIRequest) -> Int { request.envelope.participant.profileSlot ?? defaultSlot }
    private func questions(inSlot target: Int, generation: Int) -> [AIQuestion] {
        conversation.questions.filter {
            slot(of: $0.request) == target && $0.request.envelope.participant.sessionGeneration == generation
        }
    }

    // MARK: - 既定チャネルの読み出し(単一プロファイルの呼び出し口)

    var generation: Int { (try? channel(defaultSlot).generation) ?? 1 }
    var connection: AIHerdrConnection? { channels[defaultSlot]?.connection }
    var connectionStatus: AIConnectionStatus { connectionStatus(slot: defaultSlot) }
    var canSend: Bool { canSend(slot: defaultSlot) }
    var isSending: Bool { channels.values.contains { $0.isSending } }
    var sessionURL: URL { sessionURL(slot: defaultSlot) }
    var sessionToken: String? { channels[defaultSlot]?.session?.token }
    /// 会議のどこかで起きた警告。複数プロファイルではどのプロファイルかを添える
    var warning: String? {
        if let scanWarning { return scanWarning }
        for slot in channels.keys.sorted() {
            guard let message = channels[slot]?.warning else { continue }
            guard profiles.count > 1, let name = profiles[slot]?.name else { return message }
            return name + ": " + message
        }
        return nil
    }

    /// 引き継いだフックの置き場。世代を作り直すと消えることの検証に使う
    func hookContextMeetingForTesting(slot: Int) -> UUID? { channels[slot]?.hookContext?.meetingID }
    /// フックが伝えた背景処理中。引き継いだ枠の世代がずれていないかの検証に使う
    func hookBackgroundRunningForTesting(slot: Int) -> Bool { channels[slot]?.hookBackgroundRunning ?? false }
    func generation(slot: Int) -> Int { channels[slot]?.generation ?? 1 }
    func connection(slot: Int) -> AIHerdrConnection? { channels[slot]?.connection }
    func connectionStatus(slot: Int) -> AIConnectionStatus { channels[slot]?.connectionStatus ?? .unknown }
    func sessionToken(slot: Int) -> String? { channels[slot]?.session?.token }
    func sessionURL(slot: Int) -> URL {
        path(AIEnvelope.sessionPath(slot: storedSlot(slot), generation: generation(slot: slot))
            .split(separator: "/").dropFirst().map(String.init))
    }
    /// 保存パスとenvelopeへ書く番号。単一プロファイルの会議は従来どおり平置きにして、
    /// 旧requestと同じ形を保つ。プロファイルを増やした会議だけ枝を切る。
    private func storedSlot(_ slot: Int) -> Int? { profiles.count > 1 || slot != defaultSlot ? slot : nil }
    func canSend(slot: Int) -> Bool {
        guard allowsSending, !discarded, let channel = channels[slot] else { return false }
        return !channel.isSending && !channel.connecting
            && (channel.connection == nil ? !channel.launchingAttempted : channel.connectionStatus == .idle)
            && !questions(inSlot: slot, generation: channel.generation).contains { $0.isAwaitingResult || $0.state == .prepared }
    }

    func watch() throws {
        guard monitor == nil else { return }
        let inbox = try files.directory(base + ["inbox"])
        monitor = AIInboxMonitor(directory: inbox) { [weak self] in self?.scan(); self?.pollAll() }
    }

    func preview(lines: [String], full: Bool, slot: Int? = nil) throws -> AIContextSnapshot {
        var copy = try channel(slot ?? defaultSlot).history
        return try copy.prepare(lines: lines, outputDirectory: outputDirectory, full: full)
    }

    func hasChanges(lines: [String], slot: Int? = nil) -> Bool {
        (try? channel(slot ?? defaultSlot).history.hasChanges(lines: lines)) ?? !lines.isEmpty
    }

    // MARK: - 送信

    func prepare(lines: [String], question: String, voiceQuestion: String, capturedAt: Date, cutoff: Double,
                 tail: AITentativeTail?, config: ResolvedAIConfig, helper: URL, parent: UUID? = nil,
                 full: Bool = false, workAllowed: Bool? = nil, voiceUtteranceStart: Double? = nil,
                 trigger: AIParticipantContext.Trigger? = nil, minutesPath: String? = nil) throws -> AIRequest {
        if let minutesPath { try minutes.validateTarget(minutesPath) }
        try register([config])
        let channel = try channel(config.slot)
        guard canSend(slot: config.slot) else { throw AIHerdrError.notReady }
        // 確認への返答は元質問と同じチャネルへ返す。呼び手が宛先を変えていても、ここで止める。
        if let parent, let original = conversation.questions.first(where: { $0.request.id == parent }),
           slot(of: original.request) != config.slot { throw AIError.mismatch }
        if let configuration = channel.configuration, configuration != config { throw AIError.mismatch }
        let snapshot = try channel.history.prepare(lines: lines, outputDirectory: outputDirectory, full: full)
        let slot = storedSlot(config.slot)
        let sessionPath = sessionURL(slot: config.slot).path
        let participant = AIParticipantContext(streamID: channel.history.streamID, requestID: UUID(),
            sessionGeneration: channel.generation,
            participantName: config.participantName, cliPath: helper.path, sessionPath: sessionPath,
            requestToken: UUID().uuidString + UUID().uuidString, question: question, capturedAt: capturedAt,
            audioCutoffSeconds: cutoff, tentativeTail: tail, inReplyToRequestID: parent,
            inReplyToEventID: parent.map { "\($0.uuidString)/result" }, workAllowed: workAllowed ?? config.allowWork,
            trigger: trigger, profile: slot == nil ? nil : config.name, profileSlot: slot, preparedSessionName: channel.preparedSessionName,
            minutesPath: minutesPath)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant),
            number: conversation.questions.count + 1, voiceQuestion: voiceQuestion, snapshot: snapshot, voiceUtteranceStart: voiceUtteranceStart)
        var next = conversation
        try next.append(request)
        if channel.session == nil {
            channel.session = AISessionRecord(schemaVersion: 1, meetingID: meetingID, generation: channel.generation,
                provider: config.cli, token: UUID().uuidString + UUID().uuidString)
            channel.configuration = config
        }
        if !channel.snapshots.contains(snapshot.id) {
            try files.write(snapshot.contents, to: [".kikigaki-context", meetingID.uuidString, snapshot.id.uuidString + ".md"], replacing: false)
            channel.snapshots.insert(snapshot.id)
        }
        try files.write(AIJSON.encode(request), to: base + ["requests", request.id.uuidString + ".json"], replacing: false)
        try commit(next)
        onChange?()
        return request
    }

    /// 準備済みセッションをこの枠のチャネルへ引き継ぐ。**会議側の保存が成功してから**
    /// 台帳へ `bound` を書くこと。逆順にすると、台帳では使用済みなのに会議側に接続が無い行が残る。
    func adopt(_ prepared: AIPreparedSession, config: ResolvedAIConfig) async throws {
        guard !discarded else { throw AIHerdrError.notReady }
        try register([config])
        let channel = try channel(config.slot)
        guard prepared.hasCurrentLaunch, prepared.matches(config), let connection = prepared.connection else { throw AIError.mismatch }
        // 起動時に許可した保存先と会議の保存先が違うと、返送がサンドボックスで落ちる。
        // 起動引数は変えられないので、ここで断る。候補の絞り込みでも同じ条件を見る。
        guard prepared.matchesContext(root: outputDirectory) else { throw AIError.mismatch }
        // 会議側だけ済んでいる同じ紐づけのやり直しは、そのまま成功として扱う。
        // 台帳の保存に失敗した紐づけを、利用者がもう一度選べるようにするため。
        // 一致は接続の識別だけで見る。生存確認で session や terminal が補われた分を差分にしない。
        if let existing = channel.session, existing.token == prepared.token, channel.configuration == config,
           existing.connection?.paneID == connection.paneID,
           existing.connection?.workspaceID == connection.workspaceID { onChange?(); return }
        guard allowsSending, channel.session == nil, channel.connection == nil,
              !channel.launchingAttempted else { throw AIHerdrError.notReady }
        // 何も書く前に生存を確かめる。消えたペインを引き継ぐと枠が塞がり、別の準備済みを選び直せない。
        _ = try await herdr.observe(connection)
        // await後にもう一度見る。待っている間に同じ枠で起動や別の紐づけが進んでいることがある。
        // 取り止めた会議へも書かない。ここを抜けると、消した置き場をsessionの保存で作り直す。
        guard !discarded, channel.session == nil, channel.connection == nil,
              !channel.launchingAttempted else { throw AIHerdrError.notReady }
        // フック用トークンは準備時のものを引き継ぐ。起動引数へ焼き付いていて変えられない。
        var record = AISessionRecord(schemaVersion: 1, meetingID: meetingID, generation: channel.generation,
                                     provider: config.cli, token: prepared.token)
        record.connection = connection
        // **保存してから公開する。** 先に channel を書き換えると、保存に失敗した紐づけを
        // やり直せない(2回目の adopt が session ありで弾かれる)。
        do { try files.write(AIJSON.encode(record), to: sessionParts(channel), replacing: false) }
        catch AIError.conflict {
            // 会議側だけ保存できていた同じ紐づけのやり直し。中身が同じときに限って先へ進む。
            let stored = try AIJSON.decode(AISessionRecord.self, from: files.read(sessionParts(channel)))
            guard stored == record else { throw AIError.conflict }
        }
        channel.session = record
        channel.configuration = config
        channel.connection = connection
        channel.launchingAttempted = true; channel.inputAttempted = true
        // 準備の通知は第1世代を名乗る。会議側の世代と別に持たないと、作り直した枠で捨ててしまう。
        channel.preparedSessionName = prepared.name
        channel.hookContext = (prepared.contextRoot, prepared.contextMeetingID, 1)
        // 引き継いだ直後に生存を確かめる。失敗しても記録は残し、状態は切断として見せる。
        try? await refreshConnection(slot: config.slot)
        onChange?()
    }

    /// 引き継いだ接続を手放す。「新規に起動する」を選び直したときに使う。
    /// 保存物も消して、次の起動が同じ世代のまま自分の記録を書けるようにする。
    /// この世代で依頼を1つでも作った枠は手放さない(送信済みの参照先が消える)。
    func releaseAdopted(slot: Int) throws {
        guard allowsSending, let channel = channels[slot], channel.hookContext != nil,
              !channel.isSending, !channel.connecting,
              questions(inSlot: slot, generation: channel.generation).isEmpty else { throw AIHerdrError.notReady }
        let file = sessionParts(channel).reduce(outputDirectory) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        channel.session = nil; channel.connection = nil; channel.configuration = nil
        channel.launchingAttempted = false; channel.inputAttempted = false
        channel.connectionStatus = .unknown; channel.idleSince = nil; channel.warning = nil
        channel.preparedSessionName = nil
        channel.hookContext = nil; channel.hookBackgroundRunning = false
        onChange?()
    }

    /// この枠が準備済みセッションを引き継いだ状態か。紐づけの後始末の判定に使う
    func hasAdopted(slot: Int) -> Bool { channels[slot]?.hookContext != nil }

    /// 取り止めた会議。置き場を消した後は、遅れて返ってきた観測でも何も書かない
    private(set) var discarded = false

    /// 監視を止め、この会議への書き込みを一切やめる。取り止めた会議の置き場を消す前に呼ぶ。
    /// 監視元を止めるだけでは、既に走っているpollがawaitから戻って消した場所へ書き直せる。
    func stopWatching() {
        discarded = true
        monitor?.stop(); monitor = nil
    }
    /// 片付けに失敗して会議を残すときに戻す
    func resumeWatching() throws {
        discarded = false
        try watch()
    }

    func connect(config: ResolvedAIConfig, label: String, executable: URL, arguments: [String], readinessTimeout: TimeInterval = 30) async throws {
        guard readinessTimeout.isFinite, readinessTimeout > 0 else { throw AIProcessError.invalidInput }
        let channel = try channel(config.slot)
        guard allowsSending, !channel.connecting, channel.configuration == config, channel.session != nil else { throw AIHerdrError.notReady }
        if channel.connection != nil { try await waitUntilReady(channel, timeout: readinessTimeout); return }
        guard !channel.launchingAttempted else { throw AIHerdrError.notReady }
        channel.connecting = true
        defer { channel.connecting = false; onChange?() }
        try files.write(AIJSON.encode(Date()), to: launchPath(channel), replacing: false)
        channel.launchingAttempted = true
        try await launch(channel, config: config, label: label, executable: executable, arguments: arguments)
        // pane run で起こした直後は herdr がまだagentを検知しておらず `agent get` が agent_not_found を返す
        // (実測: 初回の質問だけ「送信を完了できません」になった)。起動直後の待ちに限り、未検知は切断ではなく待ちとして扱う。
        try await waitUntilReady(channel, timeout: readinessTimeout, tolerateMissing: true)
    }

    private func launch(_ channel: Channel, config: ResolvedAIConfig, label: String, executable: URL, arguments: [String]) async throws {
        let created = try await herdr.create(cwd: config.cwd, label: label, provider: config.cli)
        try saveConnection(channel, created, replacing: false)
        do { try await herdr.label(created, participant: config.participantName) }
        catch { channel.warning = "herdrの表示名を設定できません" }
        try Task.checkCancellation()
        channel.inputAttempted = true
        do { try await herdr.start(created, executable: executable, arguments: arguments, customCommand: config.command != nil, generation: channel.generation) }
        catch AIHerdrError.server("agent_not_ready") { channel.warning = "初回設定をherdrで確認してください" }
        catch { channel.warning = "起動を確認できません。ペインを確認してください"; throw error }
    }

    private func waitUntilReady(_ channel: Channel, timeout: TimeInterval, tolerateMissing: Bool = false) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try Task.checkCancellation()
            do { try await refreshConnection(slot: channel.slot) }
            catch AIHerdrError.missing where tolerateMissing { channel.connectionStatus = .unknown }
            if channel.connectionStatus == .idle { return }
            if channel.connectionStatus == .blocked { throw AIHerdrError.notReady }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { channel.warning = "入力準備を確認できません。herdrで確認してください"; throw AIProcessError.timeout }
            try await Task.sleep(for: .seconds(min(0.1, remaining)))
        } while true
    }

    func refreshConnection() async throws { try await refreshConnection(slot: defaultSlot) }
    func refreshConnection(slot: Int) async throws {
        guard let channel = channels[slot], let target = channel.connection, channel.inputAttempted else { throw AIHerdrError.notReady }
        let revision = channel.generation
        do {
            let observed = try await herdr.observe(target)
            // 取り止めた会議へは書かない。置き場は既に消えている。
            guard !discarded, revision == channel.generation, target.paneID == channel.connection?.paneID else { return }
            try apply(channel, observed)
        } catch {
            guard !discarded, revision == channel.generation, target.paneID == channel.connection?.paneID else { return }
            channel.idleSince = nil
            if error as? AIHerdrError == .replaced || error as? AIHerdrError == .missing { channel.connectionStatus = .disconnected }
            else { channel.connectionStatus = .unknown }
            throw error
        }
    }

    func send(_ supplied: AIRequest, config: ResolvedAIConfig,
              willBeginSending: (() throws -> Void)? = nil, didBeginSending: ((Date) -> Void)? = nil) async throws {
        let channel = try channel(config.slot)
        guard allowsSending, !channel.isSending, !channel.connecting, channel.inputAttempted, channel.configuration == config,
              let stored = conversation.questions.first(where: { $0.request.id == supplied.id }), stored.request == supplied,
              stored.state == .prepared, supplied.envelope.participant.sessionGeneration == channel.generation,
              slot(of: supplied) == config.slot else { throw AIHerdrError.notReady }
        channel.isSending = true
        defer { channel.isSending = false; onChange?() }
        let text = try stored.request.envelope.prompt(address: config.address, extraPrompt: config.prompt)
        try await refreshConnection(slot: config.slot)
        try Task.checkCancellation()
        guard channel.connectionStatus == .idle, let target = channel.connection else { throw AIHerdrError.notReady }
        do {
            try await herdr.prompt(target, text: text) { @MainActor [self] in
                // 最後の生存確認中の取消まで反映し、prompt直前に送信試行を保存する。
                try willBeginSending?()
                let sentAt = Date()
                var next = conversation
                try next.update(stored.request.id) { try $0.beginSending(at: sentAt) }
                try commit(next)
                didBeginSending?(sentAt)
                onChange?()
            }
            var next = conversation
            try next.update(stored.request.id) { try $0.submitted() }
            try commit(next)
        } catch { channel.warning = "送達を確認できません。ペインを確認してください"; throw error }
    }

    func cancel(_ id: UUID) throws { try change(id) { try $0.cancel(at: Date()) } }
    func markRead(_ id: UUID) throws { try change(id) { $0.markRead() } }
    func fail(_ id: UUID, reason: String) throws { try change(id) { try $0.failBeforeSending(reason) } }
    private func change(_ id: UUID, body: (inout AIQuestion) throws -> Void) throws {
        var next = conversation; try next.update(id, body); try commit(next); onChange?()
    }
    func showPane(slot: Int? = nil) async throws {
        guard let connection = channels[slot ?? defaultSlot]?.connection else { throw AIHerdrError.notReady }
        try await herdr.show(connection)
    }

    /// 利用者の明示操作からだけ呼ぶ。旧質問は残し、新しいstreamを発行する。
    func newGeneration(slot: Int? = nil) throws {
        let target = slot ?? defaultSlot
        guard let channel = channels[target], allowsSending, !channel.isSending, !channel.connecting,
              channel.generation < Int.max else { throw AIHerdrError.notReady }
        let next = try AIStreamHistory(meetingID: meetingID, sessionGeneration: channel.generation + 1)
        try files.write(AIJSON.encode(next.sessionGeneration), to: base + ["sessions", "\(target)", "generation.json"])
        channel.history = next; channel.connection = nil; channel.session = nil; channel.snapshots = []
        channel.launchingAttempted = false; channel.inputAttempted = false
        channel.connectionStatus = .unknown; channel.idleSince = nil; channel.warning = nil
        // 作り直したCLIのフックは本会議の受信箱へ落ちる。引き継いだ置き場を残すと、
        // 走査が仮の会議の側を読み続けて背景処理中を拾えなくなる。
        channel.preparedSessionName = nil
        channel.hookContext = nil; channel.hookBackgroundRunning = false
        onChange?()
    }

    // MARK: - 受信

    func scan() {
        guard !discarded else { return }
        let oldWarning = warning, oldInvalid = invalidInboxFiles
        let oldBackground = channels.mapValues { $0.hookBackgroundRunning }
        invalidInboxFiles = []
        scanWarning = nil
        scanHooks()
        beforeMinutesScanForReplay?()
        // resultのcommit/onChangeより先に議事録の保存失敗を確定し、登録簿から脱落させない。
        minutes.scan(questions: conversation.questions)
        var events: [AIReceiveEvent] = []
        for q in conversation.questions where q.sendAttemptedAt != nil {
            for suffix in ["accept", "result"] {
                let name = q.request.id.uuidString + "." + suffix + ".json"
                do {
                    let bytes = try files.read(base + ["inbox", name], limit: AILimits.eventBytes)
                    events.append(try AIInbox.decode(bytes, filename: name, for: q.request))
                } catch AIFileError.missing { continue }
                catch { invalidInboxFiles.append(name); scanWarning = "受信箱のイベントを検証できません" }
            }
        }
        events.sort { $0.recordedAt == $1.recordedAt ? $0.eventID < $1.eventID : $0.recordedAt < $1.recordedAt }
        var next = conversation
        var changed = false
        var acknowledged: [Int: AIStreamHistory] = [:]
        /// 返事が届いたチャネル。警告を消してよいのはここに入った枠だけ
        var resolved = Set<Int>()
        var notify: [Int] = []
        let now = Date()
        for event in events {
            do {
                if try next.receive(event, at: now) {
                    changed = true
                    let question = next.questions.first { $0.request.id == event.requestID }
                    guard let request = question?.request else { continue }
                    let target = slot(of: request)
                    let scheduled = request.trigger == .scheduled
                    if event.kind == .needsInput || (event.kind == .answered && !scheduled) { notify.append(target) }
                    guard let channel = channels[target] else { continue }
                    // 別チャネルの結果でこの枠の送達不明が晴れることはない。世代も合っていなければ、
                    // その警告は今届いた結果では解消できない。
                    if event.kind != .accept, event.sessionGeneration == channel.generation { resolved.insert(target) }
                    var received = acknowledged[target] ?? channel.history
                    if event.contextReceived, channel.snapshots.contains(event.snapshotID), event.sessionGeneration == channel.generation {
                        try received.acknowledge(snapshotID: event.snapshotID, streamID: channel.history.streamID,
                                                 sessionGeneration: channel.generation)
                        acknowledged[target] = received
                    }
                }
            } catch { scanWarning = "受信箱の返事が既存記録と競合しています" }
        }
        if changed {
            do {
                try commit(next)
                for (slot, history) in acknowledged { channels[slot]?.history = history }
                for slot in resolved { channels[slot]?.warning = nil }
                for slot in notify { onResult?(slot) }
            } catch { scanWarning = "返事の取り込み状態を保存できません" }
        }
        let returns = Dictionary(uniqueKeysWithValues: conversation.questions.map { ($0.request.id, isReturnUnconfirmed($0)) })
        let returnChanged = returns != lastScanReturnStatus
        lastScanReturnStatus = returns
        if changed || returnChanged || oldWarning != warning || oldInvalid != invalidInboxFiles || oldBackground != channels.mapValues({ $0.hookBackgroundRunning }) {
            onChange?()
        }
    }

    func isReturnUnconfirmed(_ q: AIQuestion, now: Date = Date(), backgroundRunning: Bool = false) -> Bool {
        let target = slot(of: q.request)
        guard let channel = channels[target], q.request.envelope.participant.sessionGeneration == channel.generation else { return false }
        return AIReturnStatus.isUnconfirmed(question: q, connection: channel.connectionStatus, idleSince: channel.idleSince,
            now: now, hasRunningBackgroundTasks: backgroundRunning || channel.hookBackgroundRunning)
    }

    /// 受信箱は会議で1つなので、フックの観測も全チャネル分が混ざって置かれる。
    /// **どのチャネルのものかを先に決めてから検証する。** チャネルごとに走査して自分のproviderで
    /// 検証すると、相手側CLIの正常なフックが不正イベントに化ける(世代番号が並ぶと必ず起きる)。
    private func scanHooks() {
        for channel in channels.values { channel.hookBackgroundRunning = false }
        let owners = channels.values.compactMap { channel in channel.session.map { (channel, $0) } }
        guard !owners.isEmpty else { return }
        // 受信箱は基本ひとつだが、準備済みセッションを引き継いだ枠だけは起動時の置き場に落ちる。
        // 置き場ごとに束ねて、その中で持ち主を決める。
        var groups: [String: (store: AIFileStore, meetingID: UUID, owners: [(Channel, AISessionRecord)])] = [:]
        for owner in owners {
            let context = owner.0.hookContext ?? (outputDirectory, meetingID, owner.0.generation)
            let key = context.root.path + "\n" + context.meetingID.uuidString
            groups[key, default: (AIFileStore(root: context.root), context.meetingID, [])].owners.append(owner)
        }
        for group in groups.values {
            let base = [".kikigaki-context", group.meetingID.uuidString, "ai"]
            do {
                let inbox = try group.store.directory(base + ["inbox"], create: false)
                let names = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
                var identities: [Int: String] = [:]
                for (channel, _) in group.owners {
                    // 置き場の中の世代で読む。引き継いだ枠は常に第1世代の隣に置かれている。
                    let hookGeneration = channel.hookContext?.generation ?? channel.generation
                    if let identity = channel.connection?.sessionID ?? (try? AIJSON.decode(String.self,
                        from: group.store.read(base + ["sessions", "\(hookGeneration).identity.json"], limit: 2048))) {
                        identities[channel.slot] = identity
                    }
                }
                var latest: [Int: AIHookObservation] = [:]
                for name in names where name.hasPrefix("notify-") && name.hasSuffix(".json") {
                    do {
                        let event = try AIJSON.decode(AIHookObservation.self,
                            from: group.store.read(base + ["inbox", name], limit: AILimits.eventBytes))
                        guard event.filename == name, event.meetingID == group.meetingID else { throw AIError.mismatch }
                        // 持ち主は identity まで見て決める。`validate` は会議・世代・CLI種別しか比べないので、
                        // 同じCLIで世代が並ぶ2枠があると、Bのイベントで先にAを選び、その後の
                        // identity不一致で捨ててしまう(Claudeの背景処理中フラグが落ちる)。
                        // 現世代のどのチャネルにも属さないものは、旧世代の診断か未接続チャネル宛て。
                        // 壊れているとは限らないので不正には数えない。
                        guard let owner = group.owners.first(where: { channel, session in
                            let expected = channel.hookContext.map { hook in
                                AISessionRecord(schemaVersion: 1, meetingID: group.meetingID, generation: hook.generation,
                                                provider: session.provider, token: session.token)
                            } ?? session
                            return (try? event.validate(session: expected)) != nil
                                && identities[channel.slot] == event.sessionID
                        })?.0 else { continue }
                        if latest[owner.slot] == nil || event.recordedAt > latest[owner.slot]!.recordedAt { latest[owner.slot] = event }
                    } catch { invalidInboxFiles.append(name) }
                }
                for (slot, event) in latest { channels[slot]?.hookBackgroundRunning = event.runningBackgroundTasks }
            } catch { for (channel, _) in group.owners { channel.warning = "フック観測を確認できません" } }
        }
    }

    private func pollAll() { for slot in channels.keys { poll(slot) } }
    private func poll(_ slot: Int) {
        guard !discarded, let channel = channels[slot], !polling.contains(slot),
              channel.connection != nil, channel.inputAttempted else { return }
        polling.insert(slot)
        Task { [weak self] in
            guard let self else { return }
            defer { polling.remove(slot); onChange?() }
            do { try await refreshConnection(slot: slot) } catch { /* 状態分類はrefreshConnectionで行う */ }
        }
    }

    private func apply(_ channel: Channel, _ observed: AIHerdrObservation) throws {
        guard var target = channel.connection else { return }
        if let expected = target.sessionID, let actual = observed.sessionID, expected != actual { throw AIHerdrError.replaced }
        if let expected = target.terminalID, let actual = observed.terminalID, expected != actual { throw AIHerdrError.replaced }
        target.sessionID = target.sessionID ?? observed.sessionID
        target.terminalID = target.terminalID ?? observed.terminalID
        if target != channel.connection { try saveConnection(channel, target) }
        channel.connectionStatus = observed.ready || observed.status != .idle ? observed.status : .unknown
        channel.idleSince = channel.connectionStatus == .idle ? (channel.idleSince ?? Date()) : nil
    }

    private func saveConnection(_ channel: Channel, _ target: AIHerdrConnection, replacing: Bool = true) throws {
        guard !discarded else { throw AIHerdrError.notReady }
        guard var record = channel.session else { throw AIHerdrError.notReady }
        record.connection = target
        try files.write(AIJSON.encode(record), to: sessionParts(channel), replacing: replacing)
        channel.session = record; channel.connection = target
    }

    private func commit(_ next: AIConversation) throws {
        try files.write(AIJSON.encode(next), to: base + ["state.json"])
        conversation = next
    }
    private func sessionParts(_ channel: Channel) -> [String] {
        base + AIEnvelope.sessionPath(slot: storedSlot(channel.slot), generation: channel.generation)
            .split(separator: "/").dropFirst().map(String.init)
    }
    private func launchPath(_ channel: Channel) -> [String] {
        var parts = sessionParts(channel)
        parts[parts.count - 1] = "\(channel.generation).launch.json"
        return parts
    }
    private func path(_ parts: [String]) -> URL { (base + parts).reduce(outputDirectory) { $0.appendingPathComponent($1) } }
}
