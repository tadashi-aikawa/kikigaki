import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIDestinationAvatarTests {
    @Test func 宛先の各行にアバターを表示する() throws {
        _ = NSApplication.shared
        let picker = AIDestinationPicker()
        picker.update(items: [
            .init(slot: 1, name: "迅雷"),
            .init(slot: 2, name: "相談")
        ], selected: 2)
        let popup = try #require(picker.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        #expect(popup.itemArray.allSatisfy { $0.image != nil })
        #expect(popup.indexOfSelectedItem == 1)
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

    @Test func 画像取得後も選択を保持し取得失敗はイニシャルを残す() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("avatar.tiff")
        let sourceImage = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        try #require(sourceImage.tiffRepresentation).write(to: source)
        let picker = AIDestinationPicker()
        picker.update(items: [
            .init(slot: 1, name: "迅雷", avatar: source.path),
            .init(slot: 2, name: "相談", avatar: root.appendingPathComponent("missing").path)
        ], selected: 2)
        let popup = try #require(picker.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        let initial = popup.itemArray[0].image
        for _ in 0..<100 {
            if popup.itemArray[0].image !== initial { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popup.itemArray[0].image !== initial)
        #expect(popup.itemArray[1].image != nil)
        #expect(popup.indexOfSelectedItem == 1)
    }
}
