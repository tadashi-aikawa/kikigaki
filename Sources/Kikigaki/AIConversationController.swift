import Foundation
import KikigakiCore
import KikigakiAIIO

/// 1会議の直列トランザクション。外部起動と送信の前に意図を保存し、
/// 保存が成功するまで公開状態を変えない。回収用インスタンスには送信権限を与えない。
@MainActor
final class AIConversationController {
    let meetingID: UUID
    let outputDirectory: URL
    private(set) var conversation: AIConversation
    private(set) var connection: AIHerdrConnection?
    private(set) var connectionStatus: AIConnectionStatus = .unknown
    private(set) var warning: String?
    private(set) var invalidInboxFiles: [String] = []
    var onChange: (() -> Void)?
    var onResult: (() -> Void)?
    private var history: AIStreamHistory
    private let files: AIFileStore
    private let herdr: AIHerdr
    private let allowsSending: Bool
    private var configuration: ResolvedAIConfig?
    private var session: AISessionRecord?
    private var snapshots: Set<UUID> = []
    private var monitor: AIInboxMonitor?
    private var connecting = false
    private var launchingAttempted = false
    private var inputAttempted = false
    private var polling = false
    private var idleSince: Date?
    private var hookBackgroundRunning = false
    private(set) var isSending = false

    var generation: Int { history.sessionGeneration }
    var sessionURL: URL { path(["sessions", "\(generation).json"]) }
    var sessionToken: String? { session?.token }
    private var base: [String] { [".kikigaki-context", meetingID.uuidString, "ai"] }
    var canSend: Bool {
        allowsSending && !isSending && !connecting
            && (connection == nil ? !launchingAttempted : connectionStatus == .idle)
            && !conversation.questions.contains { $0.request.envelope.participant.sessionGeneration == generation && ($0.isAwaitingResult || $0.state == .prepared) }
    }

    init(meetingID: UUID, outputDirectory: URL, herdr: AIHerdr, recovered: AIConversation? = nil) throws {
        self.meetingID = meetingID; self.outputDirectory = outputDirectory; self.herdr = herdr
        files = AIFileStore(root: outputDirectory); allowsSending = recovered == nil
        conversation = recovered ?? AIConversation(meetingID: meetingID)
        history = try AIStreamHistory(meetingID: meetingID)
        guard conversation.meetingID == meetingID else { throw AIError.mismatch }
        // Codableの公開入口を通し、呼び手が作った値も復元と同じ整合検証を受ける。
        _ = try AIJSON.decode(AIConversation.self, from: AIJSON.encode(conversation))
        for q in conversation.questions { try q.request.envelope.validatePaths(outputDirectory: outputDirectory) }
    }

    func watch() throws {
        guard monitor == nil else { return }
        let inbox = try files.directory(base + ["inbox"])
        monitor = AIInboxMonitor(directory: inbox) { [weak self] in self?.scan(); self?.poll() }
    }

    func preview(lines: [String], full: Bool) throws -> AIContextSnapshot {
        var copy = history
        return try copy.prepare(lines: lines, outputDirectory: outputDirectory, full: full)
    }

    func prepare(lines: [String], question: String, voiceQuestion: String, capturedAt: Date, cutoff: Double,
                 tail: AITentativeTail?, config: ResolvedAIConfig, helper: URL, parent: UUID? = nil,
                 full: Bool = false, workAllowed: Bool? = nil, voiceUtteranceStart: Double? = nil) throws -> AIRequest {
        guard canSend else { throw AIHerdrError.notReady }
        if let configuration, configuration != config { throw AIError.mismatch }
        let snapshot = try history.prepare(lines: lines, outputDirectory: outputDirectory, full: full)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: generation,
            participantName: config.participantName, cliPath: helper.path, sessionPath: sessionURL.path,
            requestToken: UUID().uuidString + UUID().uuidString, question: question, capturedAt: capturedAt,
            audioCutoffSeconds: cutoff, tentativeTail: tail, inReplyToRequestID: parent,
            inReplyToEventID: parent.map { "\($0.uuidString)/result" }, workAllowed: workAllowed ?? config.allowWork)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant),
            number: conversation.questions.count + 1, voiceQuestion: voiceQuestion, snapshot: snapshot, voiceUtteranceStart: voiceUtteranceStart)
        var next = conversation
        try next.append(request)
        if session == nil {
            let record = AISessionRecord(schemaVersion: 1, meetingID: meetingID, generation: generation,
                provider: config.cli, token: UUID().uuidString + UUID().uuidString)
            session = record; configuration = config
        }
        if !snapshots.contains(snapshot.id) {
            try files.write(snapshot.contents, to: [".kikigaki-context", meetingID.uuidString, snapshot.id.uuidString + ".md"], replacing: false)
            snapshots.insert(snapshot.id)
        }
        try files.write(AIJSON.encode(request), to: base + ["requests", request.id.uuidString + ".json"], replacing: false)
        try commit(next)
        onChange?()
        return request
    }

    func connect(config: ResolvedAIConfig, label: String, executable: URL, arguments: [String], readinessTimeout: TimeInterval = 30) async throws {
        guard readinessTimeout.isFinite, readinessTimeout > 0 else { throw AIProcessError.invalidInput }
        guard allowsSending, !connecting, configuration == config, session != nil else { throw AIHerdrError.notReady }
        if connection != nil { try await waitUntilReady(timeout: readinessTimeout); return }
        guard !launchingAttempted else { throw AIHerdrError.notReady }
        connecting = true
        defer { connecting = false; onChange?() }
        try files.write(AIJSON.encode(Date()), to: base + ["sessions", "\(generation).launch.json"], replacing: false)
        launchingAttempted = true
        let created = try await herdr.create(cwd: config.cwd, label: label, provider: config.cli)
        try saveConnection(created, replacing: false)
        do { try await herdr.label(created, participant: config.participantName) }
        catch { warning = "herdrの表示名を設定できません" }
        try Task.checkCancellation()
        inputAttempted = true
        do { try await herdr.start(created, executable: executable, arguments: arguments, customCommand: config.command != nil, generation: generation) }
        catch AIHerdrError.server("agent_not_ready") { warning = "初回設定をherdrで確認してください" }
        catch { warning = "起動を確認できません。ペインを確認してください"; throw error }
        // pane run で起こした直後は herdr がまだagentを検知しておらず `agent get` が agent_not_found を返す
        // (実測: 初回の質問だけ「送信を完了できません」になった)。起動直後の待ちに限り、未検知は切断ではなく待ちとして扱う。
        try await waitUntilReady(timeout: readinessTimeout, tolerateMissing: true)
    }

    private func waitUntilReady(timeout: TimeInterval, tolerateMissing: Bool = false) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try Task.checkCancellation()
            do { try await refreshConnection() }
            catch AIHerdrError.missing where tolerateMissing { connectionStatus = .unknown }
            if connectionStatus == .idle { return }
            if connectionStatus == .blocked { throw AIHerdrError.notReady }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { warning = "入力準備を確認できません。herdrで確認してください"; throw AIProcessError.timeout }
            try await Task.sleep(for: .seconds(min(0.1, remaining)))
        } while true
    }

    func refreshConnection() async throws {
        guard let target = connection, inputAttempted else { throw AIHerdrError.notReady }
        let revision = generation
        do {
            let observed = try await herdr.observe(target)
            guard revision == generation, target.paneID == connection?.paneID else { return }
            try apply(observed)
        } catch {
            guard revision == generation, target.paneID == connection?.paneID else { return }
            idleSince = nil
            if error as? AIHerdrError == .replaced || error as? AIHerdrError == .missing { connectionStatus = .disconnected }
            else { connectionStatus = .unknown }
            throw error
        }
    }

    func send(_ supplied: AIRequest, config: ResolvedAIConfig) async throws {
        guard allowsSending, !isSending, !connecting, inputAttempted, configuration == config,
              let stored = conversation.questions.first(where: { $0.request.id == supplied.id }), stored.request == supplied,
              stored.state == .prepared, supplied.envelope.participant.sessionGeneration == generation else { throw AIHerdrError.notReady }
        isSending = true
        defer { isSending = false; onChange?() }
        let text = try stored.request.envelope.prompt(address: config.address, extraPrompt: config.prompt)
        try await refreshConnection()
        try Task.checkCancellation()
        guard connectionStatus == .idle, let target = connection else { throw AIHerdrError.notReady }
        do {
            try await herdr.prompt(target, text: text) { @MainActor [self] in
                // 最後の生存確認中の取消まで反映し、prompt直前に送信試行を保存する。
                var next = conversation
                try next.update(stored.request.id) { try $0.beginSending(at: Date()) }
                try commit(next)
            }
            var next = conversation
            try next.update(stored.request.id) { try $0.submitted() }
            try commit(next)
        } catch { warning = "送達を確認できません。ペインを確認してください"; throw error }
    }

    func cancel(_ id: UUID) throws { try change(id) { try $0.cancel(at: Date()) } }
    func markRead(_ id: UUID) throws { try change(id) { $0.markRead() } }
    func fail(_ id: UUID, reason: String) throws { try change(id) { try $0.failBeforeSending(reason) } }
    private func change(_ id: UUID, body: (inout AIQuestion) throws -> Void) throws {
        var next = conversation; try next.update(id, body); try commit(next); onChange?()
    }
    func showPane() async throws { guard let connection else { throw AIHerdrError.notReady }; try await herdr.show(connection) }

    /// 利用者の明示操作からだけ呼ぶ。旧質問は残し、新しいstreamを発行する。
    func newGeneration() throws {
        guard allowsSending, !isSending, !connecting, generation < Int.max else { throw AIHerdrError.notReady }
        let next = try AIStreamHistory(meetingID: meetingID, sessionGeneration: generation + 1)
        try files.write(AIJSON.encode(next.sessionGeneration), to: base + ["generation.json"])
        history = next; connection = nil; session = nil; snapshots = []; launchingAttempted = false; inputAttempted = false
        connectionStatus = .unknown; idleSince = nil; warning = nil; onChange?()
    }

    func scan() {
        invalidInboxFiles = []
        scanHooks()
        var events: [AIReceiveEvent] = []
        var scanWarning: String?
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
        var next = conversation, received = history
        var changed = false, resultArrived = false, notifyResult = false
        let now = Date()
        for event in events {
            do {
                if try next.receive(event, at: now) {
                    changed = true; resultArrived = resultArrived || event.kind != .accept
                    notifyResult = notifyResult || event.kind == .answered || event.kind == .needsInput
                    if event.contextReceived, snapshots.contains(event.snapshotID), event.sessionGeneration == generation {
                        try received.acknowledge(snapshotID: event.snapshotID, streamID: history.streamID, sessionGeneration: generation)
                    }
                }
            } catch { scanWarning = "受信箱の回答が既存記録と競合しています" }
        }
        if changed {
            do {
                try commit(next); history = received
                if resultArrived { warning = nil }
                if notifyResult { onResult?() }
            } catch { scanWarning = "回答の取り込み状態を保存できません" }
        }
        if let scanWarning { warning = scanWarning }
        onChange?()
    }
    func isReturnUnconfirmed(_ q: AIQuestion, now: Date = Date(), backgroundRunning: Bool = false) -> Bool {
        guard q.request.envelope.participant.sessionGeneration == generation else { return false }
        return AIReturnStatus.isUnconfirmed(question: q, connection: connectionStatus, idleSince: idleSince,
            now: now, hasRunningBackgroundTasks: backgroundRunning || hookBackgroundRunning)
    }
    private func scanHooks() {
        hookBackgroundRunning = false
        guard let session else { return }
        do {
            let inbox = try files.directory(base + ["inbox"], create: false)
            let names = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
            let identity = connection?.sessionID ?? (try? AIJSON.decode(String.self,
                from: files.read(base + ["sessions", "\(generation).identity.json"], limit: 2048)))
            var latest: AIHookObservation?
            for name in names where name.hasPrefix("notify-") && name.hasSuffix(".json") {
                do {
                    let event = try AIJSON.decode(AIHookObservation.self, from: files.read(base + ["inbox", name], limit: AILimits.eventBytes))
                    // 旧世代の診断も残すが、現世代の休止判定へ混ぜない。
                    guard event.generation == generation else { continue }
                    try event.validate(session: session)
                    guard event.filename == name else { throw AIError.mismatch }
                    guard let identity, event.sessionID == identity else { continue }
                    if latest == nil || event.recordedAt > latest!.recordedAt { latest = event }
                } catch { invalidInboxFiles.append(name) }
            }
            hookBackgroundRunning = latest?.runningBackgroundTasks == true
        } catch { warning = "フック観測を確認できません" }
    }
    private func poll() {
        guard !polling, connection != nil, inputAttempted else { return }
        polling = true
        Task { [weak self] in
            guard let self else { return }
            defer { polling = false; onChange?() }
            do { try await refreshConnection() } catch { /* 状態分類はrefreshConnectionで行う */ }
        }
    }
    private func apply(_ observed: AIHerdrObservation) throws {
        guard var target = connection else { return }
        if let expected = target.sessionID, let actual = observed.sessionID, expected != actual { throw AIHerdrError.replaced }
        if let expected = target.terminalID, let actual = observed.terminalID, expected != actual { throw AIHerdrError.replaced }
        target.sessionID = target.sessionID ?? observed.sessionID
        target.terminalID = target.terminalID ?? observed.terminalID
        if target != connection { try saveConnection(target) }
        connectionStatus = observed.ready || observed.status != .idle ? observed.status : .unknown
        idleSince = connectionStatus == .idle ? (idleSince ?? Date()) : nil
    }
    private func saveConnection(_ target: AIHerdrConnection, replacing: Bool = true) throws {
        guard var record = session else { throw AIHerdrError.notReady }
        record.connection = target
        try files.write(AIJSON.encode(record), to: base + ["sessions", "\(generation).json"], replacing: replacing)
        session = record; connection = target
    }
    private func commit(_ next: AIConversation) throws {
        try files.write(AIJSON.encode(next), to: base + ["state.json"])
        conversation = next
    }
    private func path(_ parts: [String]) -> URL { (base + parts).reduce(outputDirectory) { $0.appendingPathComponent($1) } }
}
