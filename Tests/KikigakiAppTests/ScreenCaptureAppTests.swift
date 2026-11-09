import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
/// 画面の記録の保存と公開の境界。ストリームは開かず、観測した1枚を同じ経路へ渡す。
@Suite(.timeLimit(.minutes(1))) @MainActor struct ScreenCaptureAppTests {
    private let display = ScreenDisplay(id: 1, name: "EV3895", points: CGSize(width: 64, height: 36), menuBarFraction: 0)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(_ value: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return try #require(context.makeImage())
    }

    /// 符号化と公開はほかのキューとMainActorの後の番で進む。条件がそろうまで待つ。
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func recording(_ root: URL) -> (MeetingSession, URL) {
        let config = ResolvedConfig(config: KikigakiConfig(outputDir: root.path))
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in })
        let url = root.appendingPathComponent("meeting.md")
        session.setAudioTranscriptForTesting([Utterance(speaker: 0, start: 0, end: 1, text: "この図を見て")], meter: AudioLevelMeter(), url: url)
        return (session, url)
    }

    @Test func 最初の1枚を保存して画面の行として公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        #expect(session.snapshot.canCaptureScreenNow)
        recorder.observeForTesting(try image(0.2), label: "EV3895 · Keynote「提案資料」")
        await wait { !session.screenEntriesForTesting.isEmpty }
        let entry = try #require(session.screenEntriesForTesting.first)
        #expect(entry.text == "EV3895 · Keynote「提案資料」" && entry.speaker == nil)
        let path = try #require(entry.imagePaths.first)
        #expect(path.hasPrefix(ScreenCaptureFiles.directory(for: url).path + "/") && path.hasSuffix(".webp"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: ScreenCaptureFiles.directory(for: url).path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(session.snapshot.utterances.contains { $0.kind == .screen })
        await wait { recorder.pendingForTesting == 0 }
    }

    @Test func 無効にした後に届いた保存は公開せず画像を消す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        recorder.observeForTesting(try image(0.2), label: "EV3895")
        // 符号化と書き込みの後、MainActorでの公開より前に無効にする。MainActorを明け渡さずに書き込みを待つ。
        let captures = ScreenCaptureFiles.directory(for: url).path
        for _ in 0..<300 where (try? FileManager.default.contentsOfDirectory(atPath: captures).isEmpty) != false {
            Thread.sleep(forTimeInterval: 0.01)
        }
        recorder.invalidate()
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: ScreenCaptureFiles.directory(for: url).path)) == [])
        // 無効にした後は新しい保存を受け付けない。
        recorder.observeForTesting(try image(0.8), label: "EV3895")
        #expect(recorder.pendingForTesting == 0)
    }

    @Test func 受付済みの保存は停止を待ってから公開しそれ以上は受け付けない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        recorder.observeForTesting(try image(0.2), label: "EV3895")
        recorder.stopAccepting()
        // 停止の操作の後に届いたフレームは保存しない。
        recorder.observeForTesting(try image(0.8), label: "EV3895")
        await recorder.drain(timeout: .seconds(3))
        #expect(session.screenEntriesForTesting.count == 1)
        #expect(recorder.isInvalidated && recorder.pendingForTesting == 0)
    }

    @Test func 一時停止の間は撮らず再開の直後の1枚を最初の1枚として撮る() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        recorder.observeForTesting(try image(0.2), label: "前の画面")
        await wait { session.screenEntriesForTesting.count == 1 }
        recorder.pauseCapturing()
        recorder.observeForTesting(try image(0.8), label: "休憩中の画面")
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["前の画面"])
        _ = recorder.resumeCapturing()
        // 前の画面と同じでも、再開の直後の1枚は待たずに撮る。
        recorder.observeForTesting(try image(0.2), label: "再開後の画面")
        await wait { session.screenEntriesForTesting.count == 2 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["前の画面", "再開後の画面"])
    }

    @Test func 撮れなくなったら取得不能の行とヘッダーの1行を出し以後は撮らない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        recorder.reportUnavailableForTesting("「画面収録」の許可がありません")
        await wait { !session.screenEntriesForTesting.isEmpty }
        #expect(session.screenEntriesForTesting.map(\.screenEvent) == [.unavailable("「画面収録」の許可がありません")])
        #expect(session.snapshot.headerMessage.text.contains("画面を記録できません: 「画面収録」の許可がありません"))
        #expect(session.snapshot.headerMessage.isError)
        #expect(!session.snapshot.canCaptureScreenNow)
        // 知らせた時点で撮影は止まり、2度目は知らせない。
        recorder.observeForTesting(try image(0.2), label: "EV3895")
        recorder.reportUnavailableForTesting("別の理由")
        await wait { recorder.pendingForTesting == 0 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.screenEntriesForTesting.count == 1)
        // 再開しても撮影は戻らない。
        _ = recorder.resumeCapturing()
        recorder.observeForTesting(try image(0.2), label: "EV3895")
        #expect(recorder.pendingForTesting == 0)
    }

    @Test func 一時停止と再開の前の世代の失敗では撮影を止めない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let old = recorder.resumeCapturing()
        recorder.pauseCapturing()
        _ = recorder.resumeCapturing()
        recorder.reportUnavailableForTesting("画面の取得を始められません", epoch: old)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!recorder.isUnavailable && session.screenEntriesForTesting.isEmpty)
        recorder.observeForTesting(try image(0.2), label: "再開後の画面")
        await wait { session.screenEntriesForTesting.count == 1 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["再開後の画面"])
    }

    @Test func いま撮るは押した時点で受け付け停止のときに待たせる() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let request = try #require(recorder.beginCapture())
        #expect(recorder.pendingForTesting == 1)
        recorder.stopAccepting()
        #expect(recorder.beginCapture() == nil)
        // 停止のときは受付済みの「いま撮る」の公開を待つ。ストリームを開いていないので撮影は失敗し、
        // その経路でも受付を1回だけ終えるので、期限より前に抜ける。
        let started = ContinuousClock.now
        async let drained: Void = recorder.drain(timeout: .seconds(3))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.pendingForTesting == 1 && !recorder.isInvalidated)
        await recorder.capture(request)
        await drained
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(recorder.isInvalidated && recorder.pendingForTesting == 0 && session.screenEntriesForTesting.isEmpty)
        // 一時停止中は受け付けない。
        let paused = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        paused.pauseCapturing()
        #expect(paused.beginCapture() == nil)
    }

    @Test func 開始シートで選んだディスプレイを渡し前回の名前で選んでおく() throws {
        let displays = [display, ScreenDisplay(id: 2, name: "Built-in Retina Display", points: CGSize(width: 1800, height: 1169), menuBarFraction: 0.03)]
        let fresh = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(), screenDisplays: displays)
        #expect(fresh.options?.screenDisplay == nil)
        #expect(fresh.screenRadios.map(\.title) == ["撮らない", "EV3895", "Built-in Retina Display"])
        let remembered = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(),
                                    screenDisplays: displays, screenDisplayName: "Built-in Retina Display")
        #expect(remembered.options?.screenDisplay == displays[1])
        remembered.screenRadios[0].performClick(nil)
        #expect(remembered.options?.screenDisplay == nil)
        // つながっていないディスプレイを覚えていたら「撮らない」から始める。
        let missing = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(),
                                 screenDisplays: displays, screenDisplayName: "EV2780")
        #expect(missing.options?.screenDisplay == nil)
    }

    @Test func いま撮るは画面を撮る会議の録音中だけ出す() {
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        var snapshot = SessionSnapshot(state: .recording)
        controller.apply(snapshot)
        #expect(!controller.footerMenu().items.map(\.title).contains("いま撮る"))
        snapshot.canCaptureScreenNow = true
        controller.apply(snapshot)
        #expect(controller.footerMenu().items.map(\.title).contains("いま撮る"))
    }
}
}
