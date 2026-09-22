import AppKit
import WebKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.serialized) @MainActor struct BoardAppTests {
    private func config(_ root: URL) throws -> ResolvedConfig {
        try ResolvedConfig(config: ConfigLoader.parse(toml: """
        [[ai]]
        board = "## ボード"
        autoPrompt = "議事録本文を更新"
        autoStart = true
        """), home: root)
    }
    @Test func 開始シートでボードにはパスが必須で手動の初期文は残る() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = try config(root)
        let sheet = StartSheet(profiles: config.aiProfiles, diarizationEnabled: false, exclusion: AudioExclusion())
        #expect(sheet.options == nil)
        sheet.startPressed()
        #expect(sheet.minutesHintText == BoardPrompt.missingLocation)
        sheet.setMinutesPath(root.appendingPathComponent("minutes.md").path)
        #expect(sheet.options?.schedule?.prompt == BoardPrompt.builtIn)
        #expect(!sheet.editor.isEditable)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        #expect(session.manualDraft(for: config.aiProfiles[0]) == "議事録本文を更新")
    }
    @Test func 三つの開始経路はパスか書き先指示を必要とする() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for location: String? in [nil, "作業用に作成"] {
            for path: String? in [nil, "/tmp/minutes.md"] {
                let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
                var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
                config.ai = ResolvedAIConfig(config: AIConfig(autoStart: true, board: "## ボード", boardLocation: location), home: root)
                let allowed = location != nil || path != nil
                let sheet = StartSheet(profiles: config.aiProfiles, diarizationEnabled: false, exclusion: AudioExclusion(), minutesPath: path)
                #expect((sheet.options != nil) == allowed)
                let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                             aiStore: AIRecordStore(directory: root))
                if let path { try session.selectMinutes(path) }
                let robot = AIScheduleSheet(session: session, profile: config.aiProfiles[0])
                #expect(robot.canStart == allowed)
                if !allowed { #expect(robot.hintText == BoardPrompt.missingLocation) }
                let options = try AIScheduleOptions(prompt: "古い下書き", interval: 60)
                if allowed {
                    try session.startAISchedule(options: options, helper: URL(fileURLWithPath: "/bin/echo"))
                    #expect(try session.previewMinutesStore()?.state.boardHeading == "## ボード")
                    #expect(session.lastScheduleOptions?.prompt.contains("作業用に作成") == (path == nil))
                    session.stopAISchedule()
                } else {
                    #expect(throws: (any Error).self) { try session.startAISchedule(options: options, helper: URL(fileURLWithPath: "/bin/echo")) }
                }
            }
        }
    }
    @Test func 作成通知後は二回目と手動へ同じパスを渡しボードタブが出る() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let records = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path,
            board: "## ボード", boardLocation: "ここに作成"), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
            aiStore: records, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("最初の論点")
        try session.startAISchedule(options: .init(prompt: "下書き", interval: 3600), helper: URL(fileURLWithPath: "/bin/echo"))
        defer { session.stopAISchedule() }
        await session.submissionTaskForTesting?.value
        let controller = try #require(session.aiRecord?.controller)
        let first = try #require(controller.conversation.questions.first?.request)
        #expect(first.envelope.participant.minutesPath == nil)
        #expect(first.envelope.participant.question.contains("ここに作成"))
        let path = root.appendingPathComponent("created.md")
        try Data("# 議事録\n## 本文\n議事録本文\n## ボード\n第1版".utf8).write(to: path)
        let event = try AIMinutesEvent(request: first, path: path.path, recordedAt: Date())
        let inbox = [".kikigaki-context", session.aiMeetingID.uuidString, "ai", "inbox"]
        try AIFileStore(root: root).write(AIJSON.encode(event), to: inbox + [event.filename])
        func reply(_ request: AIRequest) throws {
            let answer = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "更新済み")
            try AIFileStore(root: root).write(AIJSON.encode(answer), to: inbox + [request.id.uuidString + ".result.json"])
            controller.scan()
        }
        try reply(first)
        let store = try #require(try session.previewMinutesStore())
        #expect(store.state.targetSource == .ai && store.state.humanMinutesPath == nil)
        #expect(store.state.participantMinutesPath == path.path)
        let restored = MinutesStore(meetingID: store.meetingID, outputDirectory: root, markdownURL: store.markdownURL)
        #expect(restored.state.participantMinutesPath == path.path && restored.state.boardHeading == "## ボード")
        let defaults = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), defaults: defaults.value)
        defer { preview.stop() }
        preview.update(path: store.state.minutesPath, source: store.state.targetSource, active: true, boardHeading: store.state.boardHeading)
        for _ in 0..<300 {
            if !preview.tabs.isHiddenOrHasHiddenAncestor { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!preview.tabs.isHiddenOrHasHiddenAncestor)
        session.setScheduleTranscriptForTesting("最初の論点と次の論点")
        session.fireAIScheduleNow()
        await session.submissionTaskForTesting?.value
        let second = try #require(controller.conversation.questions.last?.request)
        #expect(second.id != first.id)
        #expect(second.envelope.participant.minutesPath == path.path)
        #expect(second.envelope.participant.question == BoardPrompt.builtIn)
        try reply(second)
        session.submitAI(question: "本文を更新", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let manual = try #require(controller.conversation.questions.last?.request)
        #expect(manual.trigger == nil && manual.id != second.id)
        #expect(manual.envelope.participant.minutesPath == path.path && manual.envelope.participant.boardHeading == "## ボード")
        try session.selectMinutes(root.appendingPathComponent("human.md").path)
        #expect(store.state.participantMinutesPath == root.appendingPathComponent("human.md").path)
        try session.selectMinutes(nil)
        #expect(store.state.participantMinutesPath == nil && store.state.boardHeading == "## ボード")
    }
    @Test func 自動開始は議事録パスを検証し会議の見出しを復元する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = try config(root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        let options = try AIScheduleOptions(prompt: "古い下書き", interval: 60)
        #expect(throws: (any Error).self) { try session.startAISchedule(options: options, helper: root.appendingPathComponent("helper")) }
        try session.selectMinutes(root.appendingPathComponent("minutes.md").path)
        try session.startAISchedule(options: options, helper: root.appendingPathComponent("helper"))
        defer { session.stopAISchedule() }
        #expect(session.lastScheduleOptions?.prompt == BoardPrompt.builtIn)
        let store = try #require(try session.previewMinutesStore())
        let source = store.state.targetSource, changedAt = store.state.targetChangedAt
        #expect(store.state.boardHeading == "## ボード")
        let restored = MinutesStore(meetingID: store.meetingID, outputDirectory: root, markdownURL: store.markdownURL)
        #expect(restored.state.boardHeading == "## ボード")
        #expect(restored.state.targetSource == source && restored.state.targetChangedAt == changedAt)
    }
    @Test func タブは見出しがある時だけ表示し両本文を分離する() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), defaults: defaults.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview
        defer { preview.stop(); window.orderOut(nil) }
        preview.update(path: nil, source: nil, active: true, boardHeading: "## ボード")
        preview.receive(.body("# 会議\n## 本文\n手動の記録\n## ボード(17:48 更新)\nボードだけの論点\n## 次\n後半の本文", [], modifiedAt: Date()))
        for _ in 0..<300 {
            if preview.boardDocument.renderedText.contains("ボードだけの論点") && preview.minutesDocument.renderedText.contains("後半の本文") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(preview.minutesDocument.renderedText.contains("手動の記録"))
        #expect(!preview.minutesDocument.renderedText.contains("ボードだけの論点"))
        #expect(!preview.boardDocument.renderedText.contains("手動の記録"))
        #expect(!preview.tabs.isHiddenOrHasHiddenAncestor)
        #expect(preview.tabs.label(forSegment: 1) == "ボード 17:48")
        #expect(!preview.minutesDocument.renderedText.contains("17:48 更新"))
        preview.selectBoard(true)
        #expect(preview.document === preview.boardDocument)
        _ = try await preview.minutesDocument.webView.evaluateJavaScript("window.savedHeading = document.querySelector('h1'); true")
        _ = try await preview.boardDocument.webView.evaluateJavaScript("window.savedBody = document.body.firstElementChild; document.body.style.minHeight = '3000px'; window.scrollTo(0, 120); true")
        let boardScroll = try await preview.boardDocument.webView.evaluateJavaScript("window.scrollY") as? Double
        #expect((boardScroll ?? 0) > 0)
        for (suffix, label) in [("(18:07 更新)", "ボード 18:07"), ("", "ボード")] {
            preview.receive(.body("# 会議\n## 本文\n手動の記録\n## ボード\(suffix)\nボードだけの論点\n## 次\n後半の本文", [], modifiedAt: Date()))
            #expect(preview.tabs.label(forSegment: 1) == label)
            #expect(preview.selectedBoard && preview.tabs.selectedSegment == 1)
            #expect(try await preview.minutesDocument.webView.evaluateJavaScript("window.savedHeading === document.querySelector('h1')") as? Bool == true)
            #expect(try await preview.boardDocument.webView.evaluateJavaScript("window.savedBody === document.body.firstElementChild") as? Bool == true)
            #expect(try await preview.boardDocument.webView.evaluateJavaScript("window.scrollY") as? Double == boardScroll)
        }
        preview.receive(.body("# 会議\nボードが消えた", [], modifiedAt: Date()))
        #expect(preview.document === preview.minutesDocument)
        #expect(preview.tabs.isHiddenOrHasHiddenAncestor)
        preview.resetContext()
        #expect(!preview.selectedBoard)
    }
    @Test func replayでプロファイルとパスを指定でき通常起動では無視する() throws {
        let env = ["KIKIGAKI_DEBUG_AI_AUTO_PROFILE": "ボード", "KIKIGAKI_DEBUG_MINUTES_PATH": "/tmp/minutes.md"]
        let debug = try ReplayDebugOptions.load(arguments: ["--replay"], environment: env)
        #expect(debug.automaticProfile == "ボード" && debug.minutesPath == "/tmp/minutes.md")
        #expect(try ReplayDebugOptions.load(arguments: [], environment: env).automaticProfile == nil)
        #expect(throws: (any Error).self) { try ReplayDebugOptions.load(arguments: ["--replay"], environment: ["KIKIGAKI_DEBUG_MINUTES_PATH": "relative.md"]) }
    }
    @Test func 見出し保存の競合でも新しい人のパスと時刻を巻き戻さない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), disk = MinutesFileStore(root: root, meetingID: meeting)
        let store = MinutesStore(meetingID: meeting, outputDirectory: root)
        try store.select("/tmp/元.md", at: Date(timeIntervalSince1970: 1))
        var attempts = 0
        store.beforeSave = {
            attempts += 1
            if attempts == 1 {
                let old = try disk.read()
                var next = old
                try next.select("/tmp/新.md", at: Date(timeIntervalSince1970: 2)); try next.advanceRevision()
                try disk.save(next, replacing: old)
            }
        }
        try store.bindBoard("## ボード")
        #expect(attempts == 2 && store.state.revision == 3)
        #expect(store.state.boardHeading == "## ボード" && store.state.humanMinutesPath == "/tmp/新.md")
        #expect(store.state.targetChangedAt == Date(timeIntervalSince1970: 2) && store.state.targetSource == .human)
    }
    @Test func 手動送信はボード設定のない宛先にも会議の見出しを渡す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let records = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: records)
        try session.selectMinutes(root.appendingPathComponent("minutes.md").path)
        try session.previewMinutesStore()?.bindBoard("## ボード")
        session.submitAI(question: "本文を更新", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.envelope.participant.boardHeading == "## ボード")
        #expect(request.envelope.participant.minutesPath == root.appendingPathComponent("minutes.md").path)
        #expect(request.trigger == nil)
    }
    @Test func Vault外のボードのリンク行とカードから詳細図へ移動する() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 650), defaults: defaults.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview
        defer { preview.stop(); window.orderOut(nil) }
        let markdown = """
        # 会議
        ## 本文
        手動の記録
        ## ボード
        ~~~mermaid
        flowchart TB
          T1["T1 料金"]
          click T1 "#料金%2010%25の詳細"
        ~~~
        [[#料金 10%の詳細|料金の詳細]]

        \(String(repeating: "段落\n\n", count: 40))
        ### 料金 10%の詳細
        ~~~mermaid
        flowchart TB
          T2["T2 値上げ幅"]
          T3["T3 開始日"]
          T2 --> T3
          classDef now stroke:#9b72c6,stroke-width:3px
          class T2 now
        ~~~
        \(String(repeating: "末尾\n\n", count: 30))
        """
        preview.update(path: nil, source: nil, active: true, boardHeading: "## ボード")
        preview.receive(.body(markdown, [], modifiedAt: Date()))
        for _ in 0..<400 {
            if preview.boardDocument.renderedText.contains("T3 開始日") && preview.minutesDocument.renderedText.contains("手動の記録") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        preview.selectBoard(true)
        preview.layoutSubtreeIfNeeded()
        let web = preview.boardDocument.webView
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.diagram').length") as? Int == 2)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('main a[href^=\"#\"]').length") as? Int == 1)
        for selector in ["main a[href^=\"#\"]", ".diagram g.node[role=link]"] {
            _ = try await web.evaluateJavaScript("scrollTo(0, 0); true")
            _ = try await web.callAsyncJavaScript("""
            document.querySelector(selector).dispatchEvent(new MouseEvent('click', {bubbles:true}));
            return true;
            """, arguments: ["selector": selector], contentWorld: .page)
            try await Task.sleep(for: .milliseconds(100))
            #expect(preview.selectedBoard)
            #expect(try await web.evaluateJavaScript("scrollY > 0") as? Bool == true)
            #expect(try await web.evaluateJavaScript("""
            (() => { const h = document.querySelector('h3'), r = h.getBoundingClientRect();
              return r.top >= 0 && r.bottom < innerHeight && h.getAnimations().length > 0; })()
            """) as? Bool == true)
        }
        #expect(!preview.minutesDocument.renderedText.contains("料金の詳細"))
    }
    @Test func 実Mermaidのカードから議事録へ移動し外部clickは無効() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 650), defaults: defaults.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview
        defer { preview.stop(); window.orderOut(nil) }
        let markdown = """
        # 会議
        ## 決定事項 {#decision}
        本文の決定
        ## ボード
        ```mermaid
        flowchart TB
          T1["T1 決定事項"]
          T2["T2 外部"]
          T3["T3 callback"]
          click T1 "#decision"
          click T2 "https://example.com"
          click T3 callback
        ```
        """
        preview.update(path: nil, source: nil, active: true, boardHeading: "## ボード")
        preview.receive(.body(markdown, [], modifiedAt: Date()))
        for _ in 0..<400 {
            if preview.boardDocument.renderedText.contains("T1 決定事項") && preview.minutesDocument.renderedText.contains("本文の決定") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        preview.selectBoard(true)
        let web = preview.boardDocument.webView
        let nodes = try await web.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('.diagram g.node')].map(n=>[n.id,n.getAttribute('role')]))") as? String ?? "なし"
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.diagram g.node[role=link]').length") as? Int == 1, "ノード: \(nodes)、本文: \(preview.boardDocument.renderedText)")
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.diagram a,.diagram script').length") as? Int == 0)
        _ = try await web.evaluateJavaScript("document.querySelector('.diagram g.node[role=link]').dispatchEvent(new MouseEvent('click', {bubbles:true}))")
        for _ in 0..<100 {
            if !preview.selectedBoard { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!preview.selectedBoard)
        #expect(try await preview.minutesDocument.webView.evaluateJavaScript("window.minutes.jump('decision')") as? Bool == true)
        #expect(try await preview.minutesDocument.webView.evaluateJavaScript("document.querySelector('#toc').textContent.includes('ボード')") as? Bool == false)
        _ = try await preview.minutesDocument.webView.evaluateJavaScript("window.originalHeading = document.querySelector('h1'); true")
        preview.markUpdateBaseline()
        preview.receive(.body(markdown.replacingOccurrences(of: "T1 決定事項", with: "T1 更新済み"), [], modifiedAt: Date()))
        for _ in 0..<300 {
            if preview.boardDocument.renderedText.contains("更新済み") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(preview.boardDocument.renderedText.contains("更新済み"))
        #expect(!preview.minutesDocument.renderedText.contains("更新済み"))
        #expect(try await preview.minutesDocument.webView.evaluateJavaScript("window.originalHeading === document.querySelector('h1')") as? Bool == true)
    }
}
