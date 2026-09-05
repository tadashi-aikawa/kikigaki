import AppKit
import FluidAudio
import KikigakiCore

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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let session = MeetingSession(config: config, models: { try await modelsTask.value }, log: Self.log)
        self.session = session

        let window = TranscriptWindowController()
        window.onRename = { session.rename(names: $0) }
        window.onStartStop = { [weak self] in self?.toggleRecording() }
        window.onPauseResume = { session.togglePause() }
        window.onCopy = { full in session.copyContext(full: full, writeClipboard: Self.writeClipboard) }
        window.onRecopy = { session.recopyContext(writeClipboard: Self.writeClipboard) }
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
        let started = await session.start(source: source)
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
        let bindings: [(KikigakiConfig.Hotkey, () -> Void)] = [
            (config.toggleRecording, { [weak self] in self?.toggleRecording() }),
            (config.togglePause, { [weak self] in self?.session?.togglePause() }),
        ]
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
        return true
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
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
