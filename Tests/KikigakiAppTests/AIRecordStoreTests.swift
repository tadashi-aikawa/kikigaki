import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIRecordStoreTests {
    @Test func 新会議中の旧会議への回答を元の両Markdownへ保存する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = try testDirectory(); defer { try? FileManager.default.removeItem(at: registry) }
        let fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        let store = AIRecordStore(directory: registry, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let first = try store.begin(meetingID: UUID(), markdownURL: root.appendingPathComponent("first.md"), config: config)
        let request = try first.controller.prepare(lines: ["[12:00:00] 田中: 質問"], question: "質問", voiceQuestion: "",
            capturedAt: Date(), cutoff: 1, tail: nil, config: config, helper: root.appendingPathComponent("helper"))
        try await first.controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
        try await first.controller.send(request, config: config)
        let utterances = [Utterance(speaker: 0, start: 0, end: 1, text: "本文")]
        var archive = MeetingArchive(original: .init(startedAt: Date(), duration: 1, utterances: utterances, names: SpeakerNames()),
            processed: utterances, candidateCount: 0, markdownURL: first.manifest.markdownURL)
        #expect(store.save(&archive, for: first.manifest.meetingID).succeeded)
        let second = try store.begin(meetingID: UUID(), markdownURL: root.appendingPathComponent("second.md"), config: config)
        let result = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "旧会議への回答")
        let base = [".kikigaki-context", first.manifest.meetingID.uuidString, "ai"]
        try AIFileStore(root: root).write(AIJSON.encode(result), to: base + ["inbox", result.filename], replacing: false)
        first.controller.scan()
        #expect(second.controller.conversation.questions.isEmpty)
        let markdown = try String(contentsOf: first.manifest.markdownURL, encoding: .utf8)
        let raw = try String(contentsOf: root.appendingPathComponent("first.raw.md"), encoding: .utf8)
        #expect(markdown.contains("旧会議への回答") && raw.contains("旧会議への回答"))
        archive.original.names.set("変更後", for: 0)
        #expect(store.save(&archive, for: first.manifest.meetingID).succeeded)
        #expect(try String(contentsOf: first.manifest.markdownURL, encoding: .utf8).contains("変更後"))
        #expect(try String(contentsOf: first.manifest.markdownURL, encoding: .utf8).contains("旧会議への回答"))
        let entries = try AIJSON.decode([AIRegistration].self, from: AIFileStore(root: registry).read(["ai-roots.json"]))
        #expect(!entries.contains { $0.meetingID == first.manifest.meetingID })
    }
    @Test func 再起動時は登録済みの未完了会議だけを回収して起動しない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = try testDirectory(); defer { try? FileManager.default.removeItem(at: registry) }
        let fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        var initial: AIRecordStore? = AIRecordStore(directory: registry, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let id = UUID(), markdown = root.appendingPathComponent("stopped.md")
        var record: AIRecordStore.Record? = try initial!.begin(meetingID: id, markdownURL: markdown, config: config)
        let request = try record!.controller.prepare(lines: ["[12:00:00] A: 会話"], question: "質問", voiceQuestion: "",
            capturedAt: Date(), cutoff: 1, tail: nil, config: config, helper: root.appendingPathComponent("helper"))
        try await record!.controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
        try await record!.controller.send(request, config: config)
        var archive = MeetingArchive(original: .init(startedAt: Date(), duration: 1, utterances: [], names: SpeakerNames()), processed: nil, candidateCount: 0, markdownURL: markdown)
        #expect(initial!.save(&archive, for: id).succeeded)
        record = nil; initial = nil
        let result = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "終了中に保存した回答")
        try AIFileStore(root: root).write(AIJSON.encode(result), to: [".kikigaki-context", id.uuidString, "ai", "inbox", result.filename], replacing: false)
        var starts = 0, sounds = 0
        let restored = AIRecordStore(directory: registry, makeHerdr: { starts += 1; throw AIHerdrError.notReady })
        restored.onNewResult = { _ in sounds += 1 }
        restored.recover()
        #expect(starts == 0 && sounds == 0)
        #expect(restored.records[id]?.controller.connection == nil)
        #expect(restored.records[id]?.controller.canSend == false)
        #expect(try String(contentsOf: markdown, encoding: .utf8).contains("終了中に保存した回答"))
        #expect(try AIJSON.decode([AIRegistration].self, from: AIFileStore(root: registry).read(["ai-roots.json"])).isEmpty)
    }
    @Test func 壊れた登録簿を上書きせず新規送信を拒否する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("broken".utf8), files = AIFileStore(root: root)
        try files.write(bytes, to: ["ai-roots.json"])
        let store = AIRecordStore(directory: root); store.recover()
        #expect(!store.warnings.isEmpty)
        #expect(throws: AIError.invalid("registry unavailable")) {
            try store.begin(meetingID: UUID(), markdownURL: root.appendingPathComponent("new.md"), config: .init(config: AIConfig(), home: root))
        }
        #expect(try files.read(["ai-roots.json"]) == bytes)
    }
}
