import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIDestinationAvatarTests {
    @Test func 宛先と字下げした準備済みに同じアバターを表示する() throws {
        _ = NSApplication.shared
        let picker = AIDestinationPicker()
        picker.update(items: [
            .init(slot: 1, name: "迅雷", prepared: [.init(id: UUID(), label: "議事録")]),
            .init(slot: 2, name: "相談")
        ], selected: 2)
        let popup = try #require(picker.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        #expect(popup.itemArray.allSatisfy { $0.image != nil })
        #expect(popup.itemArray[0].image === popup.itemArray[1].image)
        #expect(popup.itemArray[1].indentationLevel == 1)
        #expect(popup.indexOfSelectedItem == 2)
    }

    @Test func 会議の固定プロファイルから宛先へ画像パスを渡す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [ai]
        avatar = "/tmp/avatar.png"
        """), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        #expect(session.aiDestinationItems.first?.avatar == "/tmp/avatar.png")
    }

    @Test func 画像取得後も選択と字下げを保持し取得失敗はイニシャルを残す() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("avatar.tiff")
        let sourceImage = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        try #require(sourceImage.tiffRepresentation).write(to: source)
        let picker = AIDestinationPicker()
        picker.update(items: [
            .init(slot: 1, name: "迅雷", prepared: [.init(id: UUID(), label: "議事録")], avatar: source.path),
            .init(slot: 2, name: "相談", avatar: root.appendingPathComponent("missing").path)
        ], selected: 2)
        let popup = try #require(picker.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        let initial = popup.itemArray[0].image
        for _ in 0..<100 {
            if popup.itemArray[0].image !== initial { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popup.itemArray[0].image !== initial)
        #expect(popup.itemArray[0].image === popup.itemArray[1].image)
        #expect(popup.itemArray[2].image != nil)
        #expect(popup.itemArray[1].indentationLevel == 1 && popup.indexOfSelectedItem == 2)
    }
}
