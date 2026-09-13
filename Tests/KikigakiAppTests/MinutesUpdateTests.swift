import AppKit
import Testing
@testable import Kikigaki

@Suite @MainActor struct MinutesUpdateTests {
    @Test func 相対時間は十秒単位から分時間日へ変わる() {
        let date = Date(timeIntervalSince1970: 1000)
        for (seconds, text) in [(0.0,"たった今"),(19,"10秒前"),(59,"50秒前"),(60,"1分前"),(3599,"59分前"),(3600,"1時間前"),(86400,"1日前"),(-60,"未来の更新時刻")] {
            #expect(MinutesUpdateStatus.relative(date, now: date.addingTimeInterval(seconds)) == text)
        }
    }
    @Test func 本文と一緒にmtimeを取得し読み直しても受信時刻にしない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("minutes.md"), date = Date(timeIntervalSince1970: 1000)
        try Data("本文".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate:date], ofItemAtPath:file.path)
        guard case .body(let text, _, let modifiedAt) = MinutesFileResult.read(file.path) else { Issue.record("本文を読めません"); return }
        #expect(text == "本文" && modifiedAt == date)
        let status = MinutesUpdateStatus(frame: .zero); status.setDate(modifiedAt)
        status.refresh(now: date.addingTimeInterval(35))
        #expect(status.label.stringValue.hasSuffix("30秒前"))
        status.setDate(nil); #expect(status.label.stringValue == "最終更新 —")
    }
    @Test func 更新表示は描画成功後に切り替わり非表示や失敗で残さない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("minutes.md")
        try Data("# 議事録\n\n変更前の本文".utf8).write(to: file)
        let preferences = MinutesTestDefaults()
        let view = MinutesPreviewView(frame: NSRect(x:0,y:0,width:700,height:500), defaults: preferences.value)
        let window = NSWindow(contentRect:view.frame, styleMask:[.titled], backing:.buffered, defer:false)
        window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
        defer { view.stop(); window.orderOut(nil) }
        view.update(path:file.path, source:.human, active:true)
        for _ in 0..<500 {
            if view.updateStatus.modifiedAt != nil { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        #expect(view.updateStatus.modifiedAt != nil)
        #expect(view.updateStatus.label.stringValue.contains("最終更新"))
        #expect(view.headerBar.frame.height == 56 && view.updateStatus.frame.height == 24)
        if let output = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] {
            let status = view.updateStatus
            let bitmap = try #require(status.bitmapImageRepForCachingDisplay(in:status.bounds))
            status.cacheDisplay(in:status.bounds, to:bitmap)
            let data = try #require(bitmap.representation(using:.png, properties:[:]))
            try data.write(to:URL(fileURLWithPath:output).appendingPathComponent("update-status.png"))
        }
        view.receive(.failure("読込失敗"))
        #expect(view.updateStatus.modifiedAt == nil)
        view.update(path:file.path, source:.human, active:false)
        #expect(!view.updateStatus.active && view.updateStatus.modifiedAt == nil)
    }
}
