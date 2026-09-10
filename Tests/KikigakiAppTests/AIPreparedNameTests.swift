import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite @MainActor struct AIPreparedNameTests {
    @Test func 名前欄は64バイトで検証し空なら従来どおり起動する() throws {
        _ = NSApplication.shared
        let sheet = AIPrepareSheet(profiles: [(1, "議事録")], selected: 1)
        sheet.update(rows: [], launching: false)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let start = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "起動" })
        var names: [String?] = []
        sheet.onStart = { slot, name in #expect(slot == 1); names.append(name) }
        for text in ["", "決定事項の確認役", String(repeating: "a", count: 64), String(repeating: "あ", count: 22), "a\nb"] {
            sheet.nameField.stringValue = text
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.nameField))
            let valid = text.utf8.count <= 64 && !text.contains("\n")
            #expect(start.isEnabled == valid)
            start.performClick(nil)
        }
        #expect(names == [nil, "決定事項の確認役", String(repeating: "a", count: 64)])
        sheet.nameField.stringValue = "決定事項の確認役"
        sheet.update(rows: [.init(id: UUID(), label: "決定事項の確認役 · 定例会議の確認 · 23:50起動", reason: nil)], launching: false)
        sheet.window.setContentSize(NSSize(width: 600, height: 350))
        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["KIKIGAKI_CAPTURE_PREPARED_NAME"] == "1" {
            let view = try #require(content.superview)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/kikigaki-fb-mock4/prepared-name-sheet-600.png"))
        }
    }

    @Test func 準備の名前を台帳と宛先とペインとenvelopeへ引き継ぐ() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: try ConfigLoader.parse(toml: "[[ai]]\nname = \"議事録\"\ncommand = \"/bin/echo\"\ncwd = \"\(root.path)\""), home: root).aiProfiles[0]
        let fake = FakeHerdr()
        let herdr = AIHerdr(run: { try await fake.run($0, $1) })
        let store = AIPreparedStore(directory: root, makeHerdr: { herdr }); store.load()
        await store.prepare(profile: config, helper: URL(fileURLWithPath: "/bin/echo"), outputDirectory: root, name: "決定事項の確認役")
        let entry = try #require(store.unbound.first)
        #expect(entry.name == "決定事項の確認役")
        #expect(await fake.commands.contains(["pane", "rename", try #require(entry.connection?.paneID), "--", "決定事項の確認役"]))
        await fake.setPaneTitles([try #require(entry.connection?.paneID): "定例会議の確認"])
        await store.refresh()
        #expect(store.label(entry).hasPrefix("決定事項の確認役 · 定例会議の確認 · "))
        #expect(store.label(entry, includingName: false) == store.label(entry))
        let restored = AIPreparedStore(directory: root, makeHerdr: { herdr }); restored.load()
        #expect(restored.unbound.first?.name == entry.name)
        let controller = try testAIController(meetingID: UUID(), outputDirectory: root, herdr: herdr)
        try await controller.adopt(entry, config: config)
        let request = try controller.prepare(lines: [], question: "確認", voiceQuestion: "", capturedAt: Date(), cutoff: 0,
            tail: nil, config: config, helper: URL(fileURLWithPath: "/bin/echo"))
        #expect(request.envelope.participant.preparedSessionName == entry.name)
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(request.envelope.participant)) as? [String: Any])
        #expect(json["prepared_session_name"] as? String == entry.name)
        json.removeValue(forKey: "prepared_session_name")
        #expect(try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: json)).preparedSessionName == nil)
        json["prepared_session_name"] = String(repeating: "あ", count: 22)
        #expect(throws: AIError.self) { try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func 台帳の任意の名前を保存し旧データも読める() throws {
        let config = ResolvedAIConfig(config: AIConfig(), home: URL(fileURLWithPath: "/tmp"))
        let session = AIPreparedSession(profileSlot: 1, profileName: config.name, startedAt: Date(timeIntervalSince1970: 1000),
            config: config, token: "test", contextRoot: URL(fileURLWithPath: "/tmp"), contextMeetingID: UUID())
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(session)) as? [String: Any])
        for name in ["役割", String(repeating: "a", count: 64)] {
            json["name"] = name
            let restored = try AIJSON.decode(AIPreparedSession.self, from: JSONSerialization.data(withJSONObject: json))
            let saved = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(restored)) as? [String: Any])
            #expect(saved["name"] as? String == name)
        }
        for name in [String(repeating: "a", count: 65), String(repeating: "あ", count: 22), "複数\n行"] {
            json["name"] = name
            #expect(throws: AIError.self) { try AIJSON.decode(AIPreparedSession.self, from: JSONSerialization.data(withJSONObject: json)) }
        }
        json.removeValue(forKey: "name")
        #expect(try AIJSON.decode(AIPreparedSession.self, from: JSONSerialization.data(withJSONObject: json)) == session)
    }
}
