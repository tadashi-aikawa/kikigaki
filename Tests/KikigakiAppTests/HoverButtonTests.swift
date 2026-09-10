import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct HoverButtonTests {
    @Test func レイアウトではポインタの内外が変わったときだけ再描画する() throws {
        final class ObservedButton: HoverButton {
            var redrawRequests = 0
            override var needsDisplay: Bool {
                get { super.needsDisplay }
                set {
                    if newValue { redrawRequests += 1 }
                    super.needsDisplay = newValue
                }
            }
        }
        final class PointerWindow: NSWindow {
            var pointer = NSPoint(x: -100, y: -100)
            override var isKeyWindow: Bool { true }
            override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        }
        _ = NSApplication.shared
        let window = PointerWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        let button = ObservedButton(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
        try #require(window.contentView).addSubview(button)
        button.updateTrackingAreas()
        for inside in [false, true, true, false, false] {
            let wasInside = button.isHovered
            window.pointer = inside ? button.convert(NSPoint(x: 20, y: 15), to: nil) : NSPoint(x: -100, y: -100)
            // needsDisplayのgetterは親側の未描画領域も反映するため、要求回数を測る。
            button.redrawRequests = 0
            button.layout()
            #expect(button.isHovered == inside)
            #expect(button.redrawRequests == (wasInside != inside ? 1 : 0))
        }
    }

    @Test func 実際の発話行の名前とアバターはホバーでも背景を変えない() throws {
        final class PointerWindow: NSWindow {
            var pointer = NSPoint(x: -100, y: -100)
            override var isKeyWindow: Bool { true }
            override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        }
        final class PaperView: NSView {
            override func draw(_ dirtyRect: NSRect) { Washi.paper.setFill(); bounds.fill() }
        }
        _ = NSApplication.shared
        let window = PointerWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Washi.paper
        window.contentView = PaperView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let row = TranscriptRow()
        row.frame = NSRect(x: 12, y: 12, width: 576, height: 76)
        row.update(.init(speaker: 0, start: 30, end: 35, text: "会場は本社の大会議室にしましょう。"),
                   names: SpeakerNames(), timeline: .init(startedAt: Date(timeIntervalSince1970: 1_788_759_600)))
        row.updateAvatar(speakers: [], store: AvatarStore(), editable: true)
        let content = try #require(window.contentView)
        content.addSubview(row)
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        defer { window.orderOut(nil) }
        content.layoutSubtreeIfNeeded()
        let button = try #require(row.subviews.compactMap { $0 as? SpeakerButton }.first)
        func pixels(_ name: String) throws -> Data {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            if let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] {
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            }
            return data
        }
        button.updateTrackingAreas()
        let normal = try pixels("speaker-normal")
        window.pointer = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.updateTrackingAreas()
        #expect(button.isHovered && button.interactionCursor == .pointingHand)
        #expect(!button.drawsHoverBackground)
        #expect(try pixels("speaker-hover") == normal)
    }

    @Test func 可視矩形が自身より広い行でも再配置後に全行をホバーにしない() throws {
        // OSのマウス位置だけ固定し、本番NSViewの配置と可視矩形で判定する。
        final class PointerWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: 20, y: 20) }
        }
        _ = NSApplication.shared
        let window = PointerWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        var buttons: [HoverButton] = []
        for index in 0..<4 {
            let button = HoverButton(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
            button.isBordered = false
            content.addSubview(button)
            button.updateTrackingAreas()
            #expect(button.isHovered)
            // 現行AppKitの非クリップビューは親側の領域までvisibleRectを返す。
            // 再配置時に追跡を更新しても、boundsと交差しない旧判定は全行でtrueになる。
            button.setFrameOrigin(NSPoint(x: 0, y: 60 + index * 40))
            button.layout()
            button.updateTrackingAreas()
            print("FB26 window=\(button.window != nil), visible=\(button.visibleRect), localPointer=\(button.convert(window.mouseLocationOutsideOfEventStream, from: nil))")
            #expect(button.trackingAreas.allSatisfy { !$0.options.contains(.inVisibleRect) && button.bounds.contains($0.rect) })
            buttons.append(button)
        }
        print("FB26 relocated hovered=\(buttons.filter(\.isHovered).count)/\(buttons.count), pointer=(20,20), frames=\(buttons.map(\.frame))")
        #expect(buttons.allSatisfy { !$0.isHovered })
    }

    private func pixels(_ button: NSButton) throws -> Data {
        let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func 押せる各部品はホバーで変化し無効時は変化しない() throws {
        _ = NSApplication.shared
        let unread = AIStatusPill(); unread.update(.unread)
        let speaker = SpeakerButton(); speaker.title = ""; speaker.isBordered = false
        let action = WashiActionButton(title: "停止", target: nil, action: nil)
        action.isBordered = false; action.emphasis = .neutralOutline
        let buttons: [HoverButton] = [AIRobotButton(), AIFooterCount(kind: .unread), AIFooterCount(kind: .confirmation),
            AIFooterButton(symbol: "ellipsis", label: "その他"), AIFooterButton(symbol: "exclamationmark.triangle", label: "警告"),
            SpeakerCountButton(), speaker, unread, AIActionButton("返答する", action: {}),
            AIActionButton("取消", action: {}), action, HoverButton(title: "開く", target: nil, action: nil)]
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        for button in buttons {
            button.frame = NSRect(x: 0, y: 0, width: 90, height: 40)
            button.updateTrackingAreas()
            let normal = try pixels(button)
            button.mouseEntered(with: event)
            #expect(button.isHovered && button.interactionCursor == .pointingHand)
            if type(of: button) == HoverButton.self || button is SpeakerButton {
                #expect(!button.drawsHoverBackground)
                #expect(try pixels(button) == normal, "標準ベゼルと話者ボタンにホバー背景を描かない")
            } else {
                #expect(try pixels(button) != normal, "\(type(of: button))のホバーを描く")
            }
            button.mouseExited(with: event)
            #expect(!button.isHovered)
            button.isEnabled = false
            let disabled = try pixels(button)
            button.mouseEntered(with: event)
            #expect(!button.isHovered && button.interactionCursor == .arrow)
            #expect(try pixels(button) == disabled, "\(type(of: button))の無効時は変化しない")
        }
    }

    @Test func リサイズ後も可視範囲を追跡しカーソル矩形を登録し直す() throws {
        final class ObservedButton: HoverButton {
            var registered: [NSRect] = []
            override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
                registered.append(rect)
                super.addCursorRect(rect, cursor: cursor)
            }
        }
        _ = NSApplication.shared
        let button = ObservedButton(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        for width: CGFloat in [40, 90, 36] {
            button.setFrameSize(NSSize(width: width, height: 40))
            button.updateTrackingAreas(); button.resetCursorRects()
            #expect(button.trackingAreas.count == 1)
            #expect(button.trackingAreas.first?.options.contains([.cursorUpdate, .mouseEnteredAndExited]) == true)
            #expect(button.trackingAreas.first?.rect == button.bounds.intersection(button.visibleRect))
            #expect(button.registered.last?.width == width)
        }
        button.isEnabled = false; button.registered = []; button.resetCursorRects()
        #expect(button.registered.isEmpty)
        button.isEnabled = true; button.frame = .zero; button.resetCursorRects()
        #expect(button.registered.isEmpty)
    }
}
