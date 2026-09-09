import AppKit
import FluidAudio
import KikigakiCore

/// replayだけで使う開発用入力。通常起動では環境変数自体を解釈しない。
struct ReplayDebugOptions {
    struct Question { let seconds: Double; let text: String }
    var questions: [Question] = []
    var hold: Double = 0
    var rename: (slot: Int, name: String)?
    struct TypedEntry: Decodable { let seconds: Double; let text: String; let pauseSeconds: Double? }
    var typedEntries: [TypedEntry] = []
    var verifyTyped = false
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
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.contains("\0"),
                  !input.contains(where: \.isNewline), input.utf8.count <= AILimits.profileNameBytes else {
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

/// 全体の配線。設定の読み込み、モデルの先読み、メニュー・ウィンドウ・ショートカットとセッションの接続
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var window: TranscriptWindowController?
    private var session: MeetingSession?
    private var hotkeys: [Hotkey] = []
    private var config: ResolvedConfig?
    /// Sortformer モデルの先読み。開始操作を待たせないよう起動直後に走らせる
    private var modelsTask: Task<SortformerModelStore.Loaded, Error>?
    /// `--replay <wav>`: マイクの代わりに音声ファイルを流し、流し終えたら保存して終了する(開発用)
    private var replayURL: URL?
    /// 停止処理(最終判定と保存)の最中に終了操作を受けたら、保存が終わってから終了する
    private var terminateWhenIdle = false
    private var aiStore: AIRecordStore?
    private var aiSheet: AIQuestionSheet?
    private var scheduleSheet: AIScheduleSheet?
    private var scheduleSheetMeetingID: UUID?
    private var aiSheetMeetingID: UUID?
    private var previousAI: AIPastMeetingsWindow?
    private var registeredAIHotkey: KikigakiConfig.Hotkey?
    private let replayDebug: ReplayDebugOptions
    private var nextDebugQuestion = 0
    private var nextDebugTyped = 0
    private var debugTypedPausing = false
    private var replayHolding = false
    private var debugRenamed = false
    private var performingReplayDebug = false
    init(replayDebug: ReplayDebugOptions = .init()) { self.replayDebug = replayDebug; super.init() }

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

        let modelsTask = Task { try await SortformerModelStore.load() }
        self.modelsTask = modelsTask
        let support = replayURL != nil && replayDebug.verifyTyped
            ? config.outputDir.appendingPathComponent(".typed-test-support")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KIKIGAKI")
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        catch { Self.log("AI会議の登録先を作成できません") }
        // herdrはPATHか既知の置き場で探し、設定 `[ai] herdrCommand` があればそれを使う(GUI起動のPATH不足への備え)
        let aiStore = AIRecordStore(directory: support, makeHerdr: { [weak self] in
            AIHerdr(executable: try AIProcessRunner.executable(self?.config?.ai?.herdrCommand ?? "herdr"))
        })
        self.aiStore = aiStore
        aiStore.recover()
        aiStore.onNewResult = { [weak self] id in
            if self?.aiStore?.records[id]?.manifest.config.notifySound == true { NSSound(named: "Glass")?.play() }
        }
        let session = MeetingSession(config: config, models: { try await modelsTask.value }, log: Self.log, aiStore: aiStore)
        self.session = session

        let window = TranscriptWindowController()
        window.onRename = { session.rename(slot: $0, to: $1) }
        window.onSubmitTyped = { session.submitTyped($0) }
        window.onSpeakerMappingChange = { session.setSpeakerMapping(source: $0, target: $1) }
        window.onStartStop = { [weak self] in self?.toggleRecording() }
        window.onPauseResume = { session.togglePause() }
        window.onCopy = { full in session.copyContext(full: full, writeClipboard: Self.writeClipboard) }
        window.onRecopy = { session.recopyContext(writeClipboard: Self.writeClipboard) }
        window.onAskAI = { [weak self] in self?.showAISheet(parent: $0) }
        window.onScheduleAI = { [weak self] in self?.showScheduleSheet() }
        window.onStopScheduleAI = { [weak session] in session?.stopAISchedule() }
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
        statusItem.onOpenOutputDir = { [weak self] in self?.openOutputDir() }
        statusItem.onReloadConfig = { [weak self] in self?.reloadConfig() }
        self.statusItem = statusItem

        session.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.statusItem?.update(state: snapshot.state, elapsed: snapshot.elapsed)
            self.window?.apply(snapshot)
            self.previousAI?.update()
            self.performReplayDebugActions(snapshot)
            if self.registeredAIHotkey != session.aiConfiguration?.hotkey, let config = self.config { _ = self.registerHotkeys(config) }
            if let sheet = self.aiSheet {
                if self.aiSheetMeetingID != session.aiMeetingID || !snapshot.canShare || snapshot.ai?.submissionID != nil {
                    sheet.close(); self.aiSheet = nil; session.endAIDraft()
                } else { sheet.update(progress: snapshot.ai?.progress, canSubmit: snapshot.ai?.canSubmit == true, warning: snapshot.ai?.warning) }
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
        if !registerHotkeys(config) {
            Self.log("ショートカットを登録できない。メニューからは操作できる")
        }

        // --show-window: 起動直後に書き起こしウィンドウを表示する(動作確認用)
        if CommandLine.arguments.contains("--show-window") {
            window.show()
        }
        if replayURL != nil {
            toggleRecording()
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.forEach { $0.unregister() }
    }

    // MARK: - 操作

    private func toggleRecording() {
        guard let session else { return }
        if session.snapshot.state.canStart {
            Task { await startRecording() }
        } else if session.snapshot.state.canStop {
            Task { await session.stop() }
        }
    }

    private func startRecording() async {
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
        window?.show()
        if replayURL != nil {
            session.automaticIntervalOverride = replayDebug.automaticSeconds
            if let name = replayDebug.askProfile {
                guard let profile = session.meetingAIProfiles.first(where: { $0.name == name }) else {
                    Self.log("replay 手動の宛先が設定にない: \(name)"); exit(1)
                }
                session.selectAIProfile(slot: profile.slot)
                Self.log("replay 手動の宛先: \(profile.name)(slot \(profile.slot))")
            }
        }
        let started = await session.start(source: source)
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
        guard nextDebugQuestion < replayDebug.questions.count, let session else { return }
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
    }
    private func performReplayRename() {
        guard replayHolding, !debugRenamed, let rename = replayDebug.rename, let session else { return }
        debugRenamed = true
        Self.log("replay AI改名: 枡\(rename.slot)")
        session.rename(slot: rename.slot, to: rename.name)
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
        // ショートカットの登録に失敗したら新しい設定は反映せず、前の設定に戻す(操作手段を失わないため)
        guard registerHotkeys(config) else {
            if let previous = self.config { _ = registerHotkeys(previous) }
            showAlert("ショートカットを登録できません", detail: "設定は反映せず、前の設定のままにしました。キー名や他アプリとの重複を確認してください")
            return
        }
        self.config = config
        session?.update(config: config)
        Self.log("設定を再読込した")
    }

    /// 全部登録できたら true。1つでも失敗したら登録した分を解除して false
    private func registerHotkeys(_ config: ResolvedConfig) -> Bool {
        hotkeys.forEach { $0.unregister() }
        hotkeys = []
        var bindings: [(KikigakiConfig.Hotkey, () -> Void)] = [
            (config.toggleRecording, { [weak self] in self?.toggleRecording() }),
            (config.togglePause, { [weak self] in self?.session?.togglePause() }),
        ]
        let meetingAI = session == nil ? config.ai : session?.aiConfiguration
        if let ai = meetingAI { bindings.append((ai.hotkey, { [weak self] in self?.showAISheet(parent: nil) })) }
        var registered: [Hotkey] = []
        for (hotkey, handler) in bindings {
            guard let one = Hotkey(modifiers: hotkey.modifiers, key: hotkey.key, handler: handler) else {
                Self.log("ショートカットを登録できない: \(hotkey.modifiers.joined(separator: "+"))+\(hotkey.key)")
                registered.forEach { $0.unregister() }
                return false
            }
            registered.append(one)
        }
        hotkeys = registered
        registeredAIHotkey = meetingAI?.hotkey
        return true
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func showAISheet(parent: UUID?) {
        guard let session, session.snapshot.canShare, let config = session.aiConfiguration, let window = window?.window else { return }
        if let aiSheet { aiSheet.window.makeFirstResponder(aiSheet.window.firstResponder); return }
        if let scheduleSheet { self.window?.show(); scheduleSheet.focus(); return }
        session.beginAIDraft()
        let snapshot = session.snapshot
        let question = parent.flatMap { id in session.aiRecord?.controller.conversation.questions.first { $0.request.id == id } }
        let range = session.aiRangePreview(full: false)
        let sheet = AIQuestionSheet(participant: config.participantName, parentNumber: question?.request.number,
            draft: session.aiDraft, voice: snapshot.voiceQuestionPlaceholder,
            range: range, tentative: snapshot.tentativeText != nil, canSubmit: snapshot.ai?.canSubmit == true, confirmation: question?.result?.body,
            workAllowed: session.aiWorkAllowed)
        sheet.updateDestinations(session.aiDestinationItems, selected: config.slot, participant: config.participantName)
        sheet.onDestination = { [weak sheet] slot in
            session.selectAIProfile(slot: slot)
            guard let profile = session.aiConfiguration else { return }
            sheet?.updateDestinations(session.aiDestinationItems, selected: profile.slot, participant: profile.participantName)
        }
        sheet.onDraft = { session.updateAIDraft($0) }
        sheet.onWorkAllowedChange = { session.updateAIWorkAllowed($0) }
        sheet.rangePreview = { session.aiRangePreview(full: $0) }
        sheet.onCancel = { [weak self] in session.cancelAIPreparation(); session.endAIDraft(); self?.aiSheet = nil }
        sheet.onPane = { session.showAIPane() }
        sheet.onSubmit = { text, full in
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli")
            session.submitAI(question: text, full: full, parent: parent, helper: helper,
                             profile: session.aiConfiguration)
        }
        aiSheet = sheet; aiSheetMeetingID = session.aiMeetingID
        self.window?.show(); sheet.present(on: window)
    }
    private func showScheduleSheet() {
        guard let session, let config = session.aiConfiguration, let parent = window?.window,
              session.snapshot.state == .recording || session.snapshot.state == .paused,
              aiSheet == nil, scheduleSheet == nil else { return }
        let previous = session.lastScheduleOptions
        let target = session.aiScheduleConfiguration ?? config
        let sheet = AIScheduleSheet(prompt: session.scheduleDraft ?? previous?.prompt ?? target.autoPrompt,
            minutes: previous.map { Int($0.interval / 60) } ?? target.autoIntervalMinutes,
            workAllowed: previous?.workAllowed ?? session.aiWorkAllowed, sendFinal: previous?.sendFinal ?? true,
            participant: target.participantName)
        sheet.updateDestinations(session.aiDestinationItems, selected: target.slot, participant: target.participantName)
        sheet.onDestination = { [weak sheet] slot in
            session.selectAIProfile(slot: slot, forSchedule: true)
            guard let profile = session.aiScheduleConfiguration else { return }
            sheet?.updateDestinations(session.aiDestinationItems, selected: profile.slot, participant: profile.participantName)
        }
        sheet.onDraft = { session.updateScheduleDraft($0) }
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
