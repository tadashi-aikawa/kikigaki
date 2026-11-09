import Foundation
import Testing
@testable import KikigakiCore

@Suite struct ScreenCaptureTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func 置き場は会議名のcapturesで同じ秒は番号を足す() {
        let markdown = URL(fileURLWithPath: "/tmp/会議/2026-11-09_2200.md")
        #expect(ScreenCaptureFiles.directory(for: markdown).path == "/tmp/会議/2026-11-09_2200.captures")
        let observed = Date(timeIntervalSince1970: 3_723.9)
        #expect(ScreenCaptureFiles.fileName(observedAt: observed, taken: { _ in false }, timeZone: utc) == "010203.webp")
        let taken: Set = ["010203.webp", "010203_2.webp"]
        #expect(ScreenCaptureFiles.fileName(observedAt: observed, taken: taken.contains, timeZone: utc) == "010203_3.webp")
    }

    @Test func 見出しはディスプレイ名とアプリ名と題から作る() {
        #expect(ScreenCaptureLabel.make(display: "EV3895", application: "Keynote", title: "提案資料") == "EV3895 · Keynote「提案資料」")
        #expect(ScreenCaptureLabel.make(display: "EV3895", application: "Google Chrome", title: "") == "EV3895 · Google Chrome")
        #expect(ScreenCaptureLabel.make(display: "EV3895", application: nil, title: "無視") == "EV3895")
        #expect(ScreenCaptureLabel.make(display: "", application: nil, title: nil) == "画面")
        #expect(ScreenCaptureLabel.make(display: "EV3895", application: "Ghostty", title: "改\n行") == "EV3895 · Ghostty「改 行」")
    }

    @Test func 保存の失敗は3回続いたら出し次の成功で消す() {
        var health = ScreenCaptureHealth()
        health.failed("ディスクがいっぱいです"); health.failed("ディスクがいっぱいです")
        #expect(health.warning == nil)
        health.failed("ディスクがいっぱいです")
        #expect(health.warning == "画面を記録できません: ディスクがいっぱいです")
        health.saved()
        #expect(health.warning == nil)
    }

    @Test func 撮れなくなった理由は保存の成功で消さない() {
        var health = ScreenCaptureHealth()
        health.becameUnavailable("「画面収録」の許可がありません")
        health.saved()
        #expect(health.warning == "画面を記録できません: 「画面収録」の許可がありません")
    }

    @Test func 観測した瞬間の音声位置は受け付けた位置から経過を引く() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(ScreenCaptureClock.audioTime(acceptedAudioTime: 60, now: now, observedAt: now.addingTimeInterval(-0.25)) == 59.75)
        // 観測が受け付けより後に見えても、受け付けた位置より後ろにしない。0より前にもしない。
        #expect(ScreenCaptureClock.audioTime(acceptedAudioTime: 60, now: now, observedAt: now.addingTimeInterval(1)) == 60)
        #expect(ScreenCaptureClock.audioTime(acceptedAudioTime: 1, now: now, observedAt: now.addingTimeInterval(-5)) == 0)
    }
}
