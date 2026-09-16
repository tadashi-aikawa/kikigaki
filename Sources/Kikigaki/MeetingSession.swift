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
    var accurateFinalCount: Int
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
    static let diarizationDefaultsKey = "KikigakiDiarizationEnabled"
    private let diarizationDefaults: UserDefaults?
    private var nextDiarizationEnabled: Bool

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
    private var audioLevelMeter: AudioLevelMeter?
    static let audioExclusionDefaultsKey = "KikigakiAudioExclusion"
    private var audioExclusion = AudioExclusion()
    private var showAudioLevels = false
    private var recopyInvalidated = false
    private struct AudioInterval: Hashable { let start: Double; let end: Double }
    private var cachedAudioLevels: [AudioInterval: Double?] = [:]
#if DEBUG
    private(set) var audioLevelCalculationCount = 0
#endif
    private var speakerMapping = SpeakerMapping()
    private var liveSource = SpeakerTranscript(accurateFinalCount: 0)
    private var lastUndiarizedDraw = -Double.infinity
    private var lastUndiarizedFinalCount = 0
    private var pendingUndiarizedDraw: Task<Void, Never>?
    private var typedEntries: [Utterance] = []
    private var finalTokens: [TimedToken] = []
    private var finalSegments: [SpeakerSegment] = []
    private var preparationID = UUID()
    private var handoff = HandoffHistory()
    private let diagnostics = Diagnostics()
    private let aiStore: AIRecordStore?
    private(set) var waitingMinutesPath: String?
    func previewMinutesStore() throws -> MinutesStore? {
        guard let url = snapshot.markdownURL, let aiStore else { return nil }
        let store = try aiStore.minutesStores.store(meetingID: handoff.meetingID, markdownURL: url)
        if let waiting = waitingMinutesPath {
            waitingMinutesPath = nil
            // 成否にかかわらず自動適用は1回。失敗はstoreの警告に残し、人が再確定する。
            do { try store.select(waiting) }
            catch { log("議事録の指定を引き継げません: \(error)") }
        }
        return store
    }
    func selectMinutes(_ path: String?) throws {
        if let store = try previewMinutesStore() { try store.select(path) }
        else {
            if let path { try MinutesPath.validate(path) }
            waitingMinutesPath = path
        }
        emit()
    }
    /// 開始シートが決めた議事録。**シートを出したら必ず設定し、「指定なし」も区別する。**
    /// 未指定(nil)なら、パス欄から置いた待機指定をそのまま使う。
    private struct PendingMinutes { let path: String? }
    private var pendingMinutes: PendingMinutes?
    /// 開始シートで決めた議事録。**この場では表示中の会議のstoreへ当てない。**
    /// 停止後も前の会議のMarkdownは残るので、いま当てると前の会議の議事録になってしまう。
    /// 次の録音の開始で待機指定へ移し、`previewMinutesStore` が引き継ぐ。
    func prepareMinutes(_ path: String?) throws {
        if let path { try MinutesPath.validate(path) }
        pendingMinutes = PendingMinutes(path: path)
    }
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
    private var rangeAutomaticSlot: Int?
#if DEBUG
    func setMinutesPreparationForTesting() {
        handoff = HandoffHistory()
        // start() と同じ順で、開始シートの指定を待機指定へ移す。
        if let pendingMinutes { waitingMinutesPath = pendingMinutes.path }
        pendingMinutes = nil
        snapshot = SessionSnapshot(state: .preparing)
    }
    func completeMinutesPreparationForTesting(at url: URL) throws {
        snapshot.state = .recording; snapshot.markdownURL = url
        _ = try previewMinutesStore()
    }
    private(set) var scheduleLinesBuildCount = 0
#endif
    private var aiScheduleTimer: Timer?
    private var aiScheduleHelper: URL?
    /// 同梱CLIの置き場。録音開始で自動送信を始めるときに使う。バンドル実行でない検証では差し替える
    var automaticHelper: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli")
    /// replayだけで使う間隔の上書き。分単位の設定値では実行時間に収まらない
    var automaticIntervalOverride: Double?
    /// 開始シートで決めた自動送信。**シートを出したら必ず設定する。**
    /// `slot` が nil なら「送らない」で、設定の `autoStart` も使わない。
    /// この値そのものは設定ファイルへ書き戻さず、次の録音へも持ち越さない。
    struct PendingAutomaticSchedule { let slot: Int?; let options: AIScheduleOptions? }
    var pendingAutomaticSchedule: PendingAutomaticSchedule?
    private var aiScheduleWarning: String?
    /// 開いている手動シートが持つ枠。抑制も譲りもこの枠だけに効かせる
    private var manualAISheetSlot: Int?
    private(set) var lastScheduleOptions: AIScheduleOptions?
    private var scheduleDrafts: [Int: AIScheduleSheet.Draft] = [:]
    func updateScheduleDraft(_ value: AIScheduleSheet.Draft, slot: Int) { scheduleDrafts[slot] = value }
    func scheduleDraft(for profile: ResolvedAIConfig) -> AIScheduleSheet.Draft {
        scheduleDrafts[profile.slot] ?? .init(prompt: profile.autoPrompt, minutes: profile.autoIntervalMinutes,
                                             workAllowed: profile.allowWork)
    }
    private enum AIPhase { case confirmationWait, preparingAndSending }
    private var aiPhases: [Int: AIPhase] = [:]
    private var pendingAIDispatch: [Int: UUID] = [:]
    /// requestの取消対象を、その送信を始めた所有者へ結び付ける。
    private var aiRequestOwners: [UUID: UUID] = [:]
    private var aiProgresses: [Int: String] = [:]
    /// 議事録プレビューの強調の基準。依頼の送信と編集の観測でだけ置き直す。
    private var minutesHighlight = MinutesHighlightBaseline()
    private var aiWarning: String?
    private(set) var aiDraft = ""
    /// 通常の手動依頼は自動と独立して宛先ごとに保持する。空文字も編集済みとして扱う。
    private var manualDrafts: [Int: String] = [:]
    func manualDraft(for profile: ResolvedAIConfig) -> String {
        manualDrafts[profile.slot] ?? profile.autoPrompt
    }
    func updateManualDraft(_ text: String, slot: Int) { manualDrafts[slot] = text }
    private(set) var aiWorkAllowed: Bool
    private var aiCompleted: UUID?
    private var consumedAudioTime: Double = 0
    var aiMeetingID: UUID { handoff.meetingID }
    var aiRecord: AIRecordStore.Record? { aiStore?.records[handoff.meetingID] }
    /// 取り止めの後始末が登録簿まで届いたかの検証に使う
    var aiStoreForTesting: AIRecordStore? { aiStore }
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

    /// この会議の保存先
    var aiContextRoot: URL? { snapshot.markdownURL?.deletingLastPathComponent() }

    /// 宛先ポップアップへ並べる項目
    var aiDestinationItems: [AIDestinationPicker.Item] {
        meetingAIProfiles.map { .init(slot: $0.slot, name: $0.name, avatar: $0.avatar) }
    }

    /// その枠を会議側が使っている(送信中)。
    func isAIBusy(slot: Int) -> Bool { aiTasks[slot] != nil }

    /// 会議をまたいで引き継がないAIの状態。録音開始のたびにここを通す。
    /// 宛先の選択も前の会議のものを残さない。
    private func resetMeetingAIState(_ meetingConfig: ResolvedConfig) {
        scheduleDrafts = [:]
        manualDrafts = [:]
        meetingAIProfiles = meetingConfig.aiProfiles
        meetingAI = meetingConfig.aiProfiles.first; scheduleAI = meetingConfig.aiProfiles.first
        aiDraft = ""; aiWarning = nil; aiCompleted = nil
        pendingAIDispatch = [:]
        aiRequestOwners = [:]
        minutesHighlight = MinutesHighlightBaseline()
        aiWorkAllowed = meetingConfig.ai?.allowWork ?? true
    }

    init(config: ResolvedConfig, models: @escaping () async throws -> SortformerModelStore.Loaded, log: @escaping (String) -> Void,
         aiStore: AIRecordStore? = nil, diarizationDefaults: UserDefaults? = nil) {
        self.config = config
        self.aiStore = aiStore; meetingAIProfiles = config.aiProfiles
        // 手動と自動の宛先はどちらも先頭で独立に初期化する。
        meetingAI = config.aiProfiles.first; scheduleAI = config.aiProfiles.first
        aiWorkAllowed = config.ai?.allowWork ?? true
        self.models = models
        self.log = log
        self.diarizationDefaults = diarizationDefaults
        nextDiarizationEnabled = diarizationDefaults?.object(forKey: Self.diarizationDefaultsKey) as? Bool ?? true
        if let data = diarizationDefaults?.data(forKey: Self.audioExclusionDefaultsKey),
           let saved = try? JSONDecoder().decode(AudioExclusion.self, from: data) { audioExclusion = saved }
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

    func setDiarizationEnabled(_ enabled: Bool) {
        guard snapshot.canChangeDiarization else { return }
        nextDiarizationEnabled = enabled
        diarizationDefaults?.set(enabled, forKey: Self.diarizationDefaultsKey)
        emit()
    }

    func setAudioExclusion(_ value: AudioExclusion) {
        guard snapshot.canChangeAudioExclusion, value != audioExclusion else { return }
        audioExclusion = value
        if let data = try? JSONEncoder().encode(value) { diarizationDefaults?.set(data, forKey: Self.audioExclusionDefaultsKey) }
        recopyInvalidated = true
        if archive != nil { archive?.original.audioExclusion = value; save() }
        emit()
    }

    /// 録音を始める。準備に失敗したら false(理由は snapshot.message とログ)
    @discardableResult
    func start(source: AudioSource) async -> Bool {
        guard snapshot.state.canStart else { return false }
        cancelAIPreparation()
        stopAISchedule()
        aiSchedule = nil; lastScheduleOptions = nil; aiScheduleWarning = nil
        rangeAutomaticSlot = nil
        let preparation = UUID()
        preparationID = preparation
        // 準備中や録音中の再読込で、同じ会議の保存方針を途中から切り替えない。
        let meetingConfig = config
        let diarizationEnabled = nextDiarizationEnabled
        resetMeetingAIState(meetingConfig)
        consumedAudioTime = 0
        dropRepeatedBackchannels = diarizationEnabled && meetingConfig.dropRepeatedBackchannels
        audioLevelMeter = AudioLevelMeter()
        cachedAudioLevels = [:]
        showAudioLevels = meetingConfig.measureAudioLevels
        recopyInvalidated = false
        // 開始・停止の進捗は状態チップに任せ、短時間のメッセージでヘッダーを伸縮させない。
        snapshot = SessionSnapshot(state: .preparing, speakers: config.speakers)
        // 開始シートの指定はここで待機指定へ移す。前の会議のMarkdownはもう snapshot にない。
        if let pendingMinutes { waitingMinutesPath = pendingMinutes.path }
        pendingMinutes = nil
        snapshot.names.diarizationEnabled = diarizationEnabled
        speakerMapping = SpeakerMapping()
        liveSource = SpeakerTranscript(accurateFinalCount: 0)
        pendingUndiarizedDraw?.cancel(); pendingUndiarizedDraw = nil
        lastUndiarizedDraw = -Double.infinity; lastUndiarizedFinalCount = 0
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
            let loaded = diarizationEnabled ? try await models() : nil
            // 反映はMainActorの同期処理。閉包の隔離を明示し、待つものが無い `await` を書かない。
            let onResult: ((TranscriptMerge.Snapshot) async -> Void)? = diarizationEnabled ? nil : { @MainActor [weak self] value in
                self?.publishUndiarized(value, generation: preparation)
            }
            let transcriber = try await AppleTranscriber(log: log, usesFastResults: true, onResult: onResult)
            let diarizer = loaded.map { SpeakerDiarizer(models: $0) }
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
            consumer = makeConsumer(stream: stream, transcriber: transcriber, diarizer: diarizer, wav: wav, generation: preparation)
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
            do { _ = try previewMinutesStore() }
            catch { snapshot.message = "議事録の設定を引き継げません。パスを指定し直してください" }
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
        pendingUndiarizedDraw?.cancel(); pendingUndiarizedDraw = nil
        snapshot.message = nil
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
        let final = snapshot.names.diarizationEnabled
            ? MeetingResult.make(tokens: tokens, segments: segments,
                                 dropRepeatedBackchannels: dropRepeatedBackchannels, mapping: speakerMapping)
            : MeetingResult.withoutDiarization(tokens: tokens)
        diagnostics.backchannelLines(tokens: tokens, candidates: final.candidates).forEach(log)
        diagnostics.phraseLines(tokens: tokens, segments: segments, speakers: final.speakers).forEach(log)

        let duration = Double(result.fedSamples) / 16000
        snapshot.timeline = pause.timeline
        let merged = TranscriptEntries.merge(voice: final.utterances, typed: typedEntries, timeline: snapshot.timeline).utterances
        let processed = final.processed.map { TranscriptEntries.merge(voice: $0, typed: typedEntries, timeline: snapshot.timeline).utterances }
        var meeting = MeetingMarkdown.Meeting(startedAt: startedAt, duration: duration, utterances: merged,
                                              names: snapshot.names, pauses: snapshot.timeline.pauses,
                                              audioLevels: audioLevelMeter?.track(includingPartial: true))
        meeting.audioExclusion = audioExclusion
        meeting.showAudioLevels = showAudioLevels
        if let url = snapshot.markdownURL {
            archive = MeetingArchive(original: meeting, processed: processed,
                                     candidateCount: final.candidates.count, markdownURL: url)
        }

        snapshot.state = .idle
        snapshot.utterances = merged
        snapshot.tentativeText = nil
        snapshot.pendingSpeakerRows = []
        snapshot.utteranceProgress = nil
        snapshot.elapsed = duration
        consumedAudioTime = duration
        traceUtteranceProgress(finalized: true)
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
        guard snapshot.canShare, snapshot.names.diarizationEnabled, (0..<SpeakerNames.slotCount).contains(slot) else { return }
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
        guard snapshot.canShare, snapshot.names.diarizationEnabled, snapshot.detectedSpeakerSlots.contains(source),
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
            if let copy = try handoff.copy(utterances: snapshot.includedUtterances, names: snapshot.names,
                                          outputDirectory: url.deletingLastPathComponent(), timeline: snapshot.timeline, full: full,
                                          writeClipboard: writeClipboard) {
                recopyInvalidated = false
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
        guard snapshot.canShare, !recopyInvalidated else { return }
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

    private func refreshAudioSnapshot() {
        let track = archive?.original.audioLevels ?? audioLevelMeter?.track()
        snapshot.audioExclusion = audioExclusion
        // 確定窓に収まった区間のP90は、その後の音声・設定・AI通知では変化しない。
        // 未到着はキャッシュせず、再分割で使わなくなった区間は解放する。
        var used = Set<AudioInterval>()
        func level(_ start: Double, _ end: Double) -> Double? {
            let key = AudioInterval(start: start, end: end)
            used.insert(key)
            if let value = cachedAudioLevels[key] { return value }
#if DEBUG
            audioLevelCalculationCount += 1
#endif
            let value = track?.level(start: start, end: end)
            if let track, end <= track.duration { cachedAudioLevels.updateValue(value, forKey: key) }
            return value
        }
        let assessments: [AudioLevelAssessment?] = snapshot.utterances.map { row in
            row.kind == .typed ? nil : AudioLevelAssessment(dbFS: level(row.start, row.end), exclusion: audioExclusion)
        }
        snapshot.excludedRows = audioExclusion.enabled
            ? Set(assessments.indices.filter { assessments[$0]?.isCandidate == true }) : []
        let pending = liveSource.tokens.dropFirst(min(liveSource.finalCount, liveSource.tokens.count))
        snapshot.tentativeExcluded = snapshot.tentativeText != nil && pending.first.flatMap { first in pending.last.map { last in
            audioExclusion.enabled && audioExclusion.belowThreshold(level(first.start, last.end))
        } } == true
        snapshot.audioLevels = (archive?.original.displaysAudioLevels ?? showAudioLevels)
            ? assessments : []
        cachedAudioLevels = cachedAudioLevels.filter { used.contains($0.key) }
    }

    private func emit() {
        snapshot.nextDiarizationEnabled = nextDiarizationEnabled
        refreshAudioSnapshot()
        snapshot.timeline = pause.timeline
        snapshot.handoffPreview = handoff.preview(utterances: snapshot.includedUtterances, names: snapshot.names, timeline: snapshot.timeline)
        snapshot.hasCopied = handoff.lastCopy != nil
        snapshot.canRecopy = snapshot.hasCopied && !recopyInvalidated
        snapshot.previousAIUnread = aiStore?.records.values.filter { $0.manifest.meetingID != handoff.meetingID }
            .reduce(0) { count, record in
                let questions = record.controller.conversation.questions
                return count + questions.filter { AIBadgeKind.confirmation.matches($0, in: questions) }.count
            } ?? 0
        snapshot.aiRecoveryWarning = aiStore?.warnings.first
        snapshot.aiSchedule = AIScheduleViewState(schedule: aiSchedule, warning: aiScheduleWarning,
            destination: meetingAIProfiles.count > 1 ? aiScheduleConfiguration?.name : nil,
            availability: scheduleAvailability, hasChanges: scheduleHasChanges)
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
            // 引数が多すぎると型検査が通らなくなるので、組み立ててから渡す。
            var state = AIViewState()
            state.rangeBoundaries = controller?.rangeBoundaries(slot: rangeAutomaticSlot, utterances: snapshot.utterances) ?? AIRangeBoundaries()
            state.conversation = controller?.conversation
            state.participant = config.participantName
            state.connection = connections[slot] ?? .unknown
            state.warning = aiWarning ?? aiRecord?.saveWarning ?? controller?.warning
            state.progress = aiProgresses[slot]
            state.isPreparing = !pendingAIDispatch.isEmpty
            let unconfirmed = controller?.conversation.questions.filter { controller!.isReturnUnconfirmed($0) } ?? []
            state.unconfirmed = Set(unconfirmed.map { $0.request.id })
            state.progressReports = controller?.progressReports ?? [:]
            // 編集の直前で基準を置き直し、送信後・編集前に人が触った分を強調へ混ぜない。
            minutesHighlight.observe(state.progressReports)
            state.minutesHighlightRevision = minutesHighlight.revision
            state.canSubmit = canSubmits[slot] ?? true
            state.submissionID = aiCompleted
            state.draft = aiDraft
            state.canOpenPane = openablePanes.contains(slot)
            state.canRecreate = controller != nil && aiTasks[slot] == nil
                && (aiWarning != nil || connections[slot] == .disconnected)
            state.saveFailed = aiRecord?.saveWarning != nil
            state.generation = generations[slot] ?? 1
            state.profiles = meetingAIProfiles.map { ($0.slot, $0.name) }
            state.selectedSlot = slot
            state.defaultSlot = controller?.defaultSlot ?? 1
            state.connections = connections
            state.generations = generations
            state.canSubmits = canSubmits
            state.progresses = progresses
            state.participants = participants
            state.openablePanes = openablePanes
            state.avatarSources = Dictionary(uniqueKeysWithValues: meetingAIProfiles.compactMap { profile in
                profile.avatar.map { (profile.slot, $0) }
            })
            state.modelLabels = Dictionary(uniqueKeysWithValues: meetingAIProfiles.map {
                ($0.slot, AIModelLabel(profile: $0))
            })
            snapshot.ai = state
        } else { snapshot.ai = nil }
        onChange?(snapshot)
    }

    private func save() {
        guard var archive else { return }
        let result = aiStore?.save(&archive, for: handoff.meetingID) ?? archive.save()
        self.archive = archive
        snapshot.utterances = result.utterances
        refreshAudioSnapshot()
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
        else {
            cancelledAutomaticOwners[slot] = aiSubmissionOwners[slot]
            pendingAIDispatch[slot] = nil
        }
    }

    func cancelAIPreparation(slot: Int? = nil) {
        let targets = slot.map { [$0] } ?? Array(aiTasks.keys) + aiSubmissionOwners.keys.filter { aiTasks[$0] == nil }
        for target in Set(targets) {
            aiSubmissionOwners[target] = UUID(); aiSubmissionTriggers[target] = nil
            aiTasks[target]?.cancel(); aiTasks[target] = nil
            aiPhases[target] = nil; aiProgresses[target] = nil
            pendingAIDispatch[target] = nil
        }
        guard let controller = aiRecord?.controller else { return }
        for q in controller.conversation.questions where q.state == .prepared {
            let owner = q.request.envelope.participant.profileSlot ?? controller.defaultSlot
            guard slot == nil || slot == owner else { continue }
            try? controller.cancel(q.request.id)
        }
    }

    func cancelAI(_ id: UUID) {
        do {
            let wasPrepared = aiRecord?.controller.conversation.questions.first(where: { $0.request.id == id })?.state == .prepared
            let owner = aiRequestOwners[id]
            try aiRecord?.controller.cancel(id)
            if wasPrepared, let owner, let question = aiRecord?.controller.conversation.questions.first(where: { $0.request.id == id }) {
                let slot = question.request.envelope.participant.profileSlot ?? aiRecord?.controller.defaultSlot ?? 1
                if pendingAIDispatch[slot] == owner { pendingAIDispatch[slot] = nil }
            }
        } catch { aiWarning = "取消を保存できません" }
        emit()
    }
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
        let lines = TranscriptRenderer.lines(snapshot.includedUtterances, names: snapshot.names, timeline: snapshot.timeline)
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
        // 確定待ち後のprepareでは遅い。人の書き先を送信操作の入口で固定する。
        // AI通知は表示対象だけを変えるので、この値へ混ぜない。
        let minutesPath: String?
        do { minutesPath = try aiStore.minutesStores.store(meetingID: meetingID, markdownURL: url).state.humanMinutesPath }
        catch { aiWarning = "議事録の書き先を確認できません"; emit(); return }
        let names = snapshot.names, timeline = snapshot.timeline, typed = typedEntries
        let exclusion = audioExclusion
        let workAllowed = suppliedWorkAllowed ?? aiWorkAllowed
        let owner = UUID(), scheduleRun = aiSchedule?.runID
        aiSubmissionOwners[slot] = owner; aiSubmissionTriggers[slot] = trigger
        pendingAIDispatch[slot] = owner
        if trigger == nil { aiDraft = question; aiCompleted = nil }
        aiWarning = nil; aiProgresses[slot] = "送信の準備中"
        aiPhases[slot] = .confirmationWait
        aiTasks[slot] = Task { [weak self] in
            guard let self else { return }
            var request: AIRequest?
            defer {
                if let request { aiRequestOwners[request.id] = nil }
                if meetingID == handoff.meetingID, aiSubmissionOwners[slot] == owner {
                    aiTasks[slot] = nil; aiPhases[slot] = nil; aiProgresses[slot] = nil; aiSubmissionTriggers[slot] = nil
                    if pendingAIDispatch[slot] == owner { pendingAIDispatch[slot] = nil }
                    observeAIScheduleResults(); emit()
                }
            }
            do {
                let record = try aiStore.begin(meetingID: meetingID, markdownURL: url, profiles: meetingAIProfiles)
                if let slot = rangeAutomaticSlot { aiStore.setAutomaticSlot(slot, for: record) }
                try record.controller.register(meetingAIProfiles)
                guard record.controller.canSend(slot: config.slot) else { throw AIHerdrError.notReady }
                if snapshot.state == .idle, var archive, record.archive == nil {
                    let saved = aiStore.save(&archive, for: meetingID); self.archive = archive
                    guard saved.succeeded else { throw AIError.unsafeFile }
                }
                let capture = try await AIConfirmationWait.capture(waitForFinalResults: !(transcriber?.hasFastResults ?? false), latest: {
                    guard self.handoff.meetingID == meetingID, self.snapshot.canShare else { throw CancellationError() }
                    if let transcriber = self.transcriber {
                        let latest = await transcriber.snapshot()
                        let tokens = latest.tokens, count = latest.finalCount
                        let speakers = names.diarizationEnabled
                            ? self.speakerMapping.apply(Aligner.speakers(for: tokens, segments: self.diarizer?.segments() ?? []))
                            : Array<Int?>(repeating: nil, count: tokens.count)
                        return try AICapture(tokens: tokens, speakers: speakers, finalCount: count, processedUntil: self.consumedAudioTime,
                            cutoff: cutoff, names: names, timeline: timeline, typed: typed,
                            audioExclusion: exclusion, audioLevels: self.audioLevelMeter?.track())
                    } else {
                        let speakers = names.diarizationEnabled
                            ? self.speakerMapping.apply(Aligner.speakers(for: self.finalTokens, segments: self.finalSegments))
                            : Array<Int?>(repeating: nil, count: self.finalTokens.count)
                        return try AICapture(tokens: self.finalTokens, speakers: speakers,
                            finalCount: self.finalTokens.count, processedUntil: self.snapshot.elapsed, cutoff: cutoff, names: names, timeline: timeline, typed: typed,
                            audioExclusion: exclusion, audioLevels: self.archive?.original.audioLevels ?? self.audioLevelMeter?.track())
                    }
                }, progress: { seconds in self.aiProgresses[slot] = "聞き取りの確定待ち · あと\(seconds)秒"; self.emit() })
                try Task.checkCancellation()
                guard aiSubmissionOwners[slot] == owner else { throw CancellationError() }
                guard consumedAudioTime >= cutoff else { throw AIError.invalid("audio not processed") }
                if question.isEmpty, capture.voiceExcluded {
                    aiWarning = "末尾の声は小音量のため除外されました。問いを入力するか、除外設定を調整してください"
                    return
                }
                if trigger == .scheduled, !record.controller.hasChanges(lines: capture.lines, slot: config.slot) { return }
                // prepareの通知から録音停止が始まっても、確定待ちの取消へ戻さない。
                aiPhases[slot] = .preparingAndSending
                let fixed = try record.controller.prepare(lines: capture.lines, question: question, voiceQuestion: capture.voice,
                    capturedAt: capturedAt, cutoff: cutoff, tail: capture.tail, config: config, helper: helper, parent: parent, full: full,
                    workAllowed: workAllowed, voiceUtteranceStart: capture.voiceUtteranceStart, trigger: trigger, minutesPath: minutesPath)
                request = fixed
                aiRequestOwners[fixed.id] = owner
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
                guard handoff.meetingID == meetingID, aiSubmissionOwners[slot] == owner else { throw CancellationError() }
                guard cancelledAutomaticOwners[slot] != owner else { throw CancellationError() }
                aiProgresses[slot] = "送信中"; emit()
                try await record.controller.send(fixed, config: config, willBeginSending: { [self] in
                    guard self.handoff.meetingID == meetingID, self.aiSubmissionOwners[slot] == owner,
                          self.cancelledAutomaticOwners[slot] != owner,
                          trigger != .scheduled || self.aiSchedule?.runID == scheduleRun else { throw CancellationError() }
                }, didBeginSending: { [self] sentAt in
                    guard self.handoff.meetingID == meetingID, self.aiSubmissionOwners[slot] == owner else { return }
                    if self.pendingAIDispatch[slot] == owner { self.pendingAIDispatch[slot] = nil }
                    // 議事録の強調は、この依頼で編集された箇所だけを残す。送った時点の本文を基準にする。
                    self.minutesHighlight.didSend(fixed.id)
                    if trigger == .scheduled, let scheduleRun {
                        self.aiSchedule?.didBeginSending(requestID: fixed.id, meetingID: meetingID, runID: scheduleRun, at: sentAt)
                        if CommandLine.arguments.contains("--replay"), ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_AUTO"] != nil {
                            FileHandle.standardError.write(Data("[schedule-dispatch] at=\(sentAt.timeIntervalSince1970) next=\(self.aiSchedule?.nextFire?.timeIntervalSince1970 ?? 0) request=\(fixed.id)\n".utf8))
                        }
                    }
                    self.emit()
                })
                if trigger == nil { aiDraft = ""; aiCompleted = fixed.id }
            } catch is CancellationError {
                if let request { try? aiStore.records[meetingID]?.controller.cancel(request.id) }
            } catch {
                if let request, aiStore.records[meetingID]?.controller.conversation.questions.first(where: { $0.request.id == request.id })?.state == .prepared {
                    try? aiStore.records[meetingID]?.controller.fail(request.id, reason: "入力前に停止しました。接続先と設定を確認してください")
                }
                log("AI送信に失敗(slot \(slot)): \(error)")
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
                     recordedSamples: Int = 0, finishAudio: @escaping () async -> Void = {}, diarizationEnabled: Bool = true) {
        self.init(config: config, models: { throw CancellationError() }, log: { _ in }, aiStore: aiStore)
        snapshot.state = .recording; snapshot.markdownURL = url
        snapshot.names.diarizationEnabled = diarizationEnabled
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
    /// 次の会議へ移った状態を作る。録音の全経路を通さずに、会議IDの入れ替わりと
    /// 会議をまたがない状態の初期化だけを再現する。録音中の状態も作り直す
    func beginNextMeetingForTesting(recording: Bool = false) {
        preparationID = UUID()
        handoff = HandoffHistory()
        resetMeetingAIState(config)
        if recording { snapshot.state = .recording }
    }
    var undiarizedResultHandlerForTesting: ([TimedToken], Int) -> Void {
        let generation = preparationID
        return { [weak self] tokens, count in
            self?.publishUndiarized(.init(tokens: tokens, finalCount: count, accurateFinalCount: count), generation: generation)
        }
    }
    var undiarizedSnapshotHandlerForTesting: (TranscriptMerge.Snapshot) -> Void {
        let generation = preparationID
        return { [weak self] value in self?.publishUndiarized(value, generation: generation) }
    }
    var pendingUndiarizedDrawForTesting: Task<Void, Never>? { pendingUndiarizedDraw }
    var submissionTaskForTesting: Task<Void, Never>? { aiTasks[meetingAI?.slot ?? 1] ?? aiTasks.values.first }
    func submissionTaskForTesting(slot: Int) -> Task<Void, Never>? { aiTasks[slot] }
    func publishForTesting(tokens: [TimedToken], speakers: [Int?], elapsed: Double,
                           finalCount: Int? = nil, accurateFinalCount: Int? = nil, frozenCount: Int = 0) {
        finalTokens = tokens
        finalSegments = zip(tokens, speakers).compactMap { token, slot in
            slot.map { SpeakerSegment(speaker: $0, start: token.start, end: token.end) }
        }
        receiveSpeakerState(segments: finalSegments)
        consumedAudioTime = elapsed
        publishLive(SpeakerTranscript(tokens: tokens, speakers: speakers, finalCount: finalCount ?? tokens.count,
                                     accurateFinalCount: accurateFinalCount ?? tokens.count, frozenCount: frozenCount), elapsed: elapsed)
    }
#endif

    private func tearDown() async {
        pendingUndiarizedDraw?.cancel(); pendingUndiarizedDraw = nil
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
        stream: AsyncStream<[Float]>, transcriber: AppleTranscriber, diarizer: SpeakerDiarizer?, wav: WavWriter?, generation: UUID
    ) -> Task<PipelineResult, Never> {
        let log = self.log
        // self を強く持つ。stop() が消費タスクの終了を待つので、タスクの寿命は会議の間だけ
        return Task.detached(priority: .userInitiated) {
            var result = PipelineResult()
            var lastDraw = Date.distantPast
            for await chunk in stream {
                result.fedSamples += chunk.count
                do { try wav?.write(chunk) } catch { log("WAV書き出しに失敗: \(error)") }
                do { try diarizer?.process(chunk) } catch { log("話者判別に失敗: \(error)") }
                do { try transcriber.feed(chunk) } catch { log("文字起こしへの入力に失敗: \(error)") }
                let consumed = Double(result.fedSamples) / 16000
                // 既存の供給後の更新へ計測を併せる。OFF時に供給前のMainActor待ちを増やさない。
                await MainActor.run {
                    guard self.preparationID == generation else { return }
                    self.audioLevelMeter?.append(chunk)
                    self.consumedAudioTime = consumed
                }

                guard Date().timeIntervalSince(lastDraw) >= 0.5 else { continue }
                lastDraw = Date()
                // 無効時の本文は結果通知だけで更新する。古いsnapshotが新しい確定結果を戻さない。
                guard let diarizer else {
                    await MainActor.run {
                        guard self.preparationID == generation,
                              self.snapshot.state == .recording || self.snapshot.state == .paused else { return }
                        self.snapshot.elapsed = consumed
                        self.emit()
                    }
                    continue
                }
                let latest = await transcriber.snapshot()
                let tokens = latest.tokens, finalCount = latest.finalCount
                let segments = diarizer.segments()
                let elapsed = Double(result.fedSamples) / 16000
                let speakers = Aligner.speakers(for: tokens, segments: segments, frozen: result.frozen)
                result.frozen = SpeakerFreeze.advance(
                    frozen: result.frozen, speakers: speakers, tokens: tokens, elapsed: elapsed, finalCount: latest.accurateFinalCount,
                    judgedUntil: diarizer.finalizedDuration)
                let live = SpeakerTranscript(tokens: tokens, speakers: speakers, finalCount: finalCount,
                                             accurateFinalCount: latest.accurateFinalCount, frozenCount: result.frozen.count)
                await MainActor.run {
                    self.receiveSpeakerState(segments: segments)
                    self.publishLive(live, elapsed: elapsed)
                }
            }
            return result
        }
    }

    /// 入力が止まった一時停止中にも確定を反映する。有効時の凍結列には触れない。
    private func publishUndiarized(_ value: TranscriptMerge.Snapshot, generation: UUID) {
        guard preparationID == generation, !snapshot.names.diarizationEnabled,
              snapshot.state == .recording || snapshot.state == .paused else { return }
        let newlyFinalized = value.finalCount > liveSource.finalCount
            || value.accurateFinalCount > liveSource.accurateFinalCount
        liveSource.tokens = value.tokens
        liveSource.finalCount = value.finalCount
        liveSource.accurateFinalCount = value.accurateFinalCount
        let remaining = 0.5 - (ProcessInfo.processInfo.systemUptime - lastUndiarizedDraw)
        if newlyFinalized || remaining <= 0 {
            pendingUndiarizedDraw?.cancel(); pendingUndiarizedDraw = nil
            flushUndiarized(generation: generation)
        } else if pendingUndiarizedDraw == nil {
            // 暫定だけをまとめる。最後の通知の後に入力が止まっても最新の暫定文字を反映する。
            let deadline = lastUndiarizedDraw + 0.5
            pendingUndiarizedDraw = Task { [weak self] in
                // MainActorが混んでTaskの開始が遅れても、そこからさらに0.5秒待たない。
                let delay = deadline - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard !Task.isCancelled, let self, self.preparationID == generation else { return }
                self.pendingUndiarizedDraw = nil
                self.flushUndiarized(generation: generation)
            }
        }
    }

    private func flushUndiarized(generation: UUID) {
        guard preparationID == generation, !snapshot.names.diarizationEnabled,
              snapshot.state == .recording || snapshot.state == .paused else { return }
        let newlyFinalized = liveSource.finalCount > lastUndiarizedFinalCount
        lastUndiarizedFinalCount = liveSource.finalCount
        lastUndiarizedDraw = ProcessInfo.processInfo.systemUptime
        refreshLive()
        diagnostics.liveTraceLines(snapshot.utterances, names: snapshot.names, elapsed: consumedAudioTime).forEach(log)
        emit()
        if diagnostics.showsLiveTrace && newlyFinalized {
            log(String(format: "[undiarized-final count=%d published=%.6f]", liveSource.finalCount, ProcessInfo.processInfo.systemUptime))
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
                                  finalCount: liveSource.finalCount, frozenCount: liveSource.frozenCount,
                                  diarizationEnabled: snapshot.names.diarizationEnabled)
        let merged = TranscriptEntries.merge(voice: live.utterances, typed: typedEntries, timeline: pause.timeline,
                                             pendingVoiceRows: live.pendingSpeakerRows,
                                             voiceProgress: live.progress(accurateFinalCount: liveSource.accurateFinalCount))
        snapshot.utterances = merged.utterances
        snapshot.tentativeText = live.tentativeText
        snapshot.pendingSpeakerRows = merged.pendingSpeakerRows
        snapshot.utteranceProgress = merged.progress
        traceUtteranceProgress(finalized: false)
    }

    private func traceUtteranceProgress(finalized: Bool) {
        diagnostics.utteranceProgressLines(snapshot.utteranceProgress, utterances: snapshot.utterances,
            elapsed: consumedAudioTime, diarizationEnabled: snapshot.names.diarizationEnabled, finalized: finalized).forEach(log)
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
    /// 録音開始と同時に自動送信を始める。
    ///
    /// 開始シートを出した会議は**シートの値だけ**を使う。「送らない」を選んだ会議では、
    /// 設定に `autoStart` があっても始めない。シートを出さないreplayと検証だけが設定を使う。
    /// 設定だけで決まる非対話の開始なので、接続先を解決できなければ理由を出して開始しない。
    func startAutomaticSchedule(now: Date = Date()) {
        let pending = pendingAutomaticSchedule
        pendingAutomaticSchedule = nil
        guard let helper = automaticHelper else { return }
        let profile: ResolvedAIConfig
        let prompt: String, interval: Double, workAllowed: Bool, sendFinal: Bool
        if let pending {
            guard let slot = pending.slot, let options = pending.options,
                  let chosen = meetingAIProfiles.first(where: { $0.slot == slot }) else { return }
            profile = chosen; prompt = options.prompt; interval = options.interval
            workAllowed = options.workAllowed; sendFinal = options.sendFinal
        } else {
            guard let configured = meetingAIProfiles.first(where: \.autoStart) else { return }
            profile = configured; prompt = configured.autoPrompt
            interval = Double(configured.autoIntervalMinutes) * 60
            workAllowed = configured.allowWork; sendFinal = true
        }
        do {
            // replayの秒指定は分の指定より優先する。実行時間に収めるための上書きのため。
            let options = try AIScheduleOptions(prompt: prompt, interval: automaticIntervalOverride ?? interval,
                                                workAllowed: workAllowed, sendFinal: sendFinal)
            try startAISchedule(options: options, helper: helper, now: now, profile: profile)
        } catch {
            aiScheduleWarning = "自動送信を開始できません。宛先と依頼を確認してください"
            log("自動送信を開始できません: \(error)")
        }
    }

    func startAISchedule(options: AIScheduleOptions, helper: URL, now: Date = Date(), profile: ResolvedAIConfig? = nil) throws {
        guard snapshot.state == .recording || snapshot.state == .paused, meetingAI != nil else {
            throw AIError.invalid("schedule recording state")
        }
        if let profile { scheduleAI = profile }
        var next = aiSchedule ?? AIScheduleState(meetingID: aiMeetingID)
        try next.start(options: options, now: now, runID: UUID())
        if let record = aiRecord, let slot = aiScheduleConfiguration?.slot { aiStore?.setAutomaticSlot(slot, for: record) }
        aiSchedule = next
        rangeAutomaticSlot = aiScheduleConfiguration?.slot
        lastScheduleOptions = options; aiScheduleHelper = helper; aiScheduleWarning = nil
        if let slot = aiScheduleConfiguration?.slot {
            updateScheduleDraft(.init(prompt: options.prompt, minutes: Int(options.interval / 60),
                                      workAllowed: options.workAllowed, sendFinal: options.sendFinal), slot: slot)
        }
        aiScheduleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.evaluateAISchedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        aiScheduleTimer = timer
        evaluateAISchedule(now: now, immediately: true)
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
            // 失敗・取消で終わった返答は返答済みと数えない。まだ返答できる確認は自動送信を止める。
            let questions = controller.conversation.questions
            if current.contains(where: { $0.state == .needsInput && !AIQuestion.isAnswered($0, in: questions) }) {
                return .confirmation
            }
        }
        return .ready
    }

    private var scheduleHasChanges: Bool {
        guard aiSchedule?.phase == .running else { return false }
#if DEBUG
        scheduleLinesBuildCount += 1
#endif
        let lines = TranscriptRenderer.lines(snapshot.includedUtterances, names: snapshot.names, timeline: snapshot.timeline)
        return aiRecord?.controller.hasChanges(lines: lines, slot: aiScheduleConfiguration?.slot) ?? !lines.isEmpty
    }

    func fireAIScheduleNow(now: Date = Date()) { evaluateAISchedule(now: now, immediately: true) }

    func evaluateAISchedule(now: Date = Date(), immediately: Bool = false) {
        guard let phase = aiSchedule?.phase, phase != .stopped else {
            aiScheduleTimer?.invalidate(); aiScheduleTimer = nil; return
        }
        observeAIScheduleResults()
        guard immediately || aiSchedule?.phase == .awaitingFinal ||
              (aiSchedule?.phase == .running && aiSchedule?.nextFire.map({ now >= $0 }) == true) else { return }
        let lines = TranscriptRenderer.lines(snapshot.includedUtterances, names: snapshot.names, timeline: snapshot.timeline)
        let changed = aiRecord?.controller.hasChanges(lines: lines, slot: aiScheduleConfiguration?.slot) ?? !lines.isEmpty
        let availability = scheduleAvailability
        let effect: AIScheduleState.Effect?
        if immediately {
            effect = aiSchedule?.fireNow(now: now, availability: availability, hasChanges: changed)
        } else if phase == .awaitingFinal {
            effect = aiSchedule?.finalDecision(availability: availability, hasChanges: changed)
        } else {
            effect = aiSchedule?.tick(now: now, availability: availability, hasChanges: changed)
        }
        if CommandLine.arguments.contains("--replay"), ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_AUTO"] != nil,
           let effect, effect != .none {
            let count = aiRecord?.controller.conversation.questions.count ?? 0
            FileHandle.standardError.write(Data("[schedule] \(effect) availability=\(availability) changed=\(changed) requests=\(count) at=\(now.timeIntervalSince1970) next=\(aiSchedule?.nextFire?.timeIntervalSince1970 ?? 0) immediate=\(immediately)\n".utf8))
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
    func setAudioTranscriptForTesting(_ utterances: [Utterance], meter: AudioLevelMeter, url: URL) {
        snapshot.state = .recording; snapshot.markdownURL = url
        snapshot.utterances = utterances; audioLevelMeter = meter
        cachedAudioLevels = [:]
        finalTokens = utterances.filter { $0.kind == .voice }.enumerated().map {
            TimedToken(text: $0.element.text, phraseId: $0.offset, start: $0.element.start, end: $0.element.end)
        }
        typedEntries = utterances.filter { $0.kind == .typed }
        consumedAudioTime = meter.track().duration; snapshot.elapsed = consumedAudioTime
        emit()
    }
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
