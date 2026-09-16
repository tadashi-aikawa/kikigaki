import AppKit
import FluidAudio
import KikigakiCore
import KikigakiAIIO

/// replayだけで使う開発用入力。通常起動では環境変数自体を解釈しない。
struct ReplayDebugOptions {
    var diarizationEnabled: Bool?
    struct Question { let seconds: Double; let text: String }
    var questions: [Question] = []
    var hold: Double = 0
    var rename: (slot: Int, name: String)?
    struct TypedEntry: Decodable { let seconds: Double; let text: String; let pauseSeconds: Double? }
    var typedEntries: [TypedEntry] = []
    var verifyTyped = false
    var verifyMinutes: String?
    var automatic: AIScheduleOptions?
    /// 設定の `autoStart` を短い間隔で試すための上書き。分単位の設定ではreplayに収まらない
    var automaticSeconds: Double?
    /// 手動送信の宛先。自動と別のプロファイルへ同時に送ることを試す
    var askProfile: String?
    @MainActor static func recoverForNextQuestion(_ controller: AIConversationController?, preparing: Bool) throws {
        guard !preparing, let controller, !controller.canSend,
              let previous = controller.conversation.questions.last,
              previous.state == .failed || previous.state == .cancelled else { return }
        try controller.newGeneration()
    }
    static func load(arguments: [String] = CommandLine.arguments, environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.contains("--replay") else { return Self() }
        var result = Self()
        if let mode = env["KIKIGAKI_DEBUG_DIARIZATION"] {
            guard ["on", "off"].contains(mode) else { throw AIError.invalid("KIKIGAKI_DEBUG_DIARIZATION") }
            result.diarizationEnabled = mode == "on"
        }
        if let mode = env["KIKIGAKI_DEBUG_MINUTES_VERIFY"] {
            guard ["main", "outside"].contains(mode) else { throw AIError.invalid("KIKIGAKI_DEBUG_MINUTES_VERIFY") }
            result.verifyMinutes = mode
        }
        if let input = env["KIKIGAKI_DEBUG_AI_AUTO"] {
            let pair = input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let seconds = Double(pair[0]) else {
                throw AIError.invalid("KIKIGAKI_DEBUG_AI_AUTO")
            }
            result.automatic = try AIScheduleOptions(prompt: String(pair[1]), interval: seconds)
        }
        if let input = env["KIKIGAKI_DEBUG_AI_ASK"], !input.isEmpty {
            for entry in input.split(separator: ";", omittingEmptySubsequences: false) {
                let pair = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, let seconds = Double(pair[0]), seconds.isFinite, seconds >= 0 else {
                    throw AIError.invalid("KIKIGAKI_DEBUG_AI_ASK")
                }
                result.questions.append(Question(seconds: seconds, text: String(pair[1])))
            }
            result.questions = result.questions.enumerated().sorted {
                $0.element.seconds == $1.element.seconds ? $0.offset < $1.offset : $0.element.seconds < $1.element.seconds
            }.map(\.element)
        }
        if let input = env["KIKIGAKI_DEBUG_AI_AUTO_SECONDS"] {
            guard let seconds = Double(input), seconds.isFinite, seconds > 0, seconds <= 3600 else {
                throw AIError.invalid("KIKIGAKI_DEBUG_AI_AUTO_SECONDS")
            }
            result.automaticSeconds = seconds
        }
        if let input = env["KIKIGAKI_DEBUG_AI_ASK_PROFILE"] {
            // 長い宛名から補ったプロファイル名も指定できるよう、長さは制限しない。
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.contains("\0"),
                  !input.contains(where: \.isNewline) else {
                throw AIError.invalid("KIKIGAKI_DEBUG_AI_ASK_PROFILE")
            }
            result.askProfile = input
        }
        if let input = env["KIKIGAKI_DEBUG_REPLAY_HOLD"] {
            guard let seconds = Double(input), seconds.isFinite, (0...86400).contains(seconds) else {
                throw AIError.invalid("KIKIGAKI_DEBUG_REPLAY_HOLD")
            }
            result.hold = seconds
        }
        if let input = env["KIKIGAKI_DEBUG_AI_RENAME"] {
            let pair = input.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let slot = Int(pair[0]), (0..<SpeakerNames.slotCount).contains(slot) else {
                throw AIError.invalid("KIKIGAKI_DEBUG_AI_RENAME")
            }
            result.rename = (slot, String(pair[1]))
        }
        if let input = env["KIKIGAKI_DEBUG_TYPED_ENTRIES"] {
            let entries = try JSONDecoder().decode([TypedEntry].self, from: Data(input.utf8))
            guard entries.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0
                && ($0.pauseSeconds.map { $0.isFinite && $0 > 0 && $0 <= 60 } ?? true)
                && (try? Utterance(typedText: $0.text, at: $0.seconds, postedAt: Date(timeIntervalSince1970: 0))) != nil }) else {
                throw AIError.invalid("KIKIGAKI_DEBUG_TYPED_ENTRIES")
            }
            result.typedEntries = entries.enumerated().sorted {
                $0.element.seconds == $1.element.seconds ? $0.offset < $1.offset : $0.element.seconds < $1.element.seconds
            }.map(\.element)
        }
        if let input = env["KIKIGAKI_DEBUG_TYPED_VERIFY"] {
            guard ["0", "1"].contains(input) else { throw AIError.invalid("KIKIGAKI_DEBUG_TYPED_VERIFY") }
            result.verifyTyped = input == "1"
        }
        return result
    }
}

/// 全体の配線。設定の読み込み、モデルの先読み、メニュー・ウィンドウとセッションの接続
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var window: TranscriptWindowController?
    private var session: MeetingSession?
    private var config: ResolvedConfig?
    /// Sortformer モデルの先読み。開始操作を待たせないよう起動直後に走らせる
    private var modelsTask: Task<SortformerModelStore.Loaded, Error>?
    /// `--replay <wav>`: マイクの代わりに音声ファイルを流し、流し終えたら保存して終了する(開発用)
    private var replayURL: URL?
    /// 停止処理(最終判定と保存)の最中に終了操作を受けたら、保存が終わってから終了する
    private var terminateWhenIdle = false
    private var aiStore: AIRecordStore?
    private(set) var aiSheet: AIQuestionSheet?
    private(set) var scheduleSheet: AIScheduleSheet?
    private var scheduleSheetMeetingID: UUID?
    private var aiSheetMeetingID: UUID?
    /// 確認への返答シートが固定している枠。通常のシートはnilで選択中の宛先へ追随する
    private var aiSheetSlot: Int?
    private var previousAI: AIPastMeetingsWindow?
    /// 開いている開始シート。録音を始めるまでは何も起きていない
    private(set) var startSheet: StartSheet?
    private let replayDebug: ReplayDebugOptions
    private var nextDebugQuestion = 0
    private var nextDebugTyped = 0
    private var debugTypedPausing = false
    private var replayHolding = false
    private let minutesVerification = ReplayMinutesVerification()
    #if DEBUG
    private let progressVerification = ReplayAIProgressVerification()
    #endif
    private var debugRenamed = false
    private var performingReplayDebug = false
    /// 宛先の指定を当て終えるまでデバッグ送信を保留する。0秒指定の質問は start 内の
    /// 通知から呼ばれるため、保留しないと先頭宛で飛んでしまう
    private var replayDestinationPending = false
    /// 起動と同時に届いた `kikigaki://`。配線が済むまで持っておき、最後にまとめて流す
    private var pendingURL: String?
    init(replayDebug: ReplayDebugOptions = .init()) { self.replayDebug = replayDebug; super.init() }

    convenience init(testingSession: MeetingSession, config: ResolvedConfig,
                     window: TranscriptWindowController? = nil) {
        self.init()
        self.session = testingSession; self.config = config
        self.window = window
    }

    /// URLの受け口は配線より前に開ける。`open kikigaki://…` での起動では、この登録が
    /// 終わる前に届いたイベントが捨てられてしまう。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        open(url: text)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = ApplicationMenu.make()
        let config: ResolvedConfig
        do {
            config = try Self.loadConfig()
        } catch {
            Self.log("設定の読み込みに失敗: \(error)")
            let alert = NSAlert()
            alert.messageText = "KIKIGAKI の設定を読み込めません"
            alert.informativeText = "\(Self.configPath().path)\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.config = config
        replayURL = Self.argument(after: "--replay").map { URL(fileURLWithPath: $0) }

        let support = replayURL != nil && (replayDebug.verifyTyped || replayDebug.verifyMinutes != nil
            || ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_PROGRESS_REPLAY"] != nil)
            ? config.outputDir.appendingPathComponent(".typed-test-support")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KIKIGAKI")
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        catch { Self.log("AI会議の登録先を作成できません") }
        // herdrはPATHか既知の置き場で探し、設定 `[ai] herdrCommand` があればそれを使う(GUI起動のPATH不足への備え)。
        // adapterは全チャネルで共有するので、この設定はプロファイル共通で、不一致は設定エラーにしている。
        let aiStore = AIRecordStore(directory: support, makeHerdr: { [weak self] in
            AIHerdr(executable: try AIProcessRunner.executable(self?.config?.ai?.herdrCommand ?? "herdr"))
        })
        self.aiStore = aiStore
        aiStore.recover()
        // 通知音は返答元のプロファイルの設定で決める。先頭の設定で全チャネルを鳴らさない。
        aiStore.onNewResult = { [weak self] id, slot in
            let profiles = self?.aiStore?.records[id]?.manifest.profiles ?? []
            let source = profiles.first { $0.slot == slot } ?? profiles.first
            if source?.notifySound == true { NSSound(named: "Glass")?.play() }
        }
        let session = MeetingSession(config: config, models: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.loadModels()
        }, log: Self.log, aiStore: aiStore, diarizationDefaults: replayURL == nil ? .standard : nil)
        if let enabled = replayDebug.diarizationEnabled { session.setDiarizationEnabled(enabled) }
        if session.snapshot.nextDiarizationEnabled { preloadModels() }
        self.session = session

        let window = TranscriptWindowController()
        window.minutesSplit.preview.herdrCommand = { [weak self] in self?.config?.ai?.herdrCommand }
        window.onRename = { session.rename(slot: $0, to: $1) }
        window.onSubmitTyped = { session.submitTyped($0) }
        window.onSelectMinutes = { try session.selectMinutes($0) }
        window.onSpeakerMappingChange = { session.setSpeakerMapping(source: $0, target: $1) }
        window.onAudioExclusionChange = { value in session.setAudioExclusion(value) }
        window.onStartStop = { [weak self] in self?.toggleRecording() }
        window.onPauseResume = { session.togglePause() }
        window.onCopy = { full in session.copyContext(full: full, writeClipboard: Self.writeClipboard) }
        window.onRecopy = { session.recopyContext(writeClipboard: Self.writeClipboard) }
        window.onAskAI = { [weak self] in self?.showAISheet(parent: $0) }
        window.onResendAI = { [weak self] in self?.showAISheet(parent: nil, resend: $0) }
        window.onScheduleAI = { [weak self] in self?.showScheduleSheet() }
        window.onStopScheduleAI = { [weak session] in session?.stopAISchedule() }
        window.onFireScheduleAI = { [weak session] in session?.fireAIScheduleNow() }
        window.onReadAI = { session.readAI($0) }
        window.onCancelAI = { session.cancelAI($0) }
        window.onOpenAIPane = { session.showAIPane() }
        window.onRecreateAI = { session.recreateAI() }
        window.onRetryAISave = { session.retryAISaves() }
        window.onShowPreviousAI = { [weak self] in self?.showPreviousAI() }
        window.onOpenMarkdown = {
            if session.snapshot.saved, let url = session.snapshot.markdownURL { NSWorkspace.shared.open(url) }
        }
        self.window = window

        let statusItem = StatusItem()
        statusItem.onStartStop = { [weak self] in self?.toggleRecording() }
        statusItem.onPauseResume = { session.togglePause() }
        statusItem.onShowWindow = { window.show() }
        statusItem.onToggleMinutes = { window.show(); window.toggleMinutes() }
        window.onMinutesVisibility = { [weak statusItem] in statusItem?.setMinutesVisible($0) }
        statusItem.setMinutesVisible(window.minutesSplit.isPreviewVisible)
        statusItem.onOpenOutputDir = { [weak self] in self?.openOutputDir() }
        statusItem.onReloadConfig = { [weak self] in self?.reloadConfig() }
        self.statusItem = statusItem

        session.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.statusItem?.update(state: snapshot.state, elapsed: snapshot.elapsed)
            self.window?.apply(snapshot)
            #if DEBUG
            if self.replayURL != nil, let window = self.window,
               let directory = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_PROGRESS_REPLAY"] {
                do { try self.progressVerification.capture(snapshot: snapshot, window: window, directory: directory) }
                catch { Self.log("replay AI進行検証失敗: \(error)") }
            }
            #endif
            self.window?.connectMinutes(try? session.previewMinutesStore(), waitingPath: session.waitingMinutesPath)
            self.previousAI?.update()
            self.performReplayDebugActions(snapshot)
            if let sheet = self.aiSheet {
                if self.aiSheetMeetingID != session.aiMeetingID || !snapshot.canShare || snapshot.ai?.submissionID != nil {
                    sheet.close(); self.aiSheet = nil; self.aiSheetSlot = nil; session.endAIDraft()
                } else {
                    // 返答シートは固定した枠の状態を見る。選択中の宛先が返事待ちでも無効にしない。
                    let slot = sheet.owningSlot
                    sheet.update(progress: snapshot.ai?.progress(slot: slot),
                                 canSubmit: snapshot.ai?.canSubmit(slot: slot) == true, warning: snapshot.ai?.warning)
                }
            }
            if let sheet = self.scheduleSheet,
               self.scheduleSheetMeetingID != session.aiMeetingID || (snapshot.state != .recording && snapshot.state != .paused) {
                sheet.close(); self.scheduleSheet = nil
            }
            if self.terminateWhenIdle, snapshot.state == .idle {
                self.terminateWhenIdle = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        window.apply(session.snapshot)

        // --show-window: 起動直後に書き起こしウィンドウを表示する(動作確認用)
        if CommandLine.arguments.contains("--show-window") {
            window.show()
        }
        if replayURL != nil {
            toggleRecording()
        }
        #if DEBUG
        // 検証用の入口。実際のリンクと同じ経路へ流す。replayとは併用しない
        if replayURL == nil, let text = Self.argument(after: "--open-url") { pendingURL = text }
        #endif
        if let text = pendingURL {
            pendingURL = nil
            open(url: text)
        }
    }

    // MARK: - URLスキーム

    /// `kikigaki://start?minutes=…` を受ける。開けるのは録音開始シートまでで、録音は始めない。
    /// 待機中でなければシートを出さず、理由だけをヘッダーへ出す。始まっている会議の指定を
    /// 後から差し替えると、どの会議の議事録なのかが分からなくなる。
    func open(url text: String) {
        guard let start = KikigakiURL.start(text) else { return }
        // 配線の前に届いたものは持っておく。`open kikigaki://…` での起動がこれになる
        guard let session, let window else { pendingURL = text; return }
        // replayは開始シートを出さない経路なので、リンクも受けない
        guard replayURL == nil else { return }
        guard session.snapshot.state.canStart else {
            window.show()
            window.showNotice("\(session.snapshot.state.statusLabel)のため、リンクの指定は受け取れません")
            return
        }
        presentStartSheet(minutesPath: start.minutesPath)
        if let problem = start.problem { startSheet?.showMinutesHint(problem) }
    }

    /// 録音中・停止処理中に終了されたら、保存してから終了する(書き起こしを失わないため)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        session.stopAISchedule()
        switch session.snapshot.state {
        case .recording, .paused:
            Task {
                await session.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .finishing:
            terminateWhenIdle = true
            return .terminateLater
        case .idle, .preparing:
            return .terminateNow
        }
    }

    // MARK: - 操作

    private func toggleRecording() {
        guard let session else { return }
        if session.snapshot.state.canStart {
            // replayと検証は開始シートを出さない。前回の値と環境変数の指定で同じ開始経路を通す。
            if replayURL != nil { Task { await startRecording(options: nil) } }
            else { presentStartSheet() }
        } else if session.snapshot.state.canStop {
            Task { await session.stop() }
        }
    }

    /// 録音を始める前に、その会議だけの指定を決めるシートを出す。
    /// `minutesPath` はURLスキームなど外からの指定で、開いている最中なら差し替える。
    func presentStartSheet(minutesPath: String? = nil) {
        guard let session, let config, session.snapshot.state.canStart, replayURL == nil else { return }
        window?.show()
        if let startSheet {
            if let minutesPath { startSheet.setMinutesPath(minutesPath) }
            startSheet.focus()
            return
        }
        guard let parent = window?.window else { return }
        let sheet = StartSheet(profiles: config.aiProfiles,
                               diarizationEnabled: session.snapshot.nextDiarizationEnabled,
                               exclusion: session.snapshot.audioExclusion,
                               minutesPath: minutesPath ?? session.waitingMinutesPath,
                               minutesHistory: window?.minutesSplit.preview.history.paths ?? [])
        sheet.onDiarizationPreload = { [weak self] in self?.preloadModels() }
        sheet.onCancel = { [weak self] in self?.startSheet = nil }
        sheet.onStart = { [weak self] options in
            self?.startSheet = nil
            Task { await self?.startRecording(options: options) }
        }
        startSheet = sheet
        sheet.present(on: parent)
    }

    private func startRecording(options: StartSheet.Options?) async {
        guard let session else { return }
        let source: AudioSource
        if let replayURL {
            do {
                let file = try FileSource(url: replayURL)
                file.onEnd = { [weak self] in
                    Task { @MainActor in
                        await self?.session?.stop()
                        Self.log("replay 完了: \(self?.session?.snapshot.markdownURL?.path ?? "-")")
                        if let self, self.replayDebug.verifyTyped, let session = self.session {
                            do { try ReplayTypedVerification.finish(session, rename: self.replayDebug.rename, window: self.window?.window); self.debugRenamed = true }
                            catch { Self.log("replay 手入力検証失敗: \(error)") }
                        }
                        if let self, self.replayDebug.hold > 0 {
                            self.replayHolding = true
                            Self.log("replay HOLD開始: \(self.replayDebug.hold)秒")
                            if let snapshot = self.session?.snapshot { self.performReplayDebugActions(snapshot) }
                            try? await Task.sleep(nanoseconds: UInt64(self.replayDebug.hold * 1_000_000_000))
                            self.performReplayRename()
                            self.replayHolding = false
                        }
                        NSApp.terminate(nil)
                    }
                }
                source = file
            } catch {
                Self.log("replay の音声を読めない: \(error)")
                NSApp.terminate(nil)
                return
            }
        } else {
            source = MicSource()
        }
        // シートの値はこの録音にだけ効く。設定ファイルへは書き戻さない。
        if let options {
            session.setDiarizationEnabled(options.diarizationEnabled)
            // しきい値はシートで変えない。ON/OFFだけを次回設定へ重ねる。
            var exclusion = session.snapshot.audioExclusion
            exclusion.enabled = options.exclusionEnabled
            session.setAudioExclusion(exclusion)
            do { try session.prepareMinutes(options.minutesPath) }
            catch { Self.log("議事録の指定を引き継げません: \(error)") }
            session.pendingAutomaticSchedule = .init(slot: options.scheduleSlot, options: options.schedule)
        }
        window?.show()
        if replayURL != nil {
            session.automaticIntervalOverride = replayDebug.automaticSeconds
            replayDestinationPending = replayDebug.askProfile != nil
        }
        let started = await session.start(source: source)
        // 議事録を指定したら、開始と同時に右のペインへ出す。
        if started, options?.minutesPath != nil { window?.showMinutes() }
        // 宛先の指定は録音開始のリセットより後に当てる。start()が先頭へ戻すので、
        // 前に当てると2つ目を指定しても先頭へ送ってしまう。
        if started, replayURL != nil, let name = replayDebug.askProfile {
            guard let profile = session.meetingAIProfiles.first(where: { $0.name == name }) else {
                Self.log("replay 手動の宛先が設定にない: \(name)"); exit(1)
            }
            session.selectAIProfile(slot: profile.slot)
            replayDestinationPending = false
            Self.log("replay 手動の宛先: \(profile.name)(slot \(profile.slot))")
        }
        if started, replayURL != nil, let schedule = session.aiScheduleConfiguration, schedule.autoStart {
            Self.log("replay autoStart: \(schedule.name)(slot \(schedule.slot))へ \(session.lastScheduleOptions?.interval ?? 0)秒間隔")
        }
        if started, replayURL != nil, let automatic = replayDebug.automatic {
            do {
                let options = try AIScheduleOptions(prompt: automatic.prompt, interval: automatic.interval,
                                                    workAllowed: session.aiWorkAllowed)
                try session.startAISchedule(options: options,
                    helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli"))
                Self.log("replay 自動送信開始: \(options.interval)秒")
            } catch { Self.log("replay 自動送信を開始できない: \(error)"); exit(1) }
        }
        if !started, replayURL != nil {
            Self.log("replay を開始できなかったので終了する")
            exit(1)
        }
    }

    private func openOutputDir() {
        guard let dir = config?.outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func performReplayDebugActions(_ snapshot: SessionSnapshot) {
        guard replayURL != nil, !performingReplayDebug, !debugTypedPausing,
              snapshot.state == .recording || replayHolding else { return }
        performingReplayDebug = true
        defer { performingReplayDebug = false }
        if let mode = replayDebug.verifyMinutes, let session, let window {
            do { try minutesVerification.step(session: session, window: window, mode: mode) }
            catch { Self.log("replay minutes検証失敗: \(error)") }
        }
        if let session, snapshot.state == .recording {
            while nextDebugTyped < replayDebug.typedEntries.count,
                  replayDebug.typedEntries[nextDebugTyped].seconds <= snapshot.elapsed {
                let entry = replayDebug.typedEntries[nextDebugTyped]
                nextDebugTyped += 1
                if let seconds = entry.pauseSeconds {
                    debugTypedPausing = true
                    session.togglePause()
                    Self.log("replay 手入力: 音声\(session.snapshot.elapsed)秒で一時停止、\(seconds)秒後に投稿")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(seconds))
                        guard let self else { return }
                        let accepted = session.submitTyped(entry.text)
                        Self.log("replay 一時停止中の手入力: 受理\(accepted)")
                        if accepted, self.replayDebug.verifyTyped {
                            do { try ReplayTypedVerification.capture(session, phase: "paused", window: self.window?.window) }
                            catch { Self.log("replay 一時停止中の検証失敗: \(error)") }
                        }
                        if session.snapshot.state == .paused { session.togglePause() }
                        self.debugTypedPausing = false
                        if self.replayDebug.verifyTyped {
                            do { try ReplayTypedVerification.capture(session, phase: "resumed", window: self.window?.window) }
                            catch { Self.log("replay 再開直後の検証失敗: \(error)") }
                        }
                    }
                    return
                }
                let accepted = session.submitTyped(entry.text)
                Self.log("replay 手入力\(nextDebugTyped): 指定\(entry.seconds)秒、受理\(accepted)")
                if accepted, replayDebug.verifyTyped {
                    do { try ReplayTypedVerification.capture(session, phase: "recording-\(nextDebugTyped)", window: window?.window) }
                    catch { Self.log("replay 手入力の途中保存失敗: \(error)") }
                }
            }
        }
        if replayHolding, snapshot.ai?.conversation?.questions.contains(where: { $0.result != nil }) == true {
            performReplayRename()
        }
        // 手入力の保存検証では最終会話を送る。停止による確定待ち取消を避ける。
        if replayDebug.verifyTyped && !replayHolding { return }
        guard !replayDestinationPending, nextDebugQuestion < replayDebug.questions.count, let session else { return }
        if replayDebug.verifyMinutes == "main", !minutesVerification.canAsk(index: nextDebugQuestion) { return }
        let question = replayDebug.questions[nextDebugQuestion]
        guard snapshot.elapsed >= question.seconds else { return }
        do { try ReplayDebugOptions.recoverForNextQuestion(session.aiRecord?.controller, preparing: snapshot.ai?.progress != nil) }
        catch { Self.log("replay AI次質問の接続準備待ち"); return }
        guard session.snapshot.ai?.canSubmit == true else { return }
        // callbackの再入や回答待ちで二重送信しない。送信可能になるまで順番を保って待つ。
        nextDebugQuestion += 1
        let target = session.aiConfiguration
        Self.log("replay AI質問\(nextDebugQuestion): 指定\(question.seconds)秒、音声\(snapshot.elapsed)秒、宛先\(target?.name ?? "-")で送信開始")
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli")
        session.submitAI(question: question.text, full: false, parent: nil, helper: helper, profile: target)
        // 入口で弾かれると何も起きない。始まったかどうかを残す。
        Self.log("replay AI質問\(nextDebugQuestion): 送信タスク開始 \(session.isAIBusy(slot: target?.slot ?? 1))")
    }
    private func performReplayRename() {
        guard replayHolding, !debugRenamed, let rename = replayDebug.rename, let session else { return }
        debugRenamed = true
        Self.log("replay AI改名: 枡\(rename.slot)")
        session.rename(slot: rename.slot, to: rename.name)
    }

    /// 有効なら先読みし、開始要求と同じTaskを共有する。失敗を永続キャッシュしない。
    private func loadModels() async throws -> SortformerModelStore.Loaded {
        if let modelsTask { return try await modelsTask.value }
        Self.log("話者モデルを準備中...")
        let task = Task { try await SortformerModelStore.load() }
        modelsTask = task
        do { return try await task.value }
        catch { modelsTask = nil; throw error }
    }

    private func preloadModels() {
        Task { [weak self] in
            do { _ = try await self?.loadModels() }
            catch { Self.log("話者モデルの準備に失敗。録音開始時に再試行します: \(error)") }
        }
    }

    private func reloadConfig() {
        let config: ResolvedConfig
        do {
            config = try Self.loadConfig()
        } catch {
            Self.log("設定の再読込に失敗: \(error)")
            showAlert("設定を再読込できません", detail: "\(error)")
            return
        }
        self.config = config
        session?.update(config: config)
        Self.log("設定を再読込した")
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// 閉じる・Esc・外側クリックは表示だけを閉じる。送信準備やAIの実行は継続する。
    func dismissAISheet() {
        session?.endAIDraft(); aiSheet = nil; aiSheetSlot = nil
    }

    func showAISheet(parent: UUID?, resend: UUID? = nil) {
        guard let session, session.snapshot.canShare, let window = window?.window else { return }
        let questions = session.aiRecord?.controller.conversation.questions
        // 失敗した依頼はそのまま送り直せるよう、送信文・親・作業許可を元requestから戻す。
        let source = resend.flatMap { id in questions?.first { $0.request.id == id } }
        let parent = parent ?? source?.request.envelope.participant.inReplyToRequestID
        // 確認への返答と再送はシート全体を元質問の宛先へ固定する。送信先だけ直しても、
        // 送信可否・進捗・範囲・ペイン操作・表題が現在の選択を見ていては噛み合わない。
        guard let config = (resend ?? parent).flatMap({ session.aiProfile(forRequest: $0) }) ?? session.aiConfiguration else { return }
        let fixed = parent != nil || resend != nil
        if let aiSheet { aiSheet.window.makeFirstResponder(aiSheet.window.firstResponder); return }
        if let scheduleSheet { self.window?.show(); scheduleSheet.focus(); return }
        if let source {
            session.updateAIDraft(source.request.displayQuestion)
            session.updateAIWorkAllowed(source.request.envelope.participant.workAllowed)
        }
        session.beginAIDraft(slot: config.slot)
        let snapshot = session.snapshot
        let question = parent.flatMap { id in questions?.first { $0.request.id == id } }
        let slot = config.slot
        let range = session.aiRangePreview(full: false, slot: slot)
        let sheet = AIQuestionSheet(participant: config.participantName, parentNumber: question?.request.number,
            draft: fixed ? session.aiDraft : session.manualDraft(for: config), voice: snapshot.voiceQuestionPlaceholder,
            range: range, tentative: snapshot.tentativeText != nil,
            canSubmit: snapshot.ai?.canSubmit(slot: slot) == true, confirmation: question?.result?.body,
            workAllowed: session.aiWorkAllowed, fixedSlot: fixed ? slot : nil)
        sheet.updateDestinations(session.aiDestinationItems, selected: slot, participant: config.participantName)
        // 紐づけがsessionの選択を先に変えても、表示していた宛先へ編集内容を保存する。
        var displayedSlot = slot
        // 宛先の選び直しで動かすもの。
        let applyDestination: @MainActor (Int) -> Void = { [weak self, weak sheet] chosen in
            guard let sheet, session.meetingAIProfiles.contains(where: { $0.slot == chosen }) else { return }
            session.updateManualDraft(sheet.draft, slot: displayedSlot)
            session.selectAIProfile(slot: chosen)
            guard let profile = session.aiConfiguration else { return }
            displayedSlot = profile.slot
            sheet.restoreDraft(session.manualDraft(for: profile))
            // シートが持つ枠も選び直しに追随させる。開始処理と抑制判定の対象を揃える。
            session.beginAIDraft(slot: profile.slot)
            self?.aiSheetSlot = profile.slot
            sheet.updateDestinations(session.aiDestinationItems, selected: profile.slot, participant: profile.participantName)
            // 選択前のemitは旧owningSlotで可否を描く。一時停止中も次の発話を待たず更新する。
            sheet.update(progress: session.snapshot.ai?.progress(slot: profile.slot),
                          canSubmit: session.snapshot.ai?.canSubmit(slot: profile.slot) == true,
                          warning: session.snapshot.ai?.warning)
        }
        if !fixed { sheet.onDestination = applyDestination }
        sheet.onDraft = {
            if fixed { session.updateAIDraft($0) }
            else { session.updateManualDraft($0, slot: displayedSlot) }
        }
        sheet.onWorkAllowedChange = { session.updateAIWorkAllowed($0) }
        // 返答シートは親の枠に固定。それ以外は開いている間の選び直しへ追随する。
        sheet.rangePreview = { session.aiRangePreview(full: $0, slot: fixed ? slot : session.aiConfiguration?.slot) }
        sheet.onCancel = { [weak self, weak sheet] in
            if !fixed, let sheet { session.updateManualDraft(sheet.draft, slot: displayedSlot) }
            self?.dismissAISheet()
        }
        sheet.onPane = { session.showAIPane(slot: fixed ? slot : session.aiConfiguration?.slot) }
        sheet.onSubmit = { [weak self] text, full in
            if !fixed { session.updateManualDraft(text, slot: displayedSlot) }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli")
            let target = fixed ? config : session.aiConfiguration
            self?.aiSheetSlot = target?.slot
            session.submitAI(question: text, full: full, parent: parent, helper: helper, profile: target)
        }
        aiSheet = sheet; aiSheetMeetingID = session.aiMeetingID
        aiSheetSlot = slot
        self.window?.show(); sheet.present(on: window)
    }
    func showScheduleSheet() {
        guard let session, let config = session.aiConfiguration, let parent = window?.window,
              session.snapshot.state == .recording || session.snapshot.state == .paused,
              aiSheet == nil, scheduleSheet == nil else { return }
        let target = session.aiScheduleConfiguration ?? config
        let sheet = AIScheduleSheet(session: session, profile: target)
        sheet.onCancel = { [weak self] in self?.scheduleSheet = nil }
        sheet.onStart = { [weak self, weak sheet] options in
            do {
                try session.startAISchedule(options: options,
                    helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli"),
                    profile: session.aiScheduleConfiguration)
                sheet?.close(); self?.scheduleSheet = nil
            } catch {
                Self.log("自動送信を開始できません: \(error)")
                sheet?.update(warning: "開始できませんでした。録音状態を確認して、もう一度開始してください")
            }
        }
        scheduleSheet = sheet; scheduleSheetMeetingID = session.aiMeetingID
        window?.show(); sheet.present(on: parent)
    }

    private func showPreviousAI() {
        guard let aiStore, let session else { return }
        if previousAI == nil { previousAI = AIPastMeetingsWindow(store: aiStore, current: { [weak session] in session?.aiMeetingID }) }
        previousAI?.update(); previousAI?.showWindow(nil)
    }

    // MARK: - 補助

    private static func writeClipboard(_ prompt: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(prompt, forType: .string)
    }

    /// `--config <path>` で設定ファイルを差し替えられる(開発・検証用。既定は ~/.config/kikigaki/config.toml)
    nonisolated static func configPath() -> URL {
        argument(after: "--config").map { URL(fileURLWithPath: $0) } ?? ConfigLoader.defaultPath()
    }

    nonisolated static func loadConfig() throws -> ResolvedConfig {
        ResolvedConfig(config: try ConfigLoader.load(from: configPath()))
    }

    nonisolated private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("Kikigaki: \(message)\n".utf8))
    }
}
