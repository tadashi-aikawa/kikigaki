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
    private(set) var waitingMinutesPath: String?
    private var appliedWaitingMinutes: (meetingID: UUID, path: String)?
    func previewMinutesStore() throws -> MinutesStore? {
        guard let url = snapshot.markdownURL, let aiStore else { return nil }
        let store = try aiStore.minutesStores.store(meetingID: handoff.meetingID, markdownURL: url)
        if let waiting = waitingMinutesPath {
            waitingMinutesPath = nil
            // 成否にかかわらず自動適用は1回。失敗はstoreの警告に残し、人が再確定する。
            do { try store.select(waiting); appliedWaitingMinutes = (handoff.meetingID, waiting) }
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
        appliedWaitingMinutes = nil
        handoff = HandoffHistory()
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
    /// 録音開始時の紐づけシートを出す間、`autoStart` の開始を保留する。
    /// 先に始めると、紐づける前の新しいセッションへ1回目が飛んでしまう
    var deferAutomaticStart = false {
        didSet { if oldValue != deferAutomaticStart { emit() } }
    }
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

    /// 準備済みセッションの表示と紐づけを担う台帳。アプリが差し込む
    weak var preparedStore: AIPreparedStore?

    /// 宛先ポップアップへ並べる項目。未紐づけの準備済みはプロファイルの下へ字下げして並べる。
    /// この会議の保存先。準備済みの返送許可がここへ向いているかの判定に使う
    var aiContextRoot: URL? { snapshot.markdownURL?.deletingLastPathComponent() }

    var aiDestinationItems: [AIDestinationPicker.Item] {
        meetingAIProfiles.map { profile in
            let prepared = (preparedStore?.available(for: profile, contextRoot: aiContextRoot) ?? []).map {
                AIDestinationPicker.Prepared(id: $0.id, label: preparedStore?.label($0, includingName: false) ?? "")
            }
            // 表題は台帳へ持たないので、閉じた表題も出すたびに解決する。
            let bound = boundPrepared[profile.slot].flatMap { preparedStore?.label(id: $0, includingName: false) }
            return .init(slot: profile.slot, name: profile.name, prepared: prepared, bound: bound, avatar: profile.avatar)
        }
    }

    /// 会議へ紐づけた準備済みセッションのid。表題ではなく識別子を持ち、表示時に解決する。
    /// 録音開始と接続の作り直しで消す
    private(set) var boundPrepared: [Int: UUID] = [:]

    /// その枠を会議側が使っている(送信中・準備中)。準備の起動と重ねないための判定
    func isAIBusy(slot: Int) -> Bool { aiTasks[slot] != nil || bindingSlots.contains(slot) }

    /// 紐づけの最中の枠。確定するまで送信させない。
    /// 画面は選んだ先を出すのに送信は前の宛先へ飛ぶ、という食い違いを作らないため
    private(set) var bindingSlots: Set<Int> = []

    /// 台帳が変わったので表示を作り直す。表題は台帳へ持たないので、出すたびに引き直す
    func refreshPrepared() { emit() }

    /// 会議をまたいで引き継がないAIの状態。録音開始のたびにここを通す。
    /// 宛先の選択も、紐づけた準備済みの表示も、前の会議のものを残さない。
    private func resetMeetingAIState(_ meetingConfig: ResolvedConfig) {
        scheduleDrafts = [:]
        manualDrafts = [:]
        meetingAIProfiles = meetingConfig.aiProfiles
        meetingAI = meetingConfig.aiProfiles.first; scheduleAI = meetingConfig.aiProfiles.first
        boundPrepared = [:]
        aiDraft = ""; aiWarning = nil; aiCompleted = nil
        pendingAIDispatch = [:]
        aiRequestOwners = [:]
        aiWorkAllowed = meetingConfig.ai?.allowWork ?? true
    }

    /// フッターの一行。「準備済み: 議事録 13:05 · 相談 13:10」。3件を超えたら畳む。
    /// 台帳が読めないときは、1件も無い状態と区別して理由を出す。
    private var preparedSummary: String {
        guard let store = preparedStore else { return "" }
        guard store.isUsable else { return store.warningText }
        let rows = store.unbound
        guard !rows.isEmpty else { return "" }
        var shown: [String] = []
        for row in rows.prefix(3) {
            let time: String = AIPreparedStore.clock.string(from: row.startedAt)
            shown.append((row.name ?? row.profileName) + " " + time)
        }
        let rest: Int = rows.count - shown.count
        let tail: String = rest > 0 ? " ほか\(rest)件" : ""
        return "準備済み: " + shown.joined(separator: " · ") + tail
    }
    private var preparedDetail: String {
        guard let store = preparedStore, store.isUsable else { return "" }
        return store.unbound.map { store.label($0) }.joined(separator: "\n")
    }

    /// 録音開始時の選択をまとめて当てる。**引き継げなかった枠を返す。**
    /// 全部済むまで `autoStart` の保留を解かない。失敗した枠のまま進めると、
    /// 下ごしらえを持たない新規セッションへ自動送信の1回目が飛ぶ。
    func applyPreparedSelection(_ selection: [Int: UUID?]) async -> Set<Int> {
        let meetingID = handoff.meetingID
        var failed: Set<Int> = []
        for (slot, id) in selection.sorted(by: { $0.key < $1.key }) {
            guard handoff.meetingID == meetingID else { return failed }
            guard let profile = meetingAIProfiles.first(where: { $0.slot == slot }) else { continue }
            guard let id else {
                // 「新規に起動する」。途中まで引き継いだ接続が残っていたら手放す。
                // 残すと、新規を選んだのに準備済みのペインへ送ってしまう。
                if !releasePreparedBinding(slot: slot) { failed.insert(slot) }
                continue
            }
            if await adoptPrepared(id, profile: profile) == false { failed.insert(slot) }
        }
        guard handoff.meetingID == meetingID else { return failed }
        guard failed.isEmpty else { return failed }
        deferAutomaticStart = false
        if snapshot.state == .recording || snapshot.state == .paused { startAutomaticSchedule() }
        return []
    }

    /// 「新規に起動する」を選んだ枠の後始末。台帳の保存に失敗して途中まで引き継いだ接続を手放す。
    /// 台帳の紐づけが成功している枠は手放さない(そちらは正しく使われている)。
    /// - Returns: 手放せた、または手放すものが無ければ true
    @discardableResult
    private func releasePreparedBinding(slot: Int) -> Bool {
        guard let controller = aiRecord?.controller, controller.hasAdopted(slot: slot),
              boundPrepared[slot] == nil else { return true }
        do { try controller.releaseAdopted(slot: slot); emit(); return true }
        catch {
            aiWarning = "準備済みAIセッションの引き継ぎを解除できません"
            log("引き継ぎの解除に失敗: \(error)")
            emit()
            return false
        }
    }

    /// 準備済みセッションをこの会議のチャネルへ引き継ぐ。
    /// **会議側の保存が成功してから**台帳へ `bound` を書く。逆順にすると、台帳では使用済みなのに
    /// 会議側に接続が無い行が残る。
    @discardableResult
    func adoptPrepared(_ id: UUID, profile: ResolvedAIConfig, forSchedule: Bool = false) async -> Bool {
        guard let store = preparedStore, let aiStore, let url = snapshot.markdownURL,
              let prepared = store.unbound.first(where: { $0.id == id }) else { return false }
        // awaitを跨いで会議が入れ替わることがある(接続確認中に停止して次の録音を始める)。
        // 会議IDを固定し、各await後に照合して、古い処理が次の会議へ書き込まないようにする。
        let meetingID = handoff.meetingID
        // 失敗したら戻す送信先。選び直しの表示もここへ揃える。
        let previous = (forSchedule ? scheduleAI?.slot : meetingAI?.slot) ?? profile.slot
        bindingSlots.insert(profile.slot); emit()
        defer { bindingSlots.remove(profile.slot); emit() }
        do {
            let record = try aiStore.begin(meetingID: meetingID, markdownURL: url, profiles: meetingAIProfiles)
            if let slot = rangeAutomaticSlot { aiStore.setAutomaticSlot(slot, for: record) }
            // 紐づけの前に会議の全プロファイルを登録する。1つだけ登録すると保存パスが平置きになり、
            // あとで他の枠が登録された時点で参照先が枝つきへ変わって、CLIがsessionを読めなくなる。
            try record.controller.register(meetingAIProfiles)
            // 同じ枠に、台帳へ書けなかった別の引き継ぎが残っていることがある。
            // 先に手放さないと、別の準備済みを選び直せない(adoptが拒否する)。
            if record.controller.hasAdopted(slot: profile.slot), boundPrepared[profile.slot] == nil,
               record.controller.sessionToken(slot: profile.slot) != prepared.token {
                try record.controller.releaseAdopted(slot: profile.slot)
            }
            // 同じ枠に、台帳へ書けなかった別の引き継ぎが残っていることがある。
            // 先に手放さないと、別の準備済みを選び直せない(adoptが拒否する)。
            try await record.controller.adopt(prepared, config: profile)
            guard handoff.meetingID == meetingID else { return false }
            // 台帳へは保存済みcontrollerの会議IDを書く。await後の現在の会議ではない。
            try store.bind(id, to: record.controller.meetingID, config: profile)
            boundPrepared[profile.slot] = id
            // 選んだ枠を送信先にする。表示だけ変えて送信先が元のままになるのを防ぐ。
            selectAIProfile(slot: profile.slot, forSchedule: forSchedule)
            emit()
            return true
        } catch {
            guard handoff.meetingID == meetingID else { return false }
            // 表示と送信先を同じ枠へ戻す。画面だけ移って送信は元の宛先、という状態を残さない。
            selectAIProfile(slot: previous, forSchedule: forSchedule)
            aiWarning = "準備済みAIセッションを引き継げません"
            log("準備済みセッションの引き継ぎに失敗: \(error)")
            emit()
            return false
        }
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
        appliedWaitingMinutes = nil
        // 前回の取り止めで片付けきれなかったものがあれば、ここでもう一度片付ける。
        retryDiscard()
        cancelAIPreparation()
        stopAISchedule()
        aiSchedule = nil; lastScheduleOptions = nil; aiScheduleWarning = nil
        rangeAutomaticSlot = nil
        let preparation = UUID()
        preparationID = preparation
        // 準備中や録音中の再読込で、同じ会議の保存方針を途中から切り替えない。
        let meetingConfig = config
        resetMeetingAIState(meetingConfig)
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

    /// 録音そのものを取り止める。**保存しない**。予約したMarkdownとWAV、AIの置き場も残さない。
    /// 紐づけシートの「取消(録音を始めない)」から呼ぶ。表示している契約と動きを揃えるため、
    /// 通常の停止(最終判定して保存する)とは別の道にしてある。
    ///
    /// 片付けは**記録が先、実体が後**。逆順にすると、消えた会議の登録や使用済みのままの
    /// 紐づけだけが残り、設計文書の表で「起きない」としている状態を作ってしまう。
    func abandon() async {
        guard snapshot.state == .recording || snapshot.state == .paused else { return }
        stopAISchedule()
        for slot in aiPhases.keys { cancelAIPreparation(slot: slot) }
        let markdownURL = snapshot.markdownURL
        let meetingID = handoff.meetingID
        // 片付け先は会議に固定したMarkdownの親から組み立てる。録音中に保存先を再読込しても、
        // この会議が書いた場所は変わらない。
        let outputDir = markdownURL?.deletingLastPathComponent() ?? config.outputDir
        snapshot.state = .finishing
        snapshot.message = "録音を取り止め中..."
        emit()
        await tearDown()
        let leftover = Discarded(meetingID: meetingID, outputDir: outputDir, markdownURL: markdownURL)
        guard cleanUp(leftover) else {
            // 片付けられないものが残る。実体は消さず、やり直せる状態のままにする。
            pendingDiscards[meetingID] = leftover
            snapshot.state = .idle
            snapshot.message = "録音を取り止めましたが、AIの記録を片付けられませんでした。保存先を確認してください"
            aiWarning = "取り止めた会議のAIの記録が残っています"
            emit()
            return
        }
        if let applied = appliedWaitingMinutes, applied.meetingID == meetingID {
            waitingMinutesPath = applied.path; appliedWaitingMinutes = nil
        }
        archive = nil; finalTokens = []; finalSegments = []; typedEntries = []
        consumedAudioTime = 0
        handoff = HandoffHistory()
        resetMeetingAIState(config)
        snapshot = SessionSnapshot(state: .idle, speakers: config.speakers, message: "録音を取り止めました")
        emit()
    }

    /// 片付けきれなかった取り止め。**会議ごとに持つ。** 1つだけだと、続けて取り止めに
    /// 失敗したときに古い会議が再試行の対象から消える
    private struct Discarded { let meetingID: UUID; let outputDir: URL; let markdownURL: URL? }
    private var pendingDiscards: [UUID: Discarded] = [:]
    /// 片付け残しがあるか。表示と検証に使う
    var hasPendingDiscard: Bool { !pendingDiscards.isEmpty }

    /// 取り止めた会議の後始末。記録を外せなければ実体を消さず false を返す。
    /// **実体を消せなかったときも false。** 「取消で何も残らない」を満たせていないため。
    private func cleanUp(_ target: Discarded) -> Bool {
        // 登録簿と監視を外す。実体だけ消すと、再起動時に無いmanifestを回収しようとして失敗する。
        let unregistered = aiStore?.discard(meetingID: target.meetingID) ?? true
        // 紐づけ済みの準備済みは未紐づけへ戻す。会議が無くなった以上、次の録音でまた選べるべき。
        let unbound = preparedStore?.unbindAll(meetingID: target.meetingID) ?? true
        guard unregistered, unbound else { return false }
        var removed = true
        // 予約したMarkdownは中身が無いときだけ消す。書き込み済みのものは触らない。
        if let markdownURL = target.markdownURL {
            if (try? Data(contentsOf: markdownURL))?.isEmpty ?? false {
                do { try FileManager.default.removeItem(at: markdownURL) }
                catch { log("予約の片付けに失敗: \(error)"); removed = false }
            }
            let wav = MeetingFiles.wavURL(for: markdownURL)
            if FileManager.default.fileExists(atPath: wav.path) {
                do { try FileManager.default.removeItem(at: wav) }
                catch { log("録音の片付けに失敗: \(error)"); removed = false }
            }
        }
        // この会議のAIの置き場も残さない。
        let context = target.outputDir.appendingPathComponent(".kikigaki-context")
            .appendingPathComponent(target.meetingID.uuidString)
        if FileManager.default.fileExists(atPath: context.path) {
            do { try FileManager.default.removeItem(at: context) }
            catch { log("AIの置き場の片付けに失敗: \(error)"); removed = false }
        }
        return removed
    }

    /// 片付けきれなかった取り止めをもう一度片付ける。次の録音開始でも通る。
    /// 片付いた会議から順に外し、残ったものは次の機会へ持ち越す。
    @discardableResult
    func retryDiscard() -> Bool {
        guard !pendingDiscards.isEmpty else { return true }
        for (meetingID, pending) in pendingDiscards where cleanUp(pending) {
            pendingDiscards[meetingID] = nil
        }
        if pendingDiscards.isEmpty { aiWarning = nil }
        emit()
        return pendingDiscards.isEmpty
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
                // 同じ枠で準備を起こしている間は送らせない。別の枠は止めない。
                canSubmits[profile.slot] = snapshot.canShare && aiTasks[profile.slot] == nil
                    && !deferAutomaticStart
                    && !bindingSlots.contains(profile.slot)
                    && preparedStore?.launching.contains(profile.slot) != true
                    && (controller?.canSend(slot: profile.slot) ?? true)
                progresses[profile.slot] = aiProgresses[profile.slot]
                participants[profile.slot] = profile.participantName
                if controller?.connection(slot: profile.slot) != nil { openablePanes.insert(profile.slot) }
            }
            // 引数が多すぎると型検査が通らなくなるので、組み立ててから渡す。
            var state = AIViewState()
            state.rangeBoundaries = controller?.rangeBoundaries(slot: rangeAutomaticSlot, utterances: snapshot.utterances) ?? AIRangeBoundaries()
            state.conversation = controller?.conversation
            // ホットキーは1つ目のプロファイルのものだけを使う。宛先を選び直しても変わらない。
            state.hotkey = meetingAIProfiles.first?.hotkey ?? config.hotkey
            state.participant = config.participantName
            state.connection = connections[slot] ?? .unknown
            state.warning = aiWarning ?? aiRecord?.saveWarning ?? controller?.warning
            state.progress = aiProgresses[slot]
            state.isPreparing = !pendingAIDispatch.isEmpty
            let unconfirmed = controller?.conversation.questions.filter { controller!.isReturnUnconfirmed($0) } ?? []
            state.unconfirmed = Set(unconfirmed.map { $0.request.id })
            state.canSubmit = canSubmits[slot] ?? true
            state.submissionID = aiCompleted
            state.draft = aiDraft
            state.canOpenPane = openablePanes.contains(slot)
            state.canRecreate = controller != nil && aiTasks[slot] == nil
                && (aiWarning != nil || connections[slot] == .disconnected)
            state.saveFailed = aiRecord?.saveWarning != nil
            state.generation = generations[slot] ?? 1
            state.canPrepare = preparedStore?.isUsable ?? false
            state.preparedSummary = preparedSummary
            state.preparedToolTip = preparedDetail
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
            snapshot.ai = state
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
        // 作り直した接続は準備済みのものではない。以前の表題を残さない。
        if let slot = meetingAI?.slot { boundPrepared[slot] = nil }
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
        guard snapshot.canShare, !deferAutomaticStart, let config = selected, aiTasks[config.slot] == nil,
              // 同じ枠の準備を起こしている最中は送らない。起動と送信が同じ枠で重なると、
              // どちらの接続が正本か決まらなくなる。
              preparedStore?.launching.contains(config.slot) != true, !bindingSlots.contains(config.slot),
              let url = snapshot.markdownURL, let aiStore else { return }
        let slot = config.slot
        let meetingID = handoff.meetingID, capturedAt = Date(), cutoff = snapshot.state == .idle ? snapshot.elapsed : pause.audioTime
        // 確定待ち後のprepareでは遅い。人の書き先を送信操作の入口で固定する。
        // AI通知は表示対象だけを変えるので、この値へ混ぜない。
        let minutesPath: String?
        do { minutesPath = try aiStore.minutesStores.store(meetingID: meetingID, markdownURL: url).state.humanMinutesPath }
        catch { aiWarning = "議事録の書き先を確認できません"; emit(); return }
        let names = snapshot.names, timeline = snapshot.timeline, typed = typedEntries
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
    /// 次の会議へ移った状態を作る。録音の全経路を通さずに、会議IDの入れ替わりと
    /// 会議をまたがない状態の初期化だけを再現する。録音中の状態も作り直す
    func beginNextMeetingForTesting(recording: Bool = false) {
        handoff = HandoffHistory()
        resetMeetingAIState(config)
        if recording { snapshot.state = .recording }
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
        guard !deferAutomaticStart else { return }
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
        // 準備の起動中も同じ枠は塞がっている扱いにする。送信すると起動と競合する。
        if aiTasks[slot] != nil || manualAISheetSlot == slot || bindingSlots.contains(slot)
            || preparedStore?.launching.contains(slot) == true { return .busy }
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
        let lines = TranscriptRenderer.lines(snapshot.utterances, names: snapshot.names, timeline: snapshot.timeline)
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
        let lines = TranscriptRenderer.lines(snapshot.utterances, names: snapshot.names, timeline: snapshot.timeline)
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
