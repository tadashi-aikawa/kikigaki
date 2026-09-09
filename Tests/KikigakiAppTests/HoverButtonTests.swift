import AppKit
import Testing
@testable import Kikigaki

@Suite @MainActor struct HoverButtonTests {
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
            if type(of: button) == HoverButton.self {
                #expect(!button.drawsHoverBackground)
                #expect(try pixels(button) == normal, "標準ベゼルの外へホバー背景を描かない")
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
            #expect(button.trackingAreas.first?.options.contains([.inVisibleRect, .cursorUpdate, .mouseEnteredAndExited]) == true)
            #expect(button.registered.last?.width == width)
        }
        button.isEnabled = false; button.registered = []; button.resetCursorRects()
        #expect(button.registered.isEmpty)
        button.isEnabled = true; button.frame = .zero; button.resetCursorRects()
        #expect(button.registered.isEmpty)
    }
}
