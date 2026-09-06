import Foundation
import KikigakiCore

/// 録音寿命より長く保持する、1会議の受信先。UIと音声engineへの依存は持たない。
/// ファイル保存を先に成功させた値だけを公開する。送信試行はherdr呼出しより先に記録する。
@MainActor
final class AIConversationController {
    let meetingID: UUID
    let outputDirectory: URL
    private(set) var conversation: AIConversation
    private(set) var connection: AIHerdrConnection?
    private(set) var connectionStatus: AIConnectionStatus = .unknown
    private(set) var warning: String?
    var onChange: (() -> Void)?
    private var history: AIStreamHistory
    private let store: AIFileStore
    private var monitor: AIInboxMonitor?
    private var polling = false
    private var sending = false
    private var idleSince: Date?
    private var preparedSnapshots: [UUID: AIContextSnapshot] = [:]
    private let herdr: AIHerdr
    private let allowsSending: Bool

    private var base: [String] { [".kikigaki-context", meetingID.uuidString, "ai"] }
    var canSend: Bool {
        allowsSending && !sending && !conversation.questions.contains { $0.isAwaitingResult || $0.state == .prepared }
    }

    init(meetingID: UUID, outputDirectory: URL, herdr: AIHerdr, recovered: AIConversation? = nil) throws {
        self.meetingID = meetingID; self.outputDirectory = outputDirectory; self.herdr = herdr
        allowsSending = recovered == nil
        store = AIFileStore(root: outputDirectory)
        history = try AIStreamHistory(meetingID: meetingID)
        conversation = recovered ?? AIConversation(meetingID: meetingID)
        guard conversation.meetingID == meetingID else { throw AIError.mismatch }
        for question in conversation.questions { try question.request.envelope.validatePaths(outputDirectory: outputDirectory) }
    }

    func watch() throws {
        guard monitor == nil else { return }
        let inbox = try store.directory(base + ["inbox"])
        monitor = AIInboxMonitor(directory: inbox) { [weak self] in
            guard let self else { return }
            self.scan()
            self.poll()
        }
    }

    /// 会話本文の切出しと3秒確定待ちは録音controller側。ここへ来る値は全て固定済み。
    func prepare(lines: [String], question: String, voiceQuestion: String, capturedAt: Date, cutoff: Double,
                 tail: AITentativeTail?, config: ResolvedAIConfig, helper: URL, parent: UUID? = nil,
                 full: Bool = false) throws -> AIRequest {
        guard canSend else { throw AIHerdrError.notReady }
        let snapshot = try history.prepare(lines: lines, outputDirectory: outputDirectory, full: full)
        let sessionPath = (base + ["sessions", "\(history.sessionGeneration).json"]).reduce(outputDirectory) { $0.appendingPathComponent($1) }
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(),
            sessionGeneration: history.sessionGeneration, participantName: config.participantName,
            cliPath: helper.path, sessionPath: sessionPath.path, requestToken: UUID().uuidString + UUID().uuidString,
            question: question, capturedAt: capturedAt, audioCutoffSeconds: cutoff, tentativeTail: tail,
            inReplyToRequestID: parent, inReplyToEventID: parent.map { "\($0.uuidString)/result" })
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant),
            number: conversation.questions.count + 1, voiceQuestion: voiceQuestion, snapshot: snapshot)
        // 再利用snapshotは内容一致だけを許す。予約したsequenceは保存失敗でも巻き戻さない。
        if preparedSnapshots[snapshot.id] == nil {
            try store.write(snapshot.contents, to: [".kikigaki-context", meetingID.uuidString, snapshot.id.uuidString + ".md"], replacing: false)
            preparedSnapshots[snapshot.id] = snapshot
        }
        try store.write(AIJSON.encode(request), to: base + ["requests", request.id.uuidString + ".json"], replacing: false)
        var next = conversation
        try next.append(request)
        try persist(next)
        return request
    }

    /// create応答喪失を再作成で補わない。利用者の明示的な再接続は別世代にする。
    func connect(config: ResolvedAIConfig, label: String, executable: URL, arguments: [String]) async throws {
        guard allowsSending else { throw AIHerdrError.notReady }
        guard connection == nil else { return }
        let attempt = base + ["sessions", "\(history.sessionGeneration).launch.json"]
        // 排他保存により、応答喪失後に同じ世代を再起動できない。
        try store.write(Data("{\"attempted\":true}".utf8), to: attempt, replacing: false)
        let created = try await herdr.create(cwd: config.cwd, label: label, provider: config.cli)
        connection = created
        try saveConnection()
        do { try await herdr.label(created, participant: config.participantName) }
        catch { warning = "herdrの表示名を設定できません" }
        try await herdr.start(created, executable: executable, arguments: arguments)
        poll()
    }

    func send(_ request: AIRequest, config: ResolvedAIConfig) async throws {
        guard allowsSending, !sending, let connection else { throw AIHerdrError.notReady }
        sending = true
        defer { sending = false; onChange?() }
        let observed = try await herdr.observe(connection)
        apply(observed)
        guard observed.ready else { throw AIHerdrError.notReady }
        var next = conversation
        try next.update(request.id) { try $0.beginSending(at: Date()) }
        try persist(next)
        do {
            try await herdr.prompt(connection, text: request.envelope.prompt(address: config.address, extraPrompt: config.prompt))
            // 待っている間にresultが届いていてもstateを巻き戻さない。
            next = conversation
            try next.update(request.id) { try $0.submitted() }
            try persist(next)
        } catch {
            warning = "送達を確認できません。ペインを確認してください"
            throw error
        }
    }

    func cancel(_ id: UUID) throws {
        var next = conversation
        try next.update(id) { try $0.cancel(at: Date()) }
        try persist(next)
    }

    func markRead(_ id: UUID) throws {
        var next = conversation
        try next.update(id) { $0.markRead() }
        try persist(next)
    }

    func showPane() async throws {
        guard let connection else { throw AIHerdrError.notReady }
        try await herdr.show(connection)
    }

    func scan() {
        let inbox = AIInbox(outputDirectory: outputDirectory)
        var next = conversation
        var changed = false
        for question in conversation.questions where question.sendAttemptedAt != nil {
            for suffix in ["accept", "result"] {
                let filename = question.request.id.uuidString + "." + suffix + ".json"
                let path = (base + ["inbox", filename]).reduce(outputDirectory) { $0.appendingPathComponent($1) }
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                do {
                    let event = try inbox.read(filename: filename, for: question.request)
                    if try next.receive(event, at: Date()) { changed = true }
                } catch { warning = "受信箱のイベントを検証できません: \(filename)" }
            }
        }
        if changed {
            do {
                try persist(next)
                for question in next.questions {
                    if question.acceptance != nil || question.result?.contextReceived == true {
                        let envelope = question.request.envelope
                        // 復元した旧会議は履歴を再接続しない。受信状態とMarkdown回収だけ行う。
                        if preparedSnapshots[envelope.snapshotID] != nil {
                            try history.acknowledge(snapshotID: envelope.snapshotID, streamID: envelope.participant.streamID,
                                sessionGeneration: envelope.participant.sessionGeneration)
                        }
                    }
                }
            } catch { warning = "回答の取り込み状態を保存できません" }
        }
        onChange?()
    }

    func isReturnUnconfirmed(_ question: AIQuestion, now: Date = Date(), backgroundRunning: Bool = false) -> Bool {
        AIReturnStatus.isUnconfirmed(question: question, connection: connectionStatus, idleSince: idleSince,
            now: now, hasRunningBackgroundTasks: backgroundRunning)
    }

    private func poll() {
        guard !polling, let connection else { return }
        polling = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.polling = false; self.onChange?() }
            do { self.apply(try await self.herdr.observe(connection)) }
            catch { self.connectionStatus = .disconnected; self.idleSince = nil }
        }
    }

    private func apply(_ observation: AIHerdrObservation) {
        if observation.status != .idle { idleSince = nil }
        else if idleSince == nil { idleSince = Date() }
        connectionStatus = observation.status
        if connection?.sessionID == nil, let session = observation.sessionID {
            connection?.sessionID = session
            do { try saveConnection() } catch { warning = "接続先を保存できません" }
        }
    }

    private func saveConnection() throws {
        try store.write(AIJSON.encode(connection), to: base + ["sessions", "\(history.sessionGeneration).connection.json"])
    }

    private func persist(_ next: AIConversation) throws {
        try store.write(AIJSON.encode(next), to: base + ["state.json"])
        conversation = next
        onChange?()
    }
}
