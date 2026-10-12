import Foundation
import WebKit
import Testing
@testable import Kikigaki

private final class RenderingFeature: NSObject {
    @objc let key: String
    init(_ key: String) { self.key = key }
}
private class RenderingPreferences: NSObject {
    var enabled = true
    var writes = 0
    @objc class func _features() -> [NSObject] { [RenderingFeature(MinutesRenderingPreferences.near60FPSKey)] }
    @objc(_isEnabledForFeature:) func isEnabled(_ feature: NSObject) -> Bool { enabled }
    @objc(_setEnabled:forFeature:) func setEnabled(_ value: Bool, feature: NSObject) {
        enabled = value; writes += 1
    }
}
private final class MissingRenderingFeature: RenderingPreferences {
    override class func _features() -> [NSObject] { [RenderingFeature("RenamedFeature"), NSObject()] }
}
private final class WrongRenderingKey: NSObject {
    @objc var key: Int { 42 }
}
private final class ChangedRenderingFeature: RenderingPreferences {
    override class func _features() -> [NSObject] { [WrongRenderingKey()] }
}
private final class ChangedRenderingAPI: NSObject {
    @objc class func _features() -> Int { 42 }
}
private final class ChangedRenderingSetter: NSObject {
    var writes = 0
    @objc(_isEnabledForFeature:) func isEnabled(_ feature: NSObject) -> Bool { true }
    @objc(_setEnabled:forFeature:) func setEnabled(_ value: Int, feature: NSObject) { writes += 1 }
}

extension AppKitTests {
@Suite @MainActor struct MinutesRenderingPreferencesTests {
    @Test func 設定があれば60Hz優先だけを外す() {
        let preferences = RenderingPreferences()
        #expect(MinutesRenderingPreferences.setNear60FPS(false, on: preferences, featuresClass: RenderingPreferences.self) == false)
        #expect(!preferences.enabled && preferences.writes == 1)
    }
    @Test func 設定やAPIやキー取得がなければ何もしない() {
        for provider: AnyClass in [NSObject.self, MissingRenderingFeature.self, ChangedRenderingFeature.self, ChangedRenderingAPI.self] {
            let preferences = RenderingPreferences()
            #expect(MinutesRenderingPreferences.setNear60FPS(false, on: preferences, featuresClass: provider) == nil)
            #expect(preferences.enabled && preferences.writes == 0)
        }
        #expect(MinutesRenderingPreferences.setNear60FPS(false, on: NSObject(), featuresClass: RenderingPreferences.self) == nil)
        let changed = ChangedRenderingSetter()
        #expect(MinutesRenderingPreferences.setNear60FPS(false, on: changed, featuresClass: RenderingPreferences.self) == nil)
        #expect(changed.writes == 0)
    }
    @Test func 実WebKitの設定がある環境では議事録とボードだけへ適用する() throws {
        let supported = MinutesRenderingPreferences.setNear60FPS(true, on: WKPreferences())
        guard supported != nil else { return }
        let other = WKPreferences()
        let before = MinutesRenderingPreferences.near60FPS(on: other)
        for board in [false, true] {
            let document = MinutesWebView(frame: .zero)
            document.boardCanvasEnabled = board
            defer { document.invalidate() }
            let preferences = document.webView.configuration.preferences
            #expect(MinutesRenderingPreferences.near60FPS(on: preferences) == false)
        }
        #expect(MinutesRenderingPreferences.near60FPS(on: other) == before)
    }
}
}
