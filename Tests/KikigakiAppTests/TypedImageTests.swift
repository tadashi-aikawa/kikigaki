import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct TypedImageTests {
    private func image() throws -> TypedImageDraft {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<64 { for x in 0..<96 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = x < 48 ? 25 : 255
            pixels[offset + 1] = x < 48 ? 100 : 128
            pixels[offset + 2] = x < 48 ? 230 : 25
            pixels[offset + 3] = 255
        } }
        return try TypedImageDraft(data: #require(bitmap.representation(using: .png, properties: [:])))
    }
    private func config(_ root: URL) throws -> ResolvedConfig {
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        return config
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func 貼り付け画像は文字列より優先し削除と失敗時保持と新会議リセットができる() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        controller.apply(SessionSnapshot(state: .recording))
        let field = controller.typedEntry
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try image().data, forType: .png)
        board.setString("スクリーンショット.png", forType: .string)
        #expect(field.pasteImages(from: board))
        #expect(field.images.count == 1 && field.editor.string.isEmpty)
        #expect(!field.attachmentsView.isHidden)
        field.attachmentsView.onRemove?(0)
        #expect(field.images.isEmpty && field.attachmentsView.isHidden)
        #expect(field.pasteImages(from: board))
        var submitted: [TypedImageDraft] = []
        field.onSubmit = { _, images in submitted = images; return false }
        field.editor.onSubmit?()
        #expect(submitted.count == 1 && field.images.count == 1)
        controller.apply(SessionSnapshot(state: .idle))
        #expect(field.images.count == 1 && !field.pasteImages(from: board))
        controller.apply(SessionSnapshot(state: .preparing))
        #expect(field.images.isEmpty)
        controller.apply(SessionSnapshot(state: .recording))
        #expect(field.pasteImages(from: board))
        field.onSubmit = { _, _ in true }
        field.editor.onSubmit?()
        #expect(field.images.isEmpty && field.attachmentsView.isHidden)
    }

    @Test func ファイルコピーとTIFFを受け不正画像とサイズ超過を拒否する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try image()
        #expect(original.preview.size.width > 0 && original.preview.size.height > 0)
        let file = root.appendingPathComponent("日本語 空白.png")
        try original.data.write(to: file)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        #expect(try TypedImageDraft.read(from: board)?.first?.data == original.data)
        board.clearContents()
        let note = root.appendingPathComponent("notes.txt")
        try Data("通常の文章".utf8).write(to: note)
        board.writeObjects([note as NSURL])
        #expect(!TypedImageDraft.canRead(board))
        #expect(try TypedImageDraft.read(from: board) == nil)
        board.clearContents()
        board.writeObjects([note as NSURL, file as NSURL])
        #expect(try TypedImageDraft.read(from: board)?.count == 1)
        board.clearContents()
        board.setData(try #require(NSImage(data: original.data)?.tiffRepresentation), forType: .tiff)
        #expect(try TypedImageDraft.read(from: board)?.first?.fileExtension == "png")
        board.clearContents()
        let bitmap = try #require(NSBitmapImageRep(data: original.data))
        board.setData(try #require(bitmap.representation(using: .jpeg, properties: [:])), forType: .init("public.jpeg"))
        #expect(TypedImageDraft.canRead(board))
        #expect(try TypedImageDraft.read(from: board)?.first?.fileExtension == "jpg")
        board.clearContents(); board.setString("通常の文章", forType: .string)
        #expect(!TypedImageDraft.canRead(board))
        #expect(try TypedImageDraft.read(from: board) == nil)
        #expect(throws: (any Error).self) { try TypedImageDraft(data: Data("not an image".utf8)) }
        #expect(throws: (any Error).self) { try TypedImageDraft(data: Data(count: TypedImageDraft.maxBytes + 1)) }
    }

    @Test func 画像だけの投稿をコピー保存復元AI送信へ渡し元ファイルに依存しない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let markdownURL = root.appendingPathComponent("meeting.md")
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: markdownURL, config: try config(root), aiStore: store)
        let original = root.appendingPathComponent("original.png")
        try image().data.write(to: original)
        let draft = try TypedImageDraft(data: Data(contentsOf: original))
        try FileManager.default.removeItem(at: original)
        #expect(session.submitTyped("", images: [draft]))
        let entry = try #require(session.snapshot.utterances.first)
        let path = try #require(entry.imagePaths.first)
        #expect(path.hasPrefix(root.appendingPathComponent("meeting.attachments").path + "/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == draft.data)
        #expect(TypedImageDraft.preview(at: path) != nil)
        let copied = TranscriptRenderer.line(entry, names: .init(), timeline: session.snapshot.timeline)
        #expect(copied.contains("画像1: `\(path)`") && !copied.contains("\n"))
        session.submitAI(question: "添付画像を見て", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let question = try #require(session.aiRecord?.controller.conversation.questions.first)
        let context = try String(contentsOfFile: question.request.envelope.transcriptPath, encoding: .utf8)
        #expect(context.contains("画像1: `\(path)`"))
        await session.stop()
        #expect(!session.submitTyped("", images: [draft]))
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(markdown.contains("![画像1](<\(URL(fileURLWithPath: path).absoluteString)>)"))
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 0, utterances: [entry], names: .init())
        var archive = MeetingArchive(original: meeting, markdownURL: markdownURL)
        archive = try JSONDecoder().decode(MeetingArchive.self, from: JSONEncoder().encode(archive))
        #expect(archive.save().succeeded)
        #expect(!FileManager.default.fileExists(atPath: markdownURL.deletingPathExtension().appendingPathExtension("raw.md").path))
        #expect(archive.original.utterances.first?.imagePaths == [path])
    }

    @Test func 保存失敗では投稿せず下書き画像を再利用できる() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: try config(root), aiStore: AIRecordStore(directory: root))
        let blocked = root.appendingPathComponent("meeting.attachments")
        try Data("既存ファイル".utf8).write(to: blocked)
        let draft = try image()
        #expect(!session.submitTyped("本文", images: [draft]))
        #expect(session.snapshot.utterances.isEmpty)
        #expect(session.snapshot.message?.contains("保存できません") == true)
        try FileManager.default.removeItem(at: blocked)
        #expect(session.submitTyped("本文", images: [draft]))
        #expect(session.snapshot.utterances.count == 1)
    }

    @Test func 添付下書きと投稿済みの実ビューを確認する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        controller.window!.setContentSize(NSSize(width: 600, height: 640))
        var state = SessionSnapshot(state: .recording)
        controller.apply(state)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let draft = try image()
        board.setData(draft.data, forType: .png)
        if let output = ProcessInfo.processInfo.environment["KIKIGAKI_TYPED_CAPTURE"] {
            try draft.data.write(to: URL(fileURLWithPath: output).appendingPathComponent("image-fixture.png"))
        }
        controller.typedEntry.pasteImages(from: board)
        controller.typedEntry.pasteImages(from: board)
        controller.typedEntry.editor.string = "画像1と画像2を比較してください"
        func capture(_ name: String) throws {
            let view = controller.window!.contentView!
            view.layoutSubtreeIfNeeded()
            #expect(abs(view.bounds.width - 600) < 1)
            guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_TYPED_CAPTURE"] else { return }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        try capture("image-draft")
        controller.onSubmitTyped = { text, images in
            let paths = try! TypedImageDraft.save(images, beside: root.appendingPathComponent("meeting.md"))
            state.utterances = [try! Utterance(typedText: text, at: 0, postedAt: Date(), imagePaths: paths)]
            controller.apply(state)
            return true
        }
        controller.typedEntry.editor.onSubmit?()
        #expect(state.utterances.first?.imagePaths.count == 2)
        #expect(controller.typedEntry.images.isEmpty)
        let row = try #require(controller.rows.values.first)
        #expect(descendants(row).contains { ($0 as? NSButton)?.toolTip == "画像1を開く" })
        try capture("image-posted")
    }
}
