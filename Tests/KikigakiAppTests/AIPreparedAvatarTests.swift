import AppKit
import Testing
@testable import Kikigaki

@Suite @MainActor struct AIPreparedAvatarTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    private func avatar(_ radio: NSButton?) -> NSImage? {
        guard let radio, radio.attributedTitle.length > 0 else { return nil }
        return (radio.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
    }

    @Test func 準備の選択と一覧と紐づけ候補に画像がある() throws {
        _ = NSApplication.shared
        let id = UUID()
        let sheet = AIPrepareSheet(profiles: [(1, "迅雷"), (2, "相談")], selected: 2)
        sheet.update(rows: [.init(id: id, label: "迅雷 · 議事録 · 13:05起動", reason: nil)], launching: false)
        let views = descendants(try #require(sheet.window.contentView))
        let popup = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
        #expect(popup.itemArray.allSatisfy { $0.image != nil })
        #expect(sheet.selectedSlot == 2)
        #expect(views.compactMap { $0 as? NSImageView }.count == 1)
        let attach = AIAttachSheet(choices: [.init(slot: 1, name: "迅雷", prepared: [(id, "議事録 · 13:05起動")])])
        let radios = descendants(try #require(attach.window.contentView)).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == id.uuidString }
        #expect(avatar(radios.first)?.size == NSSize(width: 20, height: 21))
        #expect(attach.selection[1] == id)
        sheet.update(rows: [
            .init(id: id, label: "使用可能", reason: nil),
            .init(id: UUID(), label: "使用不可", reason: "設定が変わったため使えません")
        ], launching: false)
        let avatars = descendants(try #require(sheet.window.contentView)).compactMap { $0 as? NSImageView }
        #expect(avatars.map(\.alphaValue) == [1, 0.45])
    }

    @Test func 非同期取得で選択と行を保ち失敗と省略は紫のイニシャルになる() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("avatar.tiff")
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        try #require(image.tiffRepresentation).write(to: source)
        let sources = [1: source.path, 2: root.appendingPathComponent("missing").path]
        let sheet = AIPrepareSheet(profiles: [(1, "迅雷"), (2, "相談"), (3, "相談役")], selected: 2, avatarSources: sources)
        let id = UUID()
        sheet.update(rows: [.init(id: id, label: "名前 · 議事録 · 13:05起動", reason: nil, name: "迅雷", avatar: source.path)], launching: false)
        let views = descendants(try #require(sheet.window.contentView))
        let popup = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
        let row = try #require(views.compactMap { $0 as? NSImageView }.first)
        let attach = AIAttachSheet(choices: [.init(slot: 1, name: "迅雷", prepared: [(id, "議事録")])], avatarSources: sources)
        let radio = try #require(descendants(attach.window.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id.uuidString })
        let before = popup.itemArray[0].image?.tiffRepresentation
        let radioBefore = avatar(radio)?.tiffRepresentation
        for _ in 0..<100 {
            if popup.itemArray[0].image?.tiffRepresentation != before && avatar(radio)?.tiffRepresentation != radioBefore { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popup.itemArray[0].image?.tiffRepresentation != before)
        #expect(avatar(radio)?.tiffRepresentation != radioBefore)
        #expect(row.image?.tiffRepresentation == popup.itemArray[0].image?.tiffRepresentation)
        #expect(popup.itemArray[1].image?.tiffRepresentation == popup.itemArray[2].image?.tiffRepresentation)
        #expect(sheet.selectedSlot == 2 && attach.selection[1] == id)
        #expect(descendants(sheet.window.contentView!).contains { $0 === row })
    }

    @Test func アバターあり取得失敗省略の準備画面を撮る() async throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"],
              let avatar = ProcessInfo.processInfo.environment["KIKIGAKI_UI_AVATAR"] else { return }
        _ = NSApplication.shared
        func capture(_ name: String, _ window: NSWindow) throws {
            let view = try #require(window.contentView?.superview)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        let sources = [1: avatar, 2: "/missing/avatar.png"]
        let profiles = [(slot: 1, name: "迅雷"), (slot: 2, name: "相談"), (slot: 3, name: "確認")]
        let sheet = AIPrepareSheet(profiles: profiles, selected: 1, avatarSources: sources)
        sheet.update(rows: profiles.map { p in
            .init(id: UUID(), label: "\(p.name) · 議事録 · 13:05起動", reason: nil, name: p.name, avatar: sources[p.slot])
        }, launching: false)
        let attach = AIAttachSheet(choices: profiles.map { p in
            .init(slot: p.slot, name: p.name, prepared: [(UUID(), "議事録 · 13:05起動")])
        }, avatarSources: sources)
        let popup = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? NSPopUpButton }.first)
        let firstRadio = try #require(descendants(attach.window.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier != nil })
        let initial = popup.itemArray[0].image?.tiffRepresentation
        let initialRadio = self.avatar(firstRadio)?.tiffRepresentation
        for _ in 0..<200 {
            if popup.itemArray[0].image?.tiffRepresentation != initial && self.avatar(firstRadio)?.tiffRepresentation != initialRadio { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popup.itemArray[0].image?.tiffRepresentation != initial)
        #expect(self.avatar(firstRadio)?.tiffRepresentation != initialRadio)
        for window in [sheet.window, attach.window] {
            window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        }
        defer { sheet.close(); attach.close() }
        try capture("prepare-avatars", sheet.window)
        try capture("attach-avatars", attach.window)
        let menu = try #require(popup.menu)
        var captured = false
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated {
                defer { menu.cancelTracking() }
                for window in NSApp.windows where String(describing: type(of: window)).contains("Menu") {
                    do { try capture("prepare-popup", window); captured = true }
                    catch { Issue.record(error) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .eventTracking)
        popup.performClick(nil); timer.invalidate()
        #expect(captured)
    }
}
