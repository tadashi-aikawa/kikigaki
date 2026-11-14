import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
/// 利用者向けサイト `site/public/captures/` の画像の撮影。製品の振る舞いは確かめない。
///
/// `KIKIGAKI_SITE_CAPTURE=<出力先>` を渡したときだけ、2倍の画素のPNGを書き出す。指定しなければ何もしない。
/// - `KIKIGAKI_SITE_AVATARS=<フォルダ>`: 宛先のアバター。`相談.webp` と `議事録.webp` を読む。無ければアバターなしで撮る
/// - `KIKIGAKI_SITE_SLIDES=<フォルダ>`: 画像レーンに写す画面。無ければ画像レーンは撮らない
/// - ディスプレイ名は利用者の環境に依らない内蔵ディスプレイの名前にする。実機の外付けディスプレイの型番を写さない
/// - `KIKIGAKI_SITE_MENU=1`: 画面の記録のメニューも撮る。本物のメニューを画面に出すので、撮る間はMacへ触らない
/// - 切り出しとWebPへの変換は撮影の後に行う。手順は docs/dev-flags.md の「テスト」
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct SiteCaptureTests {
    private let display = ScreenDisplay(id: 1, name: "Built-in Retina Display", points: CGSize(width: 1512, height: 982), menuBarFraction: 0.03)
    private var output: URL? {
        ProcessInfo.processInfo.environment["KIKIGAKI_SITE_CAPTURE"].map { URL(fileURLWithPath: $0) }
    }
    private func avatar(_ name: String) -> String? {
        guard let folder = ProcessInfo.processInfo.environment["KIKIGAKI_SITE_AVATARS"] else { return nil }
        let path = URL(fileURLWithPath: folder).appendingPathComponent("\(name).webp").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    private func write(_ view: NSView, rect: NSRect, name: String) throws {
        guard let output else { return }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(rect.width) * 2, pixelsHigh: Int(rect.height) * 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32))
        bitmap.size = rect.size
        view.cacheDisplay(in: rect, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(name + ".png"))
    }
    /// 選んだラジオとチェックを、操作中のウィンドウと同じ青で描く。
    /// テストのアプリは前面に出さないので、そのままでは非アクティブの灰色で描かれる。前面に出すと利用者の操作を奪う。
    /// 撮影の指定があるときだけ、このウィンドウのクラスに限って差し替える。テストのプロセスの終わりまで残る。
    private func keyAppearance(_ window: NSWindow) {
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        for name in ["isKeyWindow", "isMainWindow", "hasKeyAppearance", "_hasKeyAppearance",
                     "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus"] {
            class_replaceMethod(type(of: window), NSSelectorFromString(name), imp, "c@:")
        }
    }
    /// アバターは裏で読むので、描く前に読み終えるのを待つ。
    private func settle() async throws {
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// 開始シート。前回(2026-11-01)の撮影と同じ宛先・議事録・マイクに、画面の行でディスプレイを選んだ状態。
    @Test func 開始シート() async throws {
        guard output != nil else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let consult = avatar("相談").map { "avatar = \"\($0)\"\n" } ?? ""
        let minutes = avatar("議事録").map { "avatar = \"\($0)\"\n" } ?? ""
        let profiles = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "相談"
        cli = "claude"
        model = "claude-opus-5-5"
        effort = "medium"
        cwd = "/Users/Shared/KIKIGAKI/meeting"
        identifySpeakers = true
        alwaysPrompt = "会議の流れに沿って短く答えてください。"
        \(consult)
        [[ai]]
        name = "議事録"
        cli = "claude"
        model = "claude-opus-5-5"
        effort = "medium"
        cwd = "/Users/Shared/KIKIGAKI/meeting"
        identifySpeakers = true
        allowWork = true
        autoStart = true
        autoIntervalMinutes = 5
        initialPrompt = "決まったこと・担当と期限・まだ決めていないことを、見出しを分けて議事録へ更新してください。"
        alwaysPrompt = "議事録の見出しは変えないでください。"
        \(minutes)
        """), home: root).aiProfiles
        let suite = "SiteCaptureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sheet = StartSheet(profiles: profiles, diarizationEnabled: true,
                               exclusion: AudioExclusion(enabled: false, thresholdDBFS: -45),
                               minutesPath: "/Users/Shared/KIKIGAKI/minutes/勉強会の準備.md",
                               minutesHistory: ["/Users/Shared/KIKIGAKI/minutes/勉強会の準備.md"],
                               defaults: defaults, systemAudioMode: .include,
                               screenDisplays: [display], screenDisplayName: display.name,
                               outputKind: { .builtInSpeaker }, microphoneName: { "USB MICROPHONE" })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        sheet.present(on: parent)
        keyAppearance(sheet.window)
        defer { sheet.close() }
        try await settle()
        let scroll = try #require(sheet.window.contentView as? NSScrollView)
        let view = try #require(scroll.documentView)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        try write(view, rect: scroll.documentVisibleRect, name: "start-sheet")
    }

    /// 画像レーン。勉強会の資料を流しながら話している録音中の会議。間の2枚はトレイに畳む。
    /// - `KIKIGAKI_SITE_SLIDES=<フォルダ>`: 写す画面の画像。`.webp` を名前順に6枚使う。公開してよい画像だけを置く
    @Test func 画像レーン() async throws {
        try await studyLane(name: "screen-lane", size: NSSize(width: 479, height: 820))
    }

    /// 画像レーンの「+2枚」を押して、間の2枚を開いた形。同じ会議を、開いたトレイが収まる高さで撮る。
    @Test func 画像レーンを開いた形() async throws {
        try await studyLane(name: "screen-lane-expanded", size: NSSize(width: 479, height: 1040), expanded: true)
    }

    /// 発言と画像の境目を左へドラッグして、画像を大きくした形。同じ会議を、広げた幅が収まるウィンドウで撮る。
    @Test func 画像レーンを広げた形() async throws {
        try await studyLane(name: "screen-lane-wide", size: NSSize(width: 860, height: 820), laneWidth: 400)
    }

    /// フッターの画面の記録のメニュー。本物のメニューを画面に一瞬出し、メニューのウィンドウだけを `screencapture -l` で撮って閉じる。
    /// - ディスプレイの一覧は差し替え、実機のディスプレイの型番を写さない
    /// - 撮る間はMacへ触らない。メニューは画面に出さないと描けず、操作が入るとメニューが閉じる
    /// - 画面に出すので、`KIKIGAKI_SITE_MENU=1` を添えたときだけ撮る。ほかの撮影と一緒に流したときに不意に出さない
    @Test func 画面の記録のメニュー() async throws {
        guard let output, ProcessInfo.processInfo.environment["KIKIGAKI_SITE_MENU"] == "1" else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        let suite = "SiteCaptureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        let external = ScreenDisplay(id: 2, name: "External Display", points: CGSize(width: 2560, height: 1440), menuBarFraction: 0.02)
        controller.connectedScreenDisplays = { [display, external] }
        var state = SessionSnapshot(ai: AIViewState(conversation: AIConversation(meetingID: UUID())), state: .recording,
            utterances: [.init(speaker: 0, start: 0, end: 1, text: "資料を映しますね。")])
        state.screenControl = ScreenControlState(display: .on(display), selected: display, paused: false)
        state.canCaptureScreenNow = true
        controller.apply(state)
        let menu = controller.screenMenu()
        let image = output.appendingPathComponent("screen-menu.png")
        try? FileManager.default.removeItem(at: image)
        // タイマーはメニューの追跡の中で動くので、失敗はここに残し、popUp から戻った後に確かめる。
        var failure: String?
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                defer { menu.cancelTracking() }
                let windows = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Menu") }
                guard let window = windows.first else { failure = "メニューのウィンドウが見つからない"; return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l\(window.windowNumber)", image.path]
                do { try process.run() } catch { failure = "screencapture を起動できない: \(error)"; return }
                process.waitUntilExit()
                if process.terminationStatus != 0 { failure = "screencapture が \(process.terminationStatus) で終わった" }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 400, y: 600), in: nil)
        timer.invalidate()
        if let failure { Issue.record(Comment(rawValue: failure)); return }
        // 画面収録の許可が無いと、screencapture は成功で終わっても画像を書かない。
        #expect(FileManager.default.fileExists(atPath: image.path), "画像が書かれていない。端末の画面収録の許可を確かめる")
    }

    /// 画像レーンの3枚に共通の会議。`expanded` で間の2枚を開き、`laneWidth` でレーンの幅をドラッグしたのと同じに広げる。
    private func studyLane(name: String, size: NSSize, expanded: Bool = false, laneWidth: CGFloat? = nil) async throws {
        guard output != nil, let folder = ProcessInfo.processInfo.environment["KIKIGAKI_SITE_SLIDES"] else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".webp") }.sorted()
        try #require(names.count >= 6)
        let paths = names.prefix(6).map { URL(fileURLWithPath: folder).appendingPathComponent($0).path }
        let suite = "SiteCaptureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        defer { controller.minutesSplit.preview.stop(); controller.finishScreenLaneTransitions(reflow: false) }
        controller.minutesSplit.visibleScreen = { _ in NSRect(x: 0, y: 0, width: 2400, height: 1400) }
        controller.presentScreenPreview = {}
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setFrame(NSRect(x: 0, y: 100, width: size.width, height: size.height), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        let started = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10, minute: 2, second: 10)))
        let label = "\(display.name) · Google Chrome「KIKIGAKI — 声をすべてドキュメントに」"
        func screen(_ index: Int, at time: Double) throws -> Utterance {
            try Utterance(screenLabel: label, imagePath: paths[index], at: time, postedAt: started.addingTimeInterval(time))
        }
        let rows: [Utterance] = [
            Utterance(speaker: 0, start: 0, end: 7, text: "では森さん、勉強会の資料を流してもらえますか。"),
            try screen(0, at: 4),
            Utterance(speaker: 1, start: 9, end: 40, text: "まず作った理由です。毎日の会議が多くて、記録まで手が回らなかった話をします。"),
            try screen(1, at: 12), try screen(2, at: 20), try screen(3, at: 27), try screen(4, at: 35),
            Utterance(speaker: 2, start: 43, end: 55, text: "2層構造の図は、声からMarkdownまでを先に見せると伝わりやすそうです。"),
            try screen(5, at: 49)
        ]
        var state = SessionSnapshot(ai: AIViewState(conversation: AIConversation(meetingID: UUID())), state: .recording,
                                    utterances: rows.sorted { $0.start < $1.start },
                                    timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "青木", 1: "森", 2: "星野"]))
        state.elapsed = 58
        state.markdownURL = URL(fileURLWithPath: "/Users/Shared/KIKIGAKI/2026-11-04_1002.md")
        state.detectedSpeakerSlots = [0, 1, 2]
        state.manualDestination = .init(slot: 1, name: "相談", avatar: avatar("相談"), identifySpeakers: true)
        state.manualDraftSendState = .ready(appendix: false)
        state.screenControl = ScreenControlState(display: .on(display), selected: display, paused: false)
        controller.apply(state)
        // 別の会議へ移る並べ直しで開いた覚えは消えるので、apply の後に開いて並べ直す。
        if expanded {
            controller.screenLaneExpanded = [paths[2], paths[3]]
            controller.refreshRows()
        }
        if let laneWidth {
            controller.minutesSplit.dragLane(to: laneWidth, commit: true)
            controller.applyScreenLaneWidth()
        }
        let content = try #require(window.contentView)
        let thumbnail = ScreenLaneLayout.thumbnailWidth(laneWidth: Double(controller.minutesSplit.laneWidth))
        await ScreenThumbnailLoader.shared.preload(controller.screenPreview.paths,
                                                   pixels: ScreenLaneLayout.decodePixels(thumbnailWidth: thumbnail))
        try await settle()
        content.layoutSubtreeIfNeeded()
        controller.transcriptDocument.scroll(NSPoint(x: 0, y: 0)); controller.scrolled()
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        try write(content, rect: content.bounds, name: name)
    }

    /// フッター。前回と同じく、自動は送らない、手動は「相談」が実行中。画面の操作は内蔵ディスプレイを記録中。
    /// 幅は前回の撮影のウィンドウと同じ479pt。画面の操作が入った分だけ、宛先の2段が狭くなる。
    @Test func フッター() async throws {
        guard output != nil else { return }
        let width: CGFloat = 479
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SiteCaptureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: width, height: 578))
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        defer { window.orderOut(nil) }

        var history = try AIStreamHistory(meetingID: UUID())
        let context = try history.prepare(lines: [], outputDirectory: root)
        var conversation = AIConversation(meetingID: history.meetingID)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "相談", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/1/1.json").path,
            requestToken: "site", question: "確認", capturedAt: Date(), audioCutoffSeconds: 0,
            trigger: nil, profile: "相談", profileSlot: 1)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant),
            number: 1, voiceQuestion: "", snapshot: context)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: Date()); try $0.submitted() }
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: [.init(speaker: 0, start: 0, end: 1, text: "ここまでの決定を整理してもらいましょう。")],
            markdownURL: root.appendingPathComponent("meeting.md"))
        state.manualDestination = .init(slot: 1, name: "相談", avatar: avatar("相談"), identifySpeakers: true)
        state.manualDraftSendState = .ready(appendix: true)
        state.screenControl = ScreenControlState(display: .on(display), selected: display, paused: false)
        controller.apply(state)
        let size = controller.windowWillResize(window, to: NSSize(width: width, height: 600))
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        try await settle()
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let footer = controller.compactFooter
        footer.displayIfNeeded()
        try write(footer, rect: footer.bounds, name: "footer")
    }
}
}
