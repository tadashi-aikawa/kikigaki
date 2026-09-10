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
    /// 録音を始める前に起こしておくプロファイル名。連続する会議の準備を再現する
    var prepareProfiles: [String] = []
    /// 枠ごとの紐づけの選択。`oldest` は最も古い準備済み、`new` は新規に起動する
    enum Attach: String { case oldest, new }
    var attach: [Int: Attach] = [:]
    /// 紐づけシートの「取消(録音を始めない)」を再現する。開始直後に取り止める
    var attachCancel = false
    /// 録音中に起こす準備。次の会議のぶんを会議の最中に用意することを再現する
    var prepareDuring: [(seconds: Double, name: String)] = []
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
            // 長い宛名から補ったプロファイル名も指定できるよう、長さは制限しない。
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.contains("\0"),
                  !input.contains(where: \.isNewline) else {
                throw AIError.invalid("KIKIGAKI_DEBUG_AI_ASK_PROFILE")
            }
            result.askProfile = input
        }
        if let input = env["KIKIGAKI_DEBUG_AI_PREPARE"], !input.isEmpty {
            let names = input.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.contains("\0") && !$0.contains(where: \.isNewline) }) else {
                throw AIError.invalid("KIKIGAKI_DEBUG_AI_PREPARE")
            }
            result.prepareProfiles = names
        }
        if let input = env["KIKIGAKI_DEBUG_AI_ATTACH"], !input.isEmpty {
            for entry in input.split(separator: ";", omittingEmptySubsequences: false) {
                let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, let slot = Int(pair[0]), slot > 0,
                      let choice = Attach(rawValue: String(pair[1])), result.attach[slot] == nil else {
                    throw AIError.invalid("KIKIGAKI_DEBUG_AI_ATTACH")
                }
                result.attach[slot] = choice
            }
        }
        if let input = env["KIKIGAKI_DEBUG_AI_PREPARE_AT"], !input.isEmpty {
            for entry in input.split(separator: ";", omittingEmptySubsequences: false) {
                let pair = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, let seconds = Double(pair[0]), seconds.isFinite, seconds >= 0,
                      !pair[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !pair[1].contains("\0"), !pair[1].contains(where: \.isNewline) else {
                    throw AIError.invalid("KIKIGAKI_DEBUG_AI_PREPARE_AT")
                }
                result.prepareDuring.append((seconds, String(pair[1])))
            }
            result.prepareDuring.sort { $0.seconds < $1.seconds }
        }
        if let input = env["KIKIGAKI_DEBUG_AI_ATTACH_CANCEL"] {
            guard ["0", "1"].contains(input) else { throw AIError.invalid("KIKIGAKI_DEBUG_AI_ATTACH_CANCEL") }
            result.attachCancel = input == "1"
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
    private(set) var aiSheet: AIQuestionSheet?
    private(set) var scheduleSheet: AIScheduleSheet?
    /// シートを閉じても紐づけ処理は続く。開き直したシートにも送信待ちを引き継ぐ。
    private var preparedBinding = false
    private var scheduleSheetMeetingID: UUID?
    private var aiSheetMeetingID: UUID?
    /// 確認への返答シートが固定している枠。通常のシートはnilで選択中の宛先へ追随する
    private var aiSheetSlot: Int?
    private var previousAI: AIPastMeetingsWindow?
    private var preparedStore: AIPreparedStore?
    private var prepareSheet: AIPrepareSheet?
    private var attachSheet: AIAttachSheet?
    private var registeredAIHotkey: KikigakiConfig.Hotkey?
    private let replayDebug: ReplayDebugOptions
    private var nextDebugQuestion = 0
    private var nextDebugPrepare = 0
    /// 録音中の準備は1件ずつ。同じ枠の起動を重ねない
    private var preparingDuringRecording = false
    private var nextDebugTyped = 0
    private var debugTypedPausing = false
    private var replayHolding = false
    private var debugRenamed = false
    private var performingReplayDebug = false
    /// 宛先の指定を当て終えるまでデバッグ送信を保留する。0秒指定の質問は start 内の
    /// 通知から呼ばれるため、保留しないと先頭宛で飛んでしまう
    private var replayDestinationPending = false
    init(replayDebug: ReplayDebugOptions = .init()) { self.replayDebug = replayDebug; super.init() }

    convenience init(testingSession: MeetingSession, config: ResolvedConfig, preparedStore: AIPreparedStore,
                     window: TranscriptWindowController? = nil) {
        self.init()
        self.session = testingSession; self.config = config; self.preparedStore = preparedStore
        self.window = window
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

        let modelsTask = Task { try await SortformerModelStore.load() }
        self.modelsTask = modelsTask
        let support = replayURL != nil && replayDebug.verifyTyped
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
        // 準備済みセッションの台帳。会議の登録簿と同じ置き場だがファイルは別で、
        // 片方が壊れてももう片方の機能は止まらない。
        let preparedStore = AIPreparedStore(directory: support, makeHerdr: { [weak self] in
            AIHerdr(executable: try AIProcessRunner.executable(self?.config?.ai?.herdrCommand ?? "herdr"))
        })
        self.preparedStore = preparedStore
        preparedStore.load()
        let session = MeetingSession(config: config, models: { try await modelsTask.value }, log: Self.log, aiStore: aiStore)
        session.preparedStore = preparedStore
        preparedStore.onChange = { [weak self] in self?.preparedChanged() }
        // 同じ枠の送信と準備の起動を重ねない。判定はどちらの入口からも同じものを見る。
        preparedStore.isSlotBusy = { [weak session] in session?.isAIBusy(slot: $0) ?? false }
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
        window.onPrepareAI = { [weak self] in self?.showPrepareSheet() }
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
        statusItem.onPrepareAI = { [weak self] in self?.showPrepareSheet() }
        statusItem.setPrepareEnabled(!config.aiProfiles.isEmpty && preparedStore.isUsable)
        self.statusItem = statusItem
        // ペインの表題と生存は台帳に持たないので、起動時に引き直す。
        if !config.aiProfiles.isEmpty { Task { await preparedStore.refresh() } }

        session.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.statusItem?.update(state: snapshot.state, elapsed: snapshot.elapsed)
            self.window?.apply(snapshot)
            self.previousAI?.update()
            self.performReplayDebugActions(snapshot)
            if self.registeredAIHotkey != session.aiPrimaryConfiguration?.hotkey, let config = self.config { _ = self.registerHotkeys(config) }
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
            // 録音がシートの最中に終わったら、紐づけずに閉じる。
            if let sheet = self.attachSheet, snapshot.state != .recording, snapshot.state != .paused {
                sheet.close(); self.attachSheet = nil; session.deferAutomaticStart = false
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
            replayDestinationPending = replayDebug.askProfile != nil
        }
        // 紐づけシートを出す間は設定の自動送信を待たせる。先に始めると、紐づける前の
        // 新しいセッションへ1回目が飛んでしまう。判定は開始前に済ませる。
        // replayは録音の前に準備を起こす。本番の `prepare` をそのまま通す。
        if replayURL != nil, let preparedStore, let config, !replayDebug.prepareProfiles.isEmpty {
            for name in replayDebug.prepareProfiles {
                guard let profile = config.aiProfiles.first(where: { $0.name == name }) else {
                    Self.log("replay 準備するプロファイルが設定にない: \(name)"); exit(1)
                }
                await preparedStore.prepare(profile: profile, helper: helperURL, outputDirectory: config.outputDir)
                Self.log("replay 準備: \(profile.name)(slot \(profile.slot)) 未紐づけ \(preparedStore.unbound.count)件")
            }
        }
        // 候補を確定する前に、前回の取り止めの片付けをやり直す。ここで台帳が戻ると、
        // 復旧した準備済みも今回の選択肢に出る。start()の中の再試行では候補に間に合わない。
        session.retryDiscard()
        // 候補を出す前に生存と表題を引き直す。消えたペインを選ばせない。
        if replayURL == nil, let preparedStore { await preparedStore.refresh() }
        let choices = attachChoices()
        // replayは紐づけシートを出さない代わりに、指定した選択を同じ経路へ当てる。
        let replayAttach = replayURL == nil ? [:] : replayDebug.attach
        session.deferAutomaticStart = !choices.isEmpty || !replayAttach.isEmpty
        let started = await session.start(source: source)
        if started, !choices.isEmpty { presentAttachSheet(choices) }
        else if started, replayURL != nil, replayDebug.attachCancel {
            // 「取消(録音を始めない)」と同じ経路。何も残らないことを実機で確かめる。
            // 検査対象は**取消の前に固定する**。取消が成功すると会議IDは新しくなる。
            let cancelled = session.aiMeetingID
            let markdown = session.snapshot.markdownURL
            let root = markdown?.deletingLastPathComponent() ?? config?.outputDir
            // 紐づけも実機で確かめる。指定があれば取消の前に当てておく。
            if !replayDebug.attach.isEmpty, let preparedStore {
                var selection: [Int: UUID?] = [:]
                for (slot, choice) in replayDebug.attach {
                    guard let profile = session.meetingAIProfiles.first(where: { $0.slot == slot }) else { continue }
                    selection[slot] = choice == .oldest
                        ? preparedStore.available(for: profile, contextRoot: session.aiContextRoot).first?.id : nil
                }
                let failed = await session.applyPreparedSelection(selection)
                Self.log("replay 取消前の紐づけ: 失敗 \(failed.sorted()) 紐づけ済み \(preparedStore.ledger.sessions.filter { !$0.isUnbound }.count)件")
                if !failed.isEmpty { exit(1) }
            }
            await session.abandon()
            let context = root?.appendingPathComponent(".kikigaki-context").appendingPathComponent(cancelled.uuidString)
            let leftovers = [
                "Markdown": markdown.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                "WAV": markdown.map { FileManager.default.fileExists(atPath: MeetingFiles.wavURL(for: $0).path) } ?? false,
                "置き場": context.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                "登録簿": aiStore?.records[cancelled] != nil,
                "紐づけ": preparedStore?.ledger.sessions.contains { $0.bound?.meetingID == cancelled } ?? false,
                "片付け残し": session.hasPendingDiscard,
            ]
            let remaining = leftovers.filter(\.value).keys.sorted()
            Self.log("replay 取消: 会議 \(cancelled) 保存 \(session.snapshot.saved) 残り \(remaining)"
                + " 未紐づけ \(preparedStore?.unbound.count ?? 0)件")
            if session.snapshot.saved || !remaining.isEmpty { exit(1) }
            NSApp.terminate(nil)
            return
        }
        else if started, !replayAttach.isEmpty, let preparedStore {
            var selection: [Int: UUID?] = [:]
            for (slot, choice) in replayAttach {
                guard let profile = session.meetingAIProfiles.first(where: { $0.slot == slot }) else {
                    Self.log("replay 紐づけ先の枠が設定にない: \(slot)"); exit(1)
                }
                let oldest = preparedStore.available(for: profile, contextRoot: session.aiContextRoot).first
                if choice == .oldest, oldest == nil {
                    Self.log("replay 紐づける準備済みが無い: slot \(slot)"); exit(1)
                }
                selection[slot] = choice == .oldest ? oldest?.id : nil
            }
            let failed = await session.applyPreparedSelection(selection)
            let summary = selection.keys.sorted()
                .map { "\($0)=" + (selection[$0]! == nil ? "new" : "oldest") }.joined(separator: ",")
            Self.log("replay 紐づけ: \(summary) 失敗 \(failed.sorted())")
            if !failed.isEmpty { exit(1) }
        }
        else { session.deferAutomaticStart = false }
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

    // MARK: - 準備済みAIセッション

    private var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli") }

    /// 台帳が変わった。フッターの一行・メニューの可否・開いているシートを作り直す。
    private func preparedChanged() {
        guard let preparedStore else { return }
        let configured = !(config?.aiProfiles.isEmpty ?? true)
        statusItem?.setPrepareEnabled(configured && preparedStore.isUsable)
        session?.refreshPrepared()
        updatePrepareSheet()
        // 宛先ポップアップの準備済みの行も引き直す。紐づけたものは候補から消える。
        if let session, let sheet = aiSheet {
            let slot = sheet.owningSlot
            let name = session.meetingAIProfiles.first { $0.slot == slot }?.participantName ?? ""
            sheet.updateDestinations(session.aiDestinationItems, selected: slot, participant: name)
        }
        if let session, let sheet = scheduleSheet, let target = session.aiScheduleConfiguration {
            sheet.updateDestinations(session.aiDestinationItems, selected: target.slot,
                                     participant: target.participantName)
        }
    }

    private func showPrepareSheet() {
        guard let config, let preparedStore, let parent = window?.window,
              !config.aiProfiles.isEmpty, preparedStore.isUsable, prepareSheet == nil else { return }
        let profiles = config.aiProfiles.map { (slot: $0.slot, name: $0.name) }
        let selected = session?.snapshot.ai?.selectedSlot ?? profiles.first?.slot ?? 1
        let sheet = AIPrepareSheet(profiles: profiles, selected: selected,
                                  avatarSources: Dictionary(uniqueKeysWithValues: config.aiProfiles.compactMap { p in p.avatar.map { (p.slot, $0) } }))
        sheet.onCancel = { [weak self] in self?.prepareSheet = nil }
        sheet.onStart = { [weak self] slot, name in
            guard let self, let profile = self.config?.aiProfiles.first(where: { $0.slot == slot }) else { return }
            Task { await preparedStore.prepare(profile: profile, helper: self.helperURL,
                                               outputDirectory: config.outputDir, name: name) }
        }
        sheet.onDiscard = { preparedStore.discard($0) }
        sheet.onPane = { [weak sheet] id in
            // 見出しの「ペインを開く」は、いま選んでいるプロファイルのいちばん新しいもの。
            let target = id ?? preparedStore.unbound.last { $0.profileSlot == sheet?.selectedSlot }?.id
            guard let target else { return }
            Task { await preparedStore.showPane(target) }
        }
        prepareSheet = sheet
        updatePrepareSheet()
        window?.show(); sheet.present(on: parent)
        Task { await preparedStore.refresh() }
    }

    private func updatePrepareSheet() {
        guard let sheet = prepareSheet, let preparedStore else { return }
        let profiles = config?.aiProfiles ?? []
        let rows = preparedStore.unbound.map { session -> AIPrepareSheet.Row in
            // いまの設定に同じ枠が無い、または設定が変わっていれば使えない。破棄だけできる。
            // 使えない理由は分けて示す。設定を戻すのか、保存先を戻すのかが変わる。
            let profile = profiles.first { $0.slot == session.profileSlot }
            let reason: String?
            if profile == nil || !session.matches(profile!) { reason = "設定が変わったため使えません" }
            else if let root = self.config?.outputDir, !session.matchesContext(root: root) {
                reason = "保存先が変わったため使えません"
            } else { reason = nil }
            return .init(id: session.id, label: preparedStore.label(session), reason: reason,
                         name: session.profileName, avatar: session.config.avatar)
        }
        sheet.update(rows: rows, launching: !preparedStore.launching.isEmpty, warning: preparedStore.warning)
    }

    /// 録音開始時に選ばせる候補。未紐づけが1件も無ければシートを出さない。
    /// - Parameters:
    ///   - slots: 指定するとその枠だけを出す。引き継ぎに失敗した枠の選び直しに使う
    ///   - includingEmpty: 候補が無い枠も「新規に起動する」だけの選択として出す。
    ///     選び直しでは、候補が尽きても利用者に選ばせる。黙って新規起動へ進めない
    func attachChoices(slots: Set<Int>? = nil, includingEmpty: Bool = false) -> [AIAttachSheet.Choice] {
        guard replayURL == nil, let config, let preparedStore, preparedStore.isUsable else { return [] }
        // 開始前は次の録音の設定。開始後の選び直しはadoptと同じ会議固定値で判定する。
        let active = session.flatMap { $0.snapshot.state == .recording || $0.snapshot.state == .paused ? $0 : nil }
        let profiles = active?.meetingAIProfiles ?? config.aiProfiles
        let outputDirectory = active?.aiContextRoot ?? config.outputDir
        return AIAttachSheet.choices(profiles: profiles.map { (slot: $0.slot, name: $0.name) },
                                     slots: slots, includingEmpty: includingEmpty) { slot in
            guard let profile = profiles.first(where: { $0.slot == slot }) else { return [] }
            return preparedStore.available(for: profile, contextRoot: outputDirectory)
                .map { ($0.id, preparedStore.label($0, includingName: false)) }
        }
    }

    private func presentAttachSheet(_ choices: [AIAttachSheet.Choice], warning: String? = nil) {
        guard let parent = window?.window else { session?.deferAutomaticStart = false; return }
        // 出すものが無いときだけ、新規起動として続ける。呼び手は空の候補を渡さない。
        guard !choices.isEmpty else { session?.deferAutomaticStart = false; return }
        let profiles = session?.meetingAIProfiles ?? config?.aiProfiles ?? []
        let sheet = AIAttachSheet(choices: choices, warning: warning,
                                 avatarSources: Dictionary(uniqueKeysWithValues: profiles.compactMap { p in p.avatar.map { (p.slot, $0) } }))
        sheet.onCancel = { [weak self] in
            // 取消は録音を始めない。開始してからシートを出しているので、収録した分ごと取り止め、
            // Markdownも録音も残さない。
            self?.attachSheet = nil
            Task { await self?.session?.abandon(); self?.session?.deferAutomaticStart = false }
        }
        sheet.onStart = { [weak self] selection in
            self?.attachSheet = nil
            Task { await self?.finishAttach(selection) }
        }
        attachSheet = sheet
        window?.show(); sheet.present(on: parent)
    }

    private func finishAttach(_ selection: [Int: UUID?]) async {
        guard let session else { return }
        // 紐づけはawaitを跨ぐ。この選択が属する会議を固定し、途中で録音が入れ替わったら止める。
        let meetingID = session.aiMeetingID
        // 引き継ぎと、全部済んだときの自動送信の開始は session 側の1か所で行う。
        let failed = await session.applyPreparedSelection(selection)
        guard session.aiMeetingID == meetingID else { return }
        // 紐づけた直後の生存と表題を引き直す。候補から消え、閉じた表題が最新になる。
        if let preparedStore { await preparedStore.refresh() }
        guard session.aiMeetingID == meetingID else { return }
        // 失敗した枠は選び直させる。候補が尽きていれば新規起動として続ける。
        if !failed.isEmpty, session.snapshot.state == .recording || session.snapshot.state == .paused {
            // 候補が尽きていても「新規に起動する」を選ばせる。黙って新規起動へ進めない。
            presentAttachSheet(attachChoices(slots: failed, includingEmpty: true),
                               warning: "選んだ準備済みセッションを引き継げませんでした。選び直してください")
        }
    }

    /// 宛先ポップアップで準備済みを選んだ。紐づけてから送信先も切り替える。
    /// 表示だけ変えて送信先が元のままにならないよう、`session` 側で選択も動かす。
    private func adoptPrepared(slot: Int, id: UUID, forSchedule: Bool, then: @escaping (Bool) -> Void) {
        guard !preparedBinding, let session,
              let profile = session.meetingAIProfiles.first(where: { $0.slot == slot }) else { then(false); return }
        let meetingID = session.aiMeetingID
        preparedBinding = true
        // 確定するまで送信させない。画面は選んだ先を出すのに、送信は前の宛先へ飛ぶ食い違いを作らない。
        aiSheet?.setBinding(true, canSubmit: false)
        scheduleSheet?.setBinding(true)
        Task {
            let bound = await session.adoptPrepared(id, profile: profile, forSchedule: forSchedule)
            self.preparedBinding = false
            let owning = self.aiSheet?.owningSlot
            self.aiSheet?.setBinding(false, canSubmit: owning.map { session.snapshot.ai?.canSubmit(slot: $0) == true } ?? false)
            self.scheduleSheet?.setBinding(false)
            guard session.aiMeetingID == meetingID else { return }
            self.preparedChanged()
            then(bound)
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
        // 録音中の準備。次の会議のぶんを会議の最中に用意する。
        if let session, nextDebugPrepare < replayDebug.prepareDuring.count,
           snapshot.state == .recording, !preparingDuringRecording {
            let target = replayDebug.prepareDuring[nextDebugPrepare]
            if snapshot.elapsed >= target.seconds, let preparedStore, let config,
               let profile = config.aiProfiles.first(where: { $0.name == target.name }) {
                nextDebugPrepare += 1
                preparingDuringRecording = true
                // 起動そのものは非同期で、終わるころには録音が終わっていることもある。
                // 「録音中に始めた」ことが分かるよう、判断した時点の状態と位置を先に出す。
                Self.log("replay 録音中の準備を開始: \(profile.name)(指定\(target.seconds)秒、"
                    + "経過\(snapshot.elapsed)秒、状態\(snapshot.state))")
                Task {
                    await preparedStore.prepare(profile: profile, helper: self.helperURL,
                                                outputDirectory: config.outputDir)
                    self.preparingDuringRecording = false
                    Self.log("replay 録音中の準備が完了: \(profile.name) 未紐づけ \(preparedStore.unbound.count)件")
                }
            }
        }
        guard !replayDestinationPending, nextDebugQuestion < replayDebug.questions.count, let session else { return }
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
        // AI設定を足した直後でも準備の入口を使えるようにする。開いているシートも作り直す。
        preparedChanged()
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
        // ホットキーは1つ目のプロファイルのものだけ。宛先を選び直しても登録し直さない。
        let meetingAI = session == nil ? config.aiProfiles.first : session?.aiPrimaryConfiguration
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
            draft: session.aiDraft, voice: snapshot.voiceQuestionPlaceholder,
            range: range, tentative: snapshot.tentativeText != nil,
            canSubmit: snapshot.ai?.canSubmit(slot: slot) == true, confirmation: question?.result?.body,
            workAllowed: session.aiWorkAllowed, fixedSlot: fixed ? slot : nil)
        sheet.updateDestinations(session.aiDestinationItems, selected: slot, participant: config.participantName)
        // 宛先の選び直しで動かすもの。準備済みの行を選んだときも、紐づけたあとに同じ処理を通す。
        let applyDestination: @MainActor (Int) -> Void = { [weak self, weak sheet] chosen in
            session.selectAIProfile(slot: chosen)
            guard let profile = session.aiConfiguration else { return }
            // シートが持つ枠も選び直しに追随させる。開始処理と抑制判定の対象を揃える。
            session.beginAIDraft(slot: profile.slot)
            self?.aiSheetSlot = profile.slot
            sheet?.updateDestinations(session.aiDestinationItems, selected: profile.slot, participant: profile.participantName)
            // 選択前のemitは旧owningSlotで可否を描く。一時停止中も次の発話を待たず更新する。
            sheet?.update(progress: session.snapshot.ai?.progress(slot: profile.slot),
                          canSubmit: session.snapshot.ai?.canSubmit(slot: profile.slot) == true,
                          warning: session.snapshot.ai?.warning)
        }
        if !fixed { sheet.onDestination = applyDestination }
        sheet.onPrepared = { [weak self] chosen, id in
            // 返答シートは親の枠に固定なので、紐づけても送信先は動かさない。
            self?.adoptPrepared(slot: chosen, id: id, forSchedule: false) { [weak self] bound in
                guard let self, let sheet = self.aiSheet else { return }
                // 開き直したシートへ反映する。返答・再送の固定シートにはonDestinationがない。
                if bound { sheet.onDestination?(chosen) }
                else {
                    // 失敗したら送信先(session側)へ表示を揃える。画面だけBに残さない。
                    let restored = session.aiConfiguration?.slot ?? sheet.owningSlot
                    let name = session.meetingAIProfiles.first { $0.slot == restored }?.participantName ?? ""
                    sheet.restoreDestination(restored, items: session.aiDestinationItems, participant: name)
                }
            }
        }
        sheet.onDraft = { session.updateAIDraft($0) }
        sheet.onWorkAllowedChange = { session.updateAIWorkAllowed($0) }
        // 返答シートは親の枠に固定。それ以外は開いている間の選び直しへ追随する。
        sheet.rangePreview = { session.aiRangePreview(full: $0, slot: fixed ? slot : session.aiConfiguration?.slot) }
        sheet.onCancel = { [weak self] in self?.dismissAISheet() }
        sheet.onPane = { session.showAIPane(slot: fixed ? slot : session.aiConfiguration?.slot) }
        sheet.onSubmit = { [weak self] text, full in
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kikigaki-cli")
            let target = fixed ? config : session.aiConfiguration
            self?.aiSheetSlot = target?.slot
            session.submitAI(question: text, full: full, parent: parent, helper: helper, profile: target)
        }
        sheet.setBinding(preparedBinding, canSubmit: snapshot.ai?.canSubmit(slot: slot) == true)
        aiSheet = sheet; aiSheetMeetingID = session.aiMeetingID
        aiSheetSlot = slot
        self.window?.show(); sheet.present(on: window)
        // 宛先の準備済みも出すたびに引き直す。消えたペインを候補に残さない。
        if let preparedStore { Task { await preparedStore.refresh() } }
    }
    func showScheduleSheet() {
        guard let session, let config = session.aiConfiguration, let parent = window?.window,
              session.snapshot.state == .recording || session.snapshot.state == .paused,
              aiSheet == nil, scheduleSheet == nil else { return }
        let target = session.aiScheduleConfiguration ?? config
        let sheet = AIScheduleSheet(session: session, profile: target)
        sheet.onPrepared = { [weak self] slot, id in
            self?.adoptPrepared(slot: slot, id: id, forSchedule: true) { [weak self] bound in
                // await中に閉じて開き直していても、現在のシートへ宛先と文面を一緒に反映する。
                guard let self, let sheet = self.scheduleSheet else { return }
                if bound { sheet.onDestination?(slot) }
                else if let target = session.aiScheduleConfiguration {
                    sheet.updateDestinations(session.aiDestinationItems, selected: target.slot,
                                              participant: target.participantName)
                }
            }
        }
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
        sheet.setBinding(preparedBinding)
        scheduleSheet = sheet; scheduleSheetMeetingID = session.aiMeetingID
        window?.show(); sheet.present(on: parent)
        if let preparedStore { Task { await preparedStore.refresh() } }
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
