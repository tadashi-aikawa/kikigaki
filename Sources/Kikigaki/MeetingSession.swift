import FluidAudio
import Foundation
import KikigakiCore

/// 音声スレッド側の消費ループから読む一時停止フラグ
private final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var clock = RecordedAudioClock(startedAt: Date())
    var timeline: MeetingTimeline { lock.withLock { clock.timeline } }
    var audioTime: Double { lock.withLock { Double(clock.acceptedSamples) / 16000 } }

    func reset(startedAt: Date) { lock.withLock { clock = RecordedAudioClock(startedAt: startedAt) } }
    func pause() { lock.withLock { clock.pause(at: Date()) } }
    func resume() { lock.withLock { clock.resume(at: Date()) } }

    func accept(_ chunk: [Float], into continuation: AsyncStream<[Float]>.Continuation) {
        lock.withLock {
            // 計数とyieldを一体にして、再開操作をまたいでチャンクの位置が入れ替わらないようにする。
            if clock.accept(sampleCount: chunk.count) { continuation.yield(chunk) }
        }
    }
}

/// 消費ループが終了時に返すもの
private struct PipelineResult {
    var fedSamples = 0
    var frozen: [Int?] = []
}

private struct SpeakerTranscript {
    var tokens: [TimedToken] = []
    var speakers: [Int?] = []
    var finalCount = 0
    var frozenCount = 0
}

/// 会議1本の録音〜保存の流れ。音源→(WAV)+話者判別+文字起こし→突き合わせ→表示、停止で Markdown を保存
@MainActor
final class MeetingSession {
    private(set) var snapshot = SessionSnapshot()
    var onChange: ((SessionSnapshot) -> Void)?

    private var config: ResolvedConfig
    private let models: () async throws -> SortformerModelStore.Loaded
    private let log: (String) -> Void

    private var source: AudioSource?
    private var samplesIn: AsyncStream<[Float]>.Continuation?
    private var consumer: Task<PipelineResult, Never>?
    private var transcriber: AppleTranscriber?
    private var diarizer: SpeakerDiarizer?
    private var wav: WavWriter?
    private let pause = PauseFlag()
    private var startedAt = Date()
    /// 停止後に話者名を付け直して保存し直すために持つ
    private var archive: MeetingArchive?
    private var dropRepeatedBackchannels = false
    private var speakerMapping = SpeakerMapping()
    private var liveSource = SpeakerTranscript()
    private var typedEntries: [Utterance] = []
    private var finalTokens: [TimedToken] = []
    private var finalSegments: [SpeakerSegment] = []
    private var preparationID = UUID()
    private var handoff = HandoffHistory()
    private let diagnostics = Diagnostics()
    private let aiStore: AIRecordStore?
    /// 会議開始時に固定したプロファイル。並び順が宛先ポップアップの並びになる
    private(set) var meetingAIProfiles: [ResolvedAIConfig] = []
    /// 手動送信の宛先。会議内では前回の選択を覚える
    private var meetingAI: ResolvedAIConfig?
    /// 自動送信の宛先。手動と別に覚え、別プロファイルなら同時に使える
    private var scheduleAI: ResolvedAIConfig?
    /// 送信の進行はプロファイルごとに持つ。会議に1つだと、Aの確定待ちや起動待ちの間
    /// Bへ送れなくなり、手動と自動を同時に使えるという契約が崩れる。
    private var aiTasks: [Int: Task<Void, Never>] = [:]
    private var aiSubmissionOwners: [Int: UUID] = [:]
    private var aiSubmissionTriggers: [Int: AIParticipantContext.Trigger] = [:]
    private var cancelledAutomaticOwners: [Int: UUID] = [:]
    private var aiSchedule: AIScheduleState?
    private var aiScheduleTimer: Timer?
    private var aiScheduleHelper: URL?
    /// 同梱CLIの置き場。録音開始で自動送信を始めるときに使う。バンドル実行でない検証では差し替える
    var automaticHelper: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli")
    /// replayだけで使う間隔の上書き。分単位の設定値では実行時間に収まらない
    var automaticIntervalOverride: Double?
    private var aiScheduleWarning: String?
    /// 開いている手動シートが持つ枠。抑制も譲りもこの枠だけに効かせる
    private var manualAISheetSlot: Int?
    private(set) var lastScheduleOptions: AIScheduleOptions?
    private(set) var scheduleDraft: String?
    func updateScheduleDraft(_ value: String) { scheduleDraft = value }
    private enum AIPhase { case confirmationWait, preparingAndSending }
    private var aiPhases: [Int: AIPhase] = [:]
    private var aiProgresses: [Int: String] = [:]
    private var aiWarning: String?
    private(set) var aiDraft = ""
    private(set) var aiWorkAllowed: Bool
    private var aiCompleted: UUID?
    private var consumedAudioTime: Double = 0
    var aiMeetingID: UUID { handoff.meetingID }
    var aiRecord: AIRecordStore.Record? { aiStore?.records[handoff.meetingID] }
    var aiConfiguration: ResolvedAIConfig? { meetingAI }
    /// 自動送信の宛先。手動と独立に覚えるので、手動をBへ変えても自動はAのままにする
    var aiScheduleConfiguration: ResolvedAIConfig? { scheduleAI }
    /// ホットキーと共通設定を引く先。宛先の選択では動かない
    var aiPrimaryConfiguration: ResolvedAIConfig? { meetingAIProfiles.first }

    /// 宛先を選び直す。会議の固定プロファイルとその場限りの接続先だけを受け付ける。
    func selectAIProfile(slot: Int, forSchedule: Bool = false) {
        guard let profile = meetingAIProfiles.first(where: { $0.slot == slot }) else { return }
        if forSchedule { scheduleAI = profile } else { meetingAI = profile }
        emit()
    }

    /// そのrequestを送ったプロファイル。確認への返答は元質問の宛先へ固定する
    func aiProfile(forRequest id: UUID) -> ResolvedAIConfig? {
        guard let slot = aiRecord?.controller.conversation.questions.first(where: { $0.request.id == id })?
            .request.envelope.participant.profileSlot else { return nil }
        return meetingAIProfiles.first { $0.slot == slot }
    }

    /// 宛先ポップアップへ並べる項目。準備済みセッションの表示は段7で足す。
    var aiDestinationItems: [AIDestinationPicker.Item] {
        meetingAIProfiles.map { .init(slot: $0.slot, name: $0.name, prepared: nil) }
    }

    init(config: ResolvedConfig, models: @escaping () async throws -> SortformerModelStore.Loaded, log: @escaping (String) -> Void, aiStore: AIRecordStore? = nil) {
        self.config = config
        self.aiStore = aiStore; meetingAIProfiles = config.aiProfiles
        // 手動と自動の宛先はどちらも先頭で独立に初期化する。
        meetingAI = config.aiProfiles.first; scheduleAI = config.aiProfiles.first
        aiWorkAllowed = config.ai?.allowWork ?? true
        self.models = models
        self.log = log
        snapshot.speakers = config.speakers
        aiStore?.onChange = { [weak self] in self?.aiChanged() }
        emit()
    }

    /// 設定の再読込。次の会議から反映する(進行中の会議の保存先は開始時に確定済み)
    func update(config: ResolvedConfig) {
        self.config = config
        snapshot.speakers = config.speakers
        emit()
    }

    // MARK: - 操作

    /// 録音を始める。準備に失敗したら false(理由は snapshot.message とログ)
    @discardableResult
    func start(source: AudioSource) async -> Bool {
        guard snapshot.state.canStart else { return false }
        cancelAIPreparation()
        stopAISchedule()
        aiSchedule = nil; lastScheduleOptions = nil; scheduleDraft = nil; aiScheduleWarning = nil
        let preparation = UUID()
        preparationID = preparation
        // 準備中や録音中の再読込で、同じ会議の保存方針を途中から切り替えない。
        let meetingConfig = config
        // 宛先の選択とその場限りの接続先は会議をまたいで引き継がない。
        meetingAIProfiles = meetingConfig.aiProfiles
        meetingAI = meetingConfig.aiProfiles.first; scheduleAI = meetingConfig.aiProfiles.first
        aiDraft = ""; aiWarning = nil; aiCompleted = nil
        aiWorkAllowed = meetingConfig.ai?.allowWork ?? true
        consumedAudioTime = 0
        dropRepeatedBackchannels = meetingConfig.dropRepeatedBackchannels
        snapshot = SessionSnapshot(state: .preparing, speakers: config.speakers, message: "エンジンを準備中...")
        speakerMapping = SpeakerMapping()
        liveSource = SpeakerTranscript()
        typedEntries = []
        finalTokens = []
        finalSegments = []
        handoff = HandoffHistory()
        archive = nil
        emit()
        var reservation: URL?
        do {
            if source is MicSource, !(await MicSource.requestPermission()) {
                throw NSError(domain: "kikigaki", code: 3, userInfo: [NSLocalizedDescriptionKey: "マイクの使用が許可されていない。システム設定 > プライバシーとセキュリティ > マイク で KIKIGAKI を許可する"])
            }
            let models = try await models()
            let transcriber = try await AppleTranscriber(log: log)
            let diarizer = SpeakerDiarizer(models: models)
            guard snapshot.state == .preparing, preparationID == preparation else { return false }

            startedAt = Date()
            pause.reset(startedAt: startedAt)
            snapshot.timeline = pause.timeline
            handoff = HandoffHistory(startedAt: startedAt)
            try FileManager.default.createDirectory(at: meetingConfig.outputDir, withIntermediateDirectories: true)
            let markdownURL = try MeetingFiles.reserveMarkdownURL(in: meetingConfig.outputDir, startedAt: startedAt)
            reservation = markdownURL
            if meetingConfig.saveRecording {
                wav = try WavWriter(url: MeetingFiles.wavURL(for: markdownURL))
            }
            self.transcriber = transcriber
            self.diarizer = diarizer

            // バッファは無制限のまま。実時間より遅れると溜まるが、音声を捨てると時刻がずれて
            // 書き起こしが壊れるので、遅れは受け入れて停止時に全部処理する(M4 Pro で Sortformer fast +
            // SpeechTranscriber は実時間に十分追いつく。プロトで実測)
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            samplesIn = continuation
            consumer = makeConsumer(stream: stream, transcriber: transcriber, diarizer: diarizer, wav: wav)
            let pause = self.pause
            // 一時停止の判定は収録時(音声スレッド)に行う。消費側で判定すると、処理が遅れている間に
            // 収録した分が利用者の操作した境界とずれる
            try source.start { chunk in
                pause.accept(chunk, into: continuation)
            }
            self.source = source

            snapshot.state = .recording
            snapshot.markdownURL = markdownURL
            snapshot.message = nil
            startAutomaticSchedule()
            emit()
            return true
        } catch {
            guard preparationID == preparation, snapshot.state == .preparing else { return false }
            log("開始に失敗: \(error)")
            await tearDown()
            // 自分が確保した空の予約だけを片付ける。WAVや書き込み済みの本文は残す。
            if let reservation, (try? Data(contentsOf: reservation)) == Data() {
                do { try FileManager.default.removeItem(at: reservation) } catch { log("予約ファイルの片付けに失敗: \(error)") }
            }
            snapshot = SessionSnapshot(state: .idle, message: "開始に失敗: \(error.localizedDescription)")
            snapshot.speakers = config.speakers
            emit()
            return false
        }
    }

    func stop() async {
        guard snapshot.state.canStop else { return }
        aiSchedule?.recordingStopped()
        var finalizationSucceeded = true
        // 録音の停止で破棄するのは、まだ会話を確定していない問いだけ。
        // prepare以降は固定済みの会話を使い、最終保存と並行して接続・送信を続ける。
        for (slot, phase) in aiPhases where phase == .confirmationWait { cancelAIPreparation(slot: slot) }
        snapshot.state = .finishing
        snapshot.message = "最終判定と保存中..."
        emit()

        source?.stop()
        source = nil
        samplesIn?.finish()
        samplesIn = nil
        let result = await consumer?.value ?? PipelineResult()
        consumer = nil
        wav?.close()
        wav = nil

        var note: String?
        var tokens: [TimedToken] = []
        if let transcriber {
            do {
                tokens = try await transcriber.finish()
            } catch {
                // 最終化に失敗しても、それまでに得た確定・暫定トークンは残す(空の Markdown を書かない)
                finalizationSucceeded = false
                log("文字起こしの終了に失敗。取得済みの結果で保存する: \(error)")
                tokens = await transcriber.tokens()
                note = "文字起こしの最終化に失敗したため途中までの結果"
            }
        }
        var segments: [SpeakerSegment] = []
        if let diarizer {
            do { try diarizer.finish() } catch { finalizationSucceeded = false; log("話者判別の終了に失敗: \(error)") }
            segments = diarizer.segments()
            receiveSpeakerState(segments: segments)
            diarizer.cleanup()
        }
        transcriber = nil
        diarizer = nil
        finalTokens = tokens
        finalSegments = segments

        diagnostics.liveLines(snapshot.utterances, names: snapshot.names).forEach(log)
        let final = MeetingResult.make(tokens: tokens, segments: segments,
                                       dropRepeatedBackchannels: dropRepeatedBackchannels, mapping: speakerMapping)
        diagnostics.backchannelLines(tokens: tokens, candidates: final.candidates).forEach(log)
        diagnostics.phraseLines(tokens: tokens, segments: segments, speakers: final.speakers).forEach(log)

        let duration = Double(result.fedSamples) / 16000
        snapshot.timeline = pause.timeline
        let merged = TranscriptEntries.merge(voice: final.utterances, typed: typedEntries, timeline: snapshot.timeline).utterances
        let processed = final.processed.map { TranscriptEntries.merge(voice: $0, typed: typedEntries, timeline: snapshot.timeline).utterances }
        let meeting = MeetingMarkdown.Meeting(startedAt: startedAt, duration: duration, utterances: merged,
                                              names: snapshot.names, pauses: snapshot.timeline.pauses)
        if let url = snapshot.markdownURL {
            archive = MeetingArchive(original: meeting, processed: processed,
                                     candidateCount: final.candidates.count, markdownURL: url)
        }

        snapshot.state = .idle
        snapshot.utterances = merged
        snapshot.tentativeText = nil
        snapshot.pendingSpeakerRows = []
        snapshot.elapsed = duration
        consumedAudioTime = duration
        save()
        if aiSchedule?.finalSaveCompleted(succeeded: finalizationSucceeded && snapshot.saved) == .skipped(.saveFailed) {
            aiScheduleWarning = "保存が完了していないため最後の1回を中止しました"
        }
        evaluateAISchedule()
        if let note { snapshot.message = note + " / " + (snapshot.message ?? "") }
        emit()
    }

    func togglePause() {
        switch snapshot.state {
        case .recording:
            pause.pause()
            snapshot.state = .paused
        case .paused:
            pause.resume()
            snapshot.state = .recording
        default:
            return
        }
        refreshLive()
        emit()
    }

    /// 投稿受付からemitまでawaitを挟まない。停止より先に受理した行は最終保存に含める。
    @discardableResult
    func submitTyped(_ text: String) -> Bool {
        guard snapshot.canSubmitTyped,
              let entry = try? Utterance(typedText: text, at: pause.audioTime, postedAt: Date()) else { return false }
        typedEntries.append(entry)
        refreshLive()
        emit()
        return true
    }

    /// 枡に名前を付ける。停止後なら Markdown を保存し直す
    func rename(slot: Int, to name: String) {
        guard snapshot.canShare, (0..<SpeakerNames.slotCount).contains(slot) else { return }
        var names = snapshot.names
        names.set(name, for: slot)
        guard names != snapshot.names else { return }
        snapshot.names = names
        if archive != nil {
            archive?.original.names = names
            save()
        }
        emit()
    }

    func setSpeakerMapping(source: Int, target: Int?) {
        guard snapshot.canShare, snapshot.detectedSpeakerSlots.contains(source),
              target == nil || snapshot.detectedSpeakerSlots.contains(target!) else { return }
        speakerMapping.overrides[source] = target
        refreshSpeakerMapping()
        if archive != nil {
            let result = MeetingResult.make(tokens: finalTokens, segments: finalSegments,
                dropRepeatedBackchannels: dropRepeatedBackchannels, mapping: speakerMapping)
            archive?.replaceResult(result)
            save()
        } else {
            refreshLive()
        }
        emit()
    }

    func copyContext(full: Bool = false, writeClipboard: (String) -> Bool) {
        guard snapshot.canShare, let url = snapshot.markdownURL else { return }
        do {
            if let copy = try handoff.copy(utterances: snapshot.utterances, names: snapshot.names,
                                          outputDirectory: url.deletingLastPathComponent(), timeline: snapshot.timeline, full: full,
                                          writeClipboard: writeClipboard) {
                snapshot.handoffMessage = copy.preview.lineCount == 0
                    ? "会話の訂正をコピーしました"
                    : "\(snapshot.contextStartClock(copy.preview))以降をコピーしました。AIへ貼り付けられます"
            } else {
                snapshot.handoffMessage = "前回のコピーから会話の変更はありません"
            }
            snapshot.handoffFailed = false
        } catch {
            snapshot.handoffMessage = "コピーできません: \(error.localizedDescription)"
            snapshot.handoffFailed = true
        }
        emit()
    }

    func recopyContext(writeClipboard: (String) -> Bool) {
        guard snapshot.canShare else { return }
        do {
            guard try handoff.recopy(writeClipboard: writeClipboard) != nil else { return }
            snapshot.handoffMessage = "直前と同じ範囲をコピーしました"
            snapshot.handoffFailed = false
        } catch {
            snapshot.handoffMessage = "再コピーできません: \(error.localizedDescription)"
            snapshot.handoffFailed = true
        }
        emit()
    }

    // MARK: - 内部

    private func emit() {
        snapshot.timeline = pause.timeline
        snapshot.handoffPreview = handoff.preview(utterances: snapshot.utterances, names: snapshot.names, timeline: snapshot.timeline)
        snapshot.hasCopied = handoff.lastCopy != nil
        snapshot.previousAIUnread = aiStore?.records.values.filter { $0.manifest.meetingID != handoff.meetingID }
            .reduce(0) { $0 + $1.controller.conversation.questions.filter(\.isUnread).count } ?? 0
        snapshot.aiRecoveryWarning = aiStore?.warnings.first
        snapshot.aiSchedule = AIScheduleViewState(schedule: aiSchedule, warning: aiScheduleWarning,
            destination: meetingAIProfiles.count > 1 ? aiScheduleConfiguration?.name : nil)
        if let config = meetingAI {
            let controller = aiRecord?.controller
            let slot = config.slot
            // 各印の接続状態と現世代は、その質問を送った枠のものを渡す。選択中の宛先で全行を
            // 塗ると、Aを作り直しただけでBの正常な返事まで「旧接続から」になる。
            var connections: [Int: AIConnectionStatus] = [:], generations: [Int: Int] = [:]
            var canSubmits: [Int: Bool] = [:], progresses: [Int: String] = [:]
            var participants: [Int: String] = [:], openablePanes: Set<Int> = []
            for profile in meetingAIProfiles {
                connections[profile.slot] = controller?.connectionStatus(slot: profile.slot) ?? .unknown
                generations[profile.slot] = controller?.generation(slot: profile.slot) ?? 1
                canSubmits[profile.slot] = snapshot.canShare && aiTasks[profile.slot] == nil
                    && (controller?.canSend(slot: profile.slot) ?? true)
                progresses[profile.slot] = aiProgresses[profile.slot]
                participants[profile.slot] = profile.participantName
                if controller?.connection(slot: profile.slot) != nil { openablePanes.insert(profile.slot) }
            }
            snapshot.ai = AIViewState(conversation: controller?.conversation,
                // ホットキーは1つ目のプロファイルのものだけを使う。宛先を選び直しても変わらない。
                hotkey: meetingAIProfiles.first?.hotkey ?? config.hotkey,
                participant: config.participantName, connection: connections[slot] ?? .unknown,
                warning: aiWarning ?? aiRecord?.saveWarning ?? controller?.warning, progress: aiProgresses[slot],
                unconfirmed: Set(controller?.conversation.questions.filter { controller!.isReturnUnconfirmed($0) }.map { $0.request.id } ?? []),
                canSubmit: snapshot.canShare && aiTasks[slot] == nil && (controller?.canSend(slot: slot) ?? true),
                submissionID: aiCompleted, draft: aiDraft,
                canOpenPane: controller?.connection(slot: slot) != nil,
                canRecreate: controller != nil && aiTasks[slot] == nil
                    && (aiWarning != nil || connections[slot] == .disconnected),
                saveFailed: aiRecord?.saveWarning != nil, generation: generations[slot] ?? 1,
                profiles: meetingAIProfiles.map { ($0.slot, $0.name) }, selectedSlot: slot,
                defaultSlot: controller?.defaultSlot ?? 1, connections: connections, generations: generations,
                canSubmits: canSubmits, progresses: progresses,
                participants: participants, openablePanes: openablePanes)
        } else { snapshot.ai = nil }
        onChange?(snapshot)
    }

    private func save() {
        guard var archive else { return }
        let result = aiStore?.save(&archive, for: handoff.meetingID) ?? archive.save()
        self.archive = archive
        snapshot.utterances = result.utterances
        snapshot.message = result.message
        snapshot.saved = result.succeeded
        if !result.succeeded { log(result.message) }
    }

    func updateAIDraft(_ text: String) { aiDraft = text }
    func updateAIWorkAllowed(_ allowed: Bool) { aiWorkAllowed = allowed }
    /// シートが持つ枠を受け取る。確認への返答は元質問の枠で開くので、選択中の宛先とは限らない。
    func beginAIDraft(slot requested: Int? = nil) {
        let slot = requested ?? meetingAI?.slot
        manualAISheetSlot = slot
        // 手動へ譲るのは同じ宛先の自動だけ。別プロファイルの自動送信は止めない。
        if let slot { yieldAutomatic(slot: slot) }
        aiCompleted = nil
        emit()
    }
    func endAIDraft() { manualAISheetSlot = nil }
    func retryAISaves() { aiStore?.retrySaves() }

    /// 進行中の自動送信を手動へ譲る。送信試行済みのrequestは取り消さず、既存の返事待ちに従う。
    private func yieldAutomatic(slot: Int) {
        // 返事待ちの判定はこの枠だけで行う。会議全体で見ると、別プロファイルが返事待ちの間
        // 自動送信を止められず、停止したはずの依頼が接続完了後に飛ぶ。
        let awaiting = aiRecord?.controller.conversation.questions.contains {
            ($0.request.envelope.participant.profileSlot ?? aiRecord?.controller.defaultSlot ?? 1) == slot
                && $0.isAwaitingResult
        } ?? false
        guard aiSubmissionTriggers[slot] == .scheduled, aiTasks[slot] != nil, !awaiting else { return }
        if aiPhases[slot] == .confirmationWait || aiRecord?.controller.isSending == true { cancelAIPreparation(slot: slot) }
        else { cancelledAutomaticOwners[slot] = aiSubmissionOwners[slot] }
    }

    func cancelAIPreparation(slot: Int? = nil) {
        let targets = slot.map { [$0] } ?? Array(aiTasks.keys) + aiSubmissionOwners.keys.filter { aiTasks[$0] == nil }
        for target in Set(targets) {
            aiSubmissionOwners[target] = UUID(); aiSubmissionTriggers[target] = nil
            aiTasks[target]?.cancel(); aiTasks[target] = nil
            aiPhases[target] = nil; aiProgresses[target] = nil
        }
        guard let controller = aiRecord?.controller else { return }
        for q in controller.conversation.questions where q.state == .prepared {
            let owner = q.request.envelope.participant.profileSlot ?? controller.defaultSlot
            guard slot == nil || slot == owner else { continue }
            try? controller.cancel(q.request.id)
        }
    }

    func cancelAI(_ id: UUID) { do { try aiRecord?.controller.cancel(id) } catch { aiWarning = "取消を保存できません" }; emit() }
    func readAI(_ id: UUID) { do { try aiRecord?.controller.markRead(id) } catch { aiWarning = "既読を保存できません" }; emit() }
    func recreateAI() {
        do { try aiRecord?.controller.newGeneration(slot: meetingAI?.slot); aiWarning = nil }
        catch { aiWarning = "接続を作り直せません" }
        emit()
    }
    func showAIPane(slot requested: Int? = nil) {
        let slot = requested ?? meetingAI?.slot
        Task { do { try await aiRecord?.controller.showPane(slot: slot) } catch { aiWarning = "herdrのペインを開けません"; emit() } }
    }

    func aiRangePreview(full: Bool, slot: Int? = nil) -> String {
        let lines = TranscriptRenderer.lines(snapshot.utterances, names: snapshot.names, timeline: snapshot.timeline)
        guard let url = snapshot.markdownURL else { return "確定した会話はまだありません" }
        let context: AIContextSnapshot?
        if let controller = aiRecord?.controller { context = try? controller.preview(lines: lines, full: full, slot: slot ?? meetingAI?.slot) }
        else {
            var history = try? AIStreamHistory(meetingID: aiMeetingID)
            context = try? history?.prepare(lines: lines, outputDirectory: url.deletingLastPathComponent(), full: full)
        }
        guard let context, context.readLineCount > 0 else { return "追加の確定行なし · 送信時点で範囲を確定" }
        let time = context.timeRange.map { " · \($0.start)〜\($0.end)" } ?? ""
        return "対象: \(context.readStartLine)〜\(context.lines.count)行\(time) · 送信時に確定"
    }

    /// 手動と自動の共通入口。収録位置・宛先・問いは最初に固定し、待ち中の追加発話を混ぜない。
    func submitAI(question: String, full: Bool, parent: UUID?, helper: URL,
                  launch: ((ResolvedAIConfig, URL, AIConversationController) throws -> (URL, [String]))? = nil,
                  trigger: AIParticipantContext.Trigger? = nil, workAllowed suppliedWorkAllowed: Bool? = nil,
                  profile: ResolvedAIConfig? = nil) {
        // 確認への返答は元質問の宛先へ固定する。呼び手が別の宛先を渡していても、そちらを優先しない。
        let parentSlot = parent.flatMap { id in
            aiRecord?.controller.conversation.questions.first { $0.request.id == id }?
                .request.envelope.participant.profileSlot
        }
        let selected = parentSlot.flatMap { slot in meetingAIProfiles.first { $0.slot == slot } }
            ?? profile ?? (trigger == .scheduled ? aiScheduleConfiguration : meetingAI)
        guard snapshot.canShare, let config = selected, aiTasks[config.slot] == nil,
              let url = snapshot.markdownURL, let aiStore else { return }
        let slot = config.slot
        let meetingID = handoff.meetingID, capturedAt = Date(), cutoff = snapshot.state == .idle ? snapshot.elapsed : pause.audioTime
        let names = snapshot.names, timeline = snapshot.timeline, typed = typedEntries
        let workAllowed = suppliedWorkAllowed ?? aiWorkAllowed
        let owner = UUID(), scheduleRun = aiSchedule?.runID
        aiSubmissionOwners[slot] = owner; aiSubmissionTriggers[slot] = trigger
        if trigger == nil { aiDraft = question; aiCompleted = nil }
        aiWarning = nil; aiProgresses[slot] = "送信の準備中"
        aiPhases[slot] = .confirmationWait
        aiTasks[slot] = Task { [weak self] in
            guard let self else { return }
            var request: AIRequest?
            defer {
                if meetingID == handoff.meetingID, aiSubmissionOwners[slot] == owner {
                    aiTasks[slot] = nil; aiPhases[slot] = nil; aiProgresses[slot] = nil; aiSubmissionTriggers[slot] = nil
                    observeAIScheduleResults(); emit()
                }
            }
            do {
                let record = try aiStore.begin(meetingID: meetingID, markdownURL: url, profiles: meetingAIProfiles)
                try record.controller.register(meetingAIProfiles)
                guard record.controller.canSend(slot: config.slot) else { throw AIHerdrError.notReady }
                if snapshot.state == .idle, var archive, record.archive == nil {
                    let saved = aiStore.save(&archive, for: meetingID); self.archive = archive
                    guard saved.succeeded else { throw AIError.unsafeFile }
                }
                let capture = try await AIConfirmationWait.capture(latest: {
                    guard self.handoff.meetingID == meetingID, self.snapshot.canShare else { throw CancellationError() }
                    if let transcriber = self.transcriber {
                        let (tokens, count) = await transcriber.snapshot()
                        let speakers = self.speakerMapping.apply(Aligner.speakers(for: tokens, segments: self.diarizer?.segments() ?? []))
                        return try AICapture(tokens: tokens, speakers: speakers, finalCount: count, processedUntil: self.consumedAudioTime,
                            cutoff: cutoff, names: names, timeline: timeline, typed: typed)
                    } else {
                        return try AICapture(tokens: self.finalTokens, speakers: self.speakerMapping.apply(Aligner.speakers(for: self.finalTokens, segments: self.finalSegments)),
                            finalCount: self.finalTokens.count, processedUntil: self.snapshot.elapsed, cutoff: cutoff, names: names, timeline: timeline, typed: typed)
                    }
                }, progress: { seconds in self.aiProgresses[slot] = "聞き取りの確定待ち · あと\(seconds)秒"; self.emit() })
                try Task.checkCancellation()
                guard aiSubmissionOwners[slot] == owner else { throw CancellationError() }
                guard consumedAudioTime >= cutoff else { throw AIError.invalid("audio not processed") }
                if trigger == .scheduled, !record.controller.hasChanges(lines: capture.lines, slot: config.slot) { return }
                // prepareの通知から録音停止が始まっても、確定待ちの取消へ戻さない。
                aiPhases[slot] = .preparingAndSending
                let fixed = try record.controller.prepare(lines: capture.lines, question: question, voiceQuestion: capture.voice,
                    capturedAt: capturedAt, cutoff: cutoff, tail: capture.tail, config: config, helper: helper, parent: parent, full: full,
                    workAllowed: workAllowed, voiceUtteranceStart: capture.voiceUtteranceStart, trigger: trigger)
                request = fixed
                if trigger == .scheduled, let scheduleRun {
                    aiSchedule?.register(requestID: fixed.id, meetingID: meetingID, runID: scheduleRun)
                }
                let executable: URL, arguments: [String]
                if let launch { (executable, arguments) = try launch(config, helper, record.controller) }
                else {
                    let settings = try AILaunchConfiguration(config: config, helper: helper, controller: record.controller)
                    executable = settings.executable; arguments = settings.arguments
                }
                aiProgresses[slot] = "AIの入力準備を確認中。初回設定はherdrで確認してください"; emit()
                let format = DateFormatter(); format.dateFormat = "HH:mm"
                try await record.controller.connect(config: config, label: "KIKIGAKI \(config.participantName) \(format.string(from: startedAt))", executable: executable, arguments: arguments)
                try Task.checkCancellation()
                guard handoff.meetingID == meetingID else { throw CancellationError() }
                guard cancelledAutomaticOwners[slot] != owner else { throw CancellationError() }
                aiProgresses[slot] = "送信中"; emit()
                try await record.controller.send(fixed, config: config)
                if trigger == nil { aiDraft = ""; aiCompleted = fixed.id }
            } catch is CancellationError {
                if let request { try? aiStore.records[meetingID]?.controller.cancel(request.id) }
            } catch {
                if let request, aiStore.records[meetingID]?.controller.conversation.questions.first(where: { $0.request.id == request.id })?.state == .prepared {
                    try? aiStore.records[meetingID]?.controller.fail(request.id, reason: "入力前に停止しました。接続先と設定を確認してください")
                }
                if meetingID == handoff.meetingID { aiWarning = "送信を完了できません。herdrのペインと設定を確認してください" }
            }
        }
        emit()
    }

    private func aiChanged() {
        observeAIScheduleResults()
        if snapshot.state == .idle, let result = aiRecord?.saveResult {
            snapshot.saved = result.succeeded; snapshot.message = result.message
        }
        emit()
    }

#if DEBUG
    /// 音声エンジンを起動せず、送信と録音終了の競合を本番メソッドで検証するための初期状態。
    convenience init(testingRecordingAt url: URL, config: ResolvedConfig, aiStore: AIRecordStore,
                     recordedSamples: Int = 0, finishAudio: @escaping () async -> Void = {}) {
        self.init(config: config, models: { throw CancellationError() }, log: { _ in }, aiStore: aiStore)
        snapshot.state = .recording; snapshot.markdownURL = url
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        pause.accept(Array(repeating: 0, count: recordedSamples), into: continuation)
        continuation.finish()
        consumer = Task {
            for await _ in stream { }
            await finishAudio()
            return PipelineResult(fedSamples: recordedSamples)
        }
        emit()
    }
    var submissionTaskForTesting: Task<Void, Never>? { aiTasks[meetingAI?.slot ?? 1] ?? aiTasks.values.first }
    func submissionTaskForTesting(slot: Int) -> Task<Void, Never>? { aiTasks[slot] }
    func publishForTesting(tokens: [TimedToken], speakers: [Int?], elapsed: Double) {
        finalTokens = tokens
        finalSegments = zip(tokens, speakers).compactMap { token, slot in
            slot.map { SpeakerSegment(speaker: $0, start: token.start, end: token.end) }
        }
        receiveSpeakerState(segments: finalSegments)
        consumedAudioTime = elapsed
        publishLive(SpeakerTranscript(tokens: tokens, speakers: speakers, finalCount: tokens.count), elapsed: elapsed)
    }
#endif

    private func tearDown() async {
        source?.stop()
        source = nil
        samplesIn?.finish()
        samplesIn = nil
        _ = await consumer?.value
        consumer = nil
        wav?.close()
        wav = nil
        diarizer?.cleanup()
        diarizer = nil
        transcriber = nil
    }

    /// 音声を1本の消費タスクで処理する。WAV書き出し→話者判別→文字起こしの順に同じチャンクを流し、
    /// 0.5秒ごとに突き合わせて表示へ渡す。話者判定は `SpeakerFreeze` の猶予を過ぎた分から凍結する
    private func makeConsumer(
        stream: AsyncStream<[Float]>, transcriber: AppleTranscriber, diarizer: SpeakerDiarizer, wav: WavWriter?
    ) -> Task<PipelineResult, Never> {
        let log = self.log
        // self を強く持つ。stop() が消費タスクの終了を待つので、タスクの寿命は会議の間だけ
        return Task.detached(priority: .userInitiated) {
            var result = PipelineResult()
            var lastDraw = Date.distantPast
            for await chunk in stream {
                result.fedSamples += chunk.count
                do { try wav?.write(chunk) } catch { log("WAV書き出しに失敗: \(error)") }
                do { try diarizer.process(chunk) } catch { log("話者判別に失敗: \(error)") }
                do { try transcriber.feed(chunk) } catch { log("文字起こしへの入力に失敗: \(error)") }
                let consumed = Double(result.fedSamples) / 16000
                await MainActor.run { self.consumedAudioTime = consumed }

                guard Date().timeIntervalSince(lastDraw) >= 0.5 else { continue }
                lastDraw = Date()
                let (tokens, finalCount) = await transcriber.snapshot()
                let segments = diarizer.segments()
                let elapsed = Double(result.fedSamples) / 16000
                let speakers = Aligner.speakers(for: tokens, segments: segments, frozen: result.frozen)
                result.frozen = SpeakerFreeze.advance(
                    frozen: result.frozen, speakers: speakers, tokens: tokens, elapsed: elapsed, finalCount: finalCount,
                    judgedUntil: diarizer.finalizedDuration)
                let live = SpeakerTranscript(tokens: tokens, speakers: speakers, finalCount: finalCount, frozenCount: result.frozen.count)
                await MainActor.run {
                    self.receiveSpeakerState(segments: segments)
                    self.publishLive(live, elapsed: elapsed)
                }
            }
            return result
        }
    }

    private func receiveSpeakerState(segments: [SpeakerSegment]) {
        // 暫定区間が消えても、手動で指定した統合先を画面から確認・解除できるよう保持する。
        snapshot.detectedSpeakerSlots = Set(snapshot.detectedSpeakerSlots)
            .union(segments.map(\.speaker).filter { (0..<4).contains($0) }).sorted()
        refreshSpeakerMapping()
    }

    private func refreshSpeakerMapping() {
        snapshot.speakerOverrides = speakerMapping.overrides
        snapshot.speakerMapping = Dictionary(uniqueKeysWithValues: snapshot.detectedSpeakerSlots.compactMap { source in
            speakerMapping.destination(for: source).map { (source, $0) }
        })
    }

    private func refreshLive() {
        let live = LiveTranscript(tokens: liveSource.tokens, speakers: speakerMapping.apply(liveSource.speakers),
                                  finalCount: liveSource.finalCount, frozenCount: liveSource.frozenCount)
        let merged = TranscriptEntries.merge(voice: live.utterances, typed: typedEntries, timeline: pause.timeline,
                                             pendingVoiceRows: live.pendingSpeakerRows)
        snapshot.utterances = merged.utterances
        snapshot.tentativeText = live.tentativeText
        snapshot.pendingSpeakerRows = merged.pendingSpeakerRows
    }

    private func publishLive(_ live: SpeakerTranscript, elapsed: Double) {
        guard snapshot.state == .recording || snapshot.state == .paused else { return }
        liveSource = live
        refreshLive()
        snapshot.elapsed = elapsed
        diagnostics.liveTraceLines(snapshot.utterances, names: snapshot.names, elapsed: elapsed).forEach(log)
        emit()
    }
}

extension MeetingSession {
    /// `autoStart` のプロファイルがあれば、録音開始と同時に自動送信を始める。
    /// 設定だけで決まる非対話の開始なので、接続先を解決できなければ理由を出して開始しない。
    func startAutomaticSchedule(now: Date = Date()) {
        guard let profile = meetingAIProfiles.first(where: \.autoStart), let helper = automaticHelper else { return }
        do {
            let options = try AIScheduleOptions(prompt: profile.autoPrompt,
                interval: automaticIntervalOverride ?? Double(profile.autoIntervalMinutes) * 60,
                workAllowed: profile.allowWork, sendFinal: true)
            try startAISchedule(options: options, helper: helper, now: now, profile: profile)
        } catch {
            aiScheduleWarning = "設定の自動送信を開始できません。宛先と依頼を確認してください"
            log("autoStartを開始できません: \(error)")
        }
    }

    func startAISchedule(options: AIScheduleOptions, helper: URL, now: Date = Date(), profile: ResolvedAIConfig? = nil) throws {
        guard snapshot.state == .recording || snapshot.state == .paused, meetingAI != nil else {
            throw AIError.invalid("schedule recording state")
        }
        if let profile { scheduleAI = profile }
        if aiSchedule == nil { aiSchedule = AIScheduleState(meetingID: aiMeetingID) }
        try aiSchedule?.start(options: options, now: now, runID: UUID())
        lastScheduleOptions = options; aiScheduleHelper = helper; aiScheduleWarning = nil
        aiScheduleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.evaluateAISchedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        aiScheduleTimer = timer
        emit()
    }

    func stopAISchedule() {
        aiSchedule?.stop(); aiScheduleTimer?.invalidate(); aiScheduleTimer = nil
        if let slot = aiScheduleConfiguration?.slot { yieldAutomatic(slot: slot) }
        emit()
    }

    private var scheduleAvailability: AIScheduleAvailability {
        let controller = aiRecord?.controller
        let slot = aiScheduleConfiguration?.slot ?? 1
        if let controller, controller.connection(slot: slot) != nil {
            let status = controller.connectionStatus(slot: slot)
            if status == .disconnected || status == .blocked || status == .unknown { return .disconnected }
        }
        // 手動シートを開いている間に止めるのは、そのシートが持つ枠と同じときだけ。
        // 選択中の宛先で判定すると、Aへの返答シートを開いている間にBの自動送信が止まる。
        if aiTasks[slot] != nil || manualAISheetSlot == slot { return .busy }
        if let controller {
            let generation = controller.generation(slot: slot)
            let current = controller.conversation.questions.filter {
                ($0.request.envelope.participant.profileSlot ?? controller.defaultSlot) == slot
                    && $0.request.envelope.participant.sessionGeneration == generation
            }
            if current.contains(where: { $0.isAwaitingResult }) { return .awaitingResult }
            if !controller.canSend(slot: slot) { return controller.connectionStatus(slot: slot) == .working ? .busy : .disconnected }
            if current.contains(where: { $0.state == .needsInput && $0.answeredByRequestID == nil }) { return .confirmation }
        }
        return .ready
    }

    func evaluateAISchedule(now: Date = Date()) {
        guard let phase = aiSchedule?.phase, phase != .stopped else {
            aiScheduleTimer?.invalidate(); aiScheduleTimer = nil; return
        }
        observeAIScheduleResults()
        guard aiSchedule?.phase == .awaitingFinal ||
              (aiSchedule?.phase == .running && aiSchedule?.nextFire.map({ now >= $0 }) == true) else { return }
        let lines = TranscriptRenderer.lines(snapshot.utterances, names: snapshot.names, timeline: snapshot.timeline)
        let changed = aiRecord?.controller.hasChanges(lines: lines, slot: aiScheduleConfiguration?.slot) ?? !lines.isEmpty
        let availability = scheduleAvailability
        let effect: AIScheduleState.Effect?
        if phase == .awaitingFinal {
            effect = aiSchedule?.finalDecision(availability: availability, hasChanges: changed)
        } else {
            effect = aiSchedule?.tick(now: now, availability: availability, hasChanges: changed)
        }
        if CommandLine.arguments.contains("--replay"), ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_AUTO"] != nil,
           let effect, effect != .none {
            let count = aiRecord?.controller.conversation.questions.count ?? 0
            FileHandle.standardError.write(Data("[schedule] \(effect) availability=\(availability) changed=\(changed) requests=\(count)\n".utf8))
        }
        switch effect {
        case .send:
            if let options = aiSchedule?.options, let helper = aiScheduleHelper {
                submitAI(question: options.prompt, full: false, parent: nil, helper: helper,
                         trigger: .scheduled, workAllowed: options.workAllowed)
            }
        case .skipped(.disconnected): aiScheduleWarning = "接続できないため最後の1回を中止しました"
        default: break
        }
        emit()
    }

#if DEBUG
    func setScheduleTranscriptForTesting(_ text: String) {
        finalTokens = [.init(text: text, phraseId: 0, start: 0, end: 0)]
        snapshot.utterances = [.init(speaker: nil, start: 0, end: 0, text: text)]
        consumedAudioTime = 1; snapshot.elapsed = 1
        emit()
    }
#endif

    private func observeAIScheduleResults() {
        guard let run = aiSchedule?.runID, let controller = aiRecord?.controller else { return }
        for question in controller.conversation.questions where question.request.trigger == .scheduled {
            let outcome: AIScheduleState.Outcome?
            if let result = question.result {
                switch result.kind {
                case .answered: outcome = .answered
                case .needsInput: outcome = .needsInput
                case .failed: outcome = .failed
                case .accept: outcome = nil
                }
            } else if question.state == .failed { outcome = .failed }
            else if question.state == .deliveryUnknown && !controller.isSending { outcome = .deliveryUnknown }
            else { outcome = nil }
            if let outcome, aiSchedule?.observe(requestID: question.request.id, meetingID: aiMeetingID, runID: run, outcome: outcome) == .stoppedAfterFailures {
                aiScheduleWarning = "自動送信が3回続けて失敗したため停止しました"
                aiScheduleTimer?.invalidate(); aiScheduleTimer = nil
            }
        }
    }
}
