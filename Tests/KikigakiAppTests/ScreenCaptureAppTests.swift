import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

/// 判定器へ渡す今の時刻を、検証が進める時計。観測の時刻と保存の結果の時刻を同じ時計にそろえる。
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func set(_ value: Date) { lock.withLock { date = value } }
}

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
    /// 期限の約2秒を超えたらテストの失敗にする。成立しない条件を黙って待ち越さない。
    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "待ちの期限を超えた", sourceLocation: sourceLocation)
    }

    /// 0.1は −20 dBFS で、小音量の除外のしきい値 −45 dBFS を超える。0は無音。
    private func audio(seconds: Double, voiced: Bool) -> [Float] {
        Array(repeating: voiced ? 0.1 : 0, count: Int(seconds * 16000))
    }

    /// 4秒の音声を受け付けた録音中の会議。既定は話している間で、自動の画面を保留せずに公開する。
    /// - seconds: 受け付けておく音声の長さ。0なら画面の行は0秒の位置になる
    /// - removeScreenFile: 公開しなかった画像の削除。失敗を差し込む検証で渡す
    private func recording(_ root: URL, voiced: Bool = true, seconds: Double = 4, log: @escaping (String) -> Void = { _ in },
                           removeScreenFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) })
        -> (MeetingSession, URL) {
        let config = ResolvedConfig(config: KikigakiConfig(outputDir: root.path))
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: log, removeScreenFile: removeScreenFile)
        let url = root.appendingPathComponent("meeting.md")
        session.setAudioTranscriptForTesting([Utterance(speaker: 0, start: 0, end: 1, text: "この図を見て")], meter: AudioLevelMeter(), url: url)
        session.acceptAudioForTesting(audio(seconds: seconds, voiced: voiced))
        return (session, url)
    }

    /// 判定器に画面を保存させる。最初の1枚の後は落ち着きを待つので、同じ画面を2秒あけて2回観測する。
    /// 観測の時刻は先の時刻にし、音声位置は受け付けた位置に置く。
    /// - pending: 待ち終える受付済みの保存の数。未完了の「いま撮る」を残したまま呼ぶときは、その数を渡す
    /// - clock: 渡すと、判定器へ渡す今の時刻を2回目の観測の時刻に進める。保存の結果と観測を同じ時計にそろえる
    private func show(_ recorder: ScreenRecorder, _ value: CGFloat, label: String, at offset: Double, from base: Date,
                      pending: Int = 0, clock: TestClock? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        clock?.set(base.addingTimeInterval(offset + 2))
        recorder.observeForTesting(try image(value), observedAt: base.addingTimeInterval(offset), label: label)
        recorder.observeForTesting(try image(value), observedAt: base.addingTimeInterval(offset + 2), label: label)
        await wait({ recorder.pendingForTesting == pending }, sourceLocation: sourceLocation)
    }

    private func captures(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: ScreenCaptureFiles.directory(for: url).path)) ?? []
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
        #expect((try? FileManager.default.contentsOfDirectory(atPath: captures).count) == 1, "書き込みの待ちの期限を超えた")
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

    @Test func 一時停止の間は撮らず_再開の直後は前の画面と違えば待たずに撮る() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        recorder.observeForTesting(try image(0.2), label: "前の画面")
        await wait { session.screenEntriesForTesting.count == 1 }
        recorder.pauseCapturing()
        recorder.observeForTesting(try image(0.8), label: "休憩中の画面")
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["前の画面"])
        // 前の画面と同じなら、再開の直後でも撮らない。比較の基準は一時停止をまたいで引き継ぐ。
        _ = recorder.resumeCapturing()
        recorder.observeForTesting(try image(0.2), label: "再開後の同じ画面")
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["前の画面"])
        recorder.pauseCapturing()
        _ = recorder.resumeCapturing()
        recorder.observeForTesting(try image(0.8), label: "再開後の画面")
        await wait { session.screenEntriesForTesting.count == 2 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["前の画面", "再開後の画面"])
    }

    @Test func 無音の間は最後の1枚だけを保留し_話し始めに公開して置き換えた画像は消す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        try await show(recorder, 0.2, label: "探している画面", at: 0, from: base)
        #expect(session.heldScreenCountForTesting == 1 && session.screenEntriesForTesting.isEmpty && captures(url).count == 1)
        // 黙ったまま画面を替える。前の1枚は公開せずに画像ごと捨てる。
        session.acceptAudioForTesting(audio(seconds: 2, voiced: false))
        try await show(recorder, 0.8, label: "見つけた画面", at: 10, from: base)
        #expect(session.heldScreenCountForTesting == 1 && session.screenEntriesForTesting.isEmpty && captures(url).count == 1)
        // 話し始めに、保留していた最後の1枚を観測した位置のまま公開する。
        session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true))
        #expect(session.heldScreenCountForTesting == 0)
        let held = try #require(session.screenEntriesForTesting.first)
        #expect(session.screenEntriesForTesting.count == 1 && held.text == "見つけた画面" && abs(held.start - 6) < 0.05)
        let path = try #require(held.imagePaths.first)
        #expect(captures(url).count == 1 && FileManager.default.fileExists(atPath: path))
        #expect(session.snapshot.utterances.contains { $0.kind == .screen })
        // 話している間の画面は保留せずに公開する。
        try await show(recorder, 0.2, label: "話しながら見せる画面", at: 20, from: base)
        #expect(session.screenEntriesForTesting.map(\.text) == ["見つけた画面", "話しながら見せる画面"])
    }

    /// 判定器は、公開した画面だけを直近の画面として比べる。保留は公開を受付の番号で知らせてから比べる。
    /// 仕様は docs/screen-capture.md の「直近に公開した画面」
    /// 観測・判定・保存の結果を同じ時計にそろえ、同じ観測の列で、保留したCを公開した場合と捨てた場合を比べる。
    /// - 公開した: 4秒後にCへ戻っても撮らない
    /// - 捨てた: Cへ戻ったら撮る
    @Test(arguments: [true, false])
    func 保留から公開した画面へ戻っても撮らず_保留のまま捨てた画面へ戻れば撮る(publishHeld: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date(), clock = TestClock(base)
        recorder.setClockForTesting { clock.now }
        // 無音の中のCを保留する。
        try await show(recorder, 0.5, label: "C", at: 0, from: base, clock: clock)
        #expect(session.heldScreenCountForTesting == 1)
        // 公開する場合は話し始めてからDへ替える。Dは話している間の画面なのでその場で公開する。
        // 捨てる場合は黙ったままDへ替え、DでCを置き換えて捨てる。
        if publishHeld { session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true)) }
        try await show(recorder, 0.65, label: "D", at: 4, from: base, clock: clock)
        #expect(session.screenEntriesForTesting.map(\.text) == (publishHeld ? ["C", "D"] : []))
        // Cを最後に見てから4秒でCへ戻る。どちらの場合も、Cはまだ12秒の範囲にある。
        try await show(recorder, 0.5, label: "Cへ戻る", at: 8, from: base, clock: clock)
        #expect(recorder.detectorForTesting.recentScreenCount.held == (publishHeld ? 0 : 1))
        session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true))
        #expect(session.screenEntriesForTesting.map(\.text) == (publishHeld ? ["C", "D"] : ["Cへ戻る"]))
    }

    /// 自動の保存Aを受け付けた後、後から受け付けた「いま撮る」Bが先に公開される。無音の中のAは届いた時点で捨てる。
    /// Aの行き先は保存の結果と一緒に「捨てた」として判定器へ返す。直近の画面に登録せず、Aが動き続けて撮った1枚でも外すマスを確定しない。
    @Test func いま撮るより後に届いて捨てた自動の画面は_直近の画面にも外すマスにも入れない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date(), clock = TestClock(base)
        recorder.setClockForTesting { clock.now }
        recorder.observeForTesting(try image(0.1), observedAt: base, label: "最初の画面")
        await wait { recorder.pendingForTesting == 0 }
        // 画面が毎秒変わり続ける。12秒たったら、動き続けて撮るAを決める。Aは符号化へ渡さずに持つ。
        // 観測の時刻は実時計との差で単調な秒へ写すので、ちょうど12秒は誤差で届かないことがある。1秒長く観測する。
        recorder.deferAutomaticSavesForTesting()
        for second in 1...14 {
            clock.set(base.addingTimeInterval(Double(second)))
            recorder.observeForTesting(try image(second % 2 == 0 ? 0.3 : 0.7), observedAt: base.addingTimeInterval(Double(second)), label: "動き続ける画面")
        }
        #expect(recorder.pendingForTesting == 1)
        // 後から受け付けた「いま撮る」Bを先に公開する。
        let request = try #require(recorder.beginCapture())
        recorder.deliverCapturedForTesting(request, image: try image(0.9))
        await wait { recorder.pendingForTesting == 1 }
        #expect(session.screenEntriesForTesting.map(\.text) == [request.label])
        // Aが届く。Bより前に受け付けた無音の中の画面なので、その場で捨てる。
        recorder.releaseAutomaticSavesForTesting()
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.heldScreenCountForTesting == 0 && session.screenEntriesForTesting.map(\.text) == [request.label] && captures(url).count == 1)
        let detector = recorder.detectorForTesting
        #expect(detector.recentScreenCount.held == 0)
        #expect(detector.excludedCellCount == 0)
    }

    @Test func 音量が観測位置まで届く前は無音と決めない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        // 話し始めた1秒を受け付けたが、消費が遅れて音量はまだ足されていない。その位置で1枚撮る。
        let voiced = audio(seconds: 1, voiced: true)
        session.acceptAudioForTesting(voiced, measured: false)
        try await show(recorder, 0.2, label: "話し始めの直後の画面", at: 0, from: base)
        session.acceptAudioForTesting(audio(seconds: 4, voiced: false), measured: false)
        try await show(recorder, 0.8, label: "黙った後の画面", at: 10, from: base)
        #expect(session.screenEntriesForTesting.isEmpty)
        // 音量が追いつくと、話し始めの直後の画面は話している間の1枚として公開し、黙った後の1枚だけを保留する。
        // 届く前に無音と決めると、前の1枚を後の1枚で置き換えて捨ててしまう。
        session.measureAudioForTesting(voiced)
        session.measureAudioForTesting(audio(seconds: 4, voiced: false))
        #expect(session.screenEntriesForTesting.map(\.text) == ["話し始めの直後の画面"])
        #expect(session.heldScreenCountForTesting == 1 && captures(url).count == 2)
    }

    @Test func 会話をコピーする前に保留を公開し_コピーした会話に今の画面が入る() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        try await show(recorder, 0.2, label: "EV3895 · Keynote「提案資料」", at: 0, from: Date())
        #expect(session.heldScreenCountForTesting == 1)
        var copied: [String] = []
        session.copyContext(writeClipboard: { copied.append($0); return true })
        #expect(session.heldScreenCountForTesting == 0 && session.screenEntriesForTesting.count == 1)
        let prompt = try #require(copied.first)
        let tail = try #require(prompt.components(separatedBy: "```json\n").last)
        let fenced = try #require(tail.components(separatedBy: "\n```").first)
        let metadata = try #require(try JSONSerialization.jsonObject(with: Data(fenced.utf8)) as? [String: Any])
        let transcriptPath = try #require(metadata["transcript_path"] as? String)
        let transcript = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        #expect(transcript.contains("画面: EV3895 · Keynote「提案資料」"))
    }

    @Test func 一時停止の直前に保留を公開し_再開の直後に同じ画面を重ねない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        try await show(recorder, 0.2, label: "一時停止の前の画面", at: 0, from: Date())
        #expect(session.heldScreenCountForTesting == 1)
        session.togglePause()
        #expect(session.snapshot.state == .paused && session.heldScreenCountForTesting == 0)
        #expect(session.screenEntriesForTesting.map(\.text) == ["一時停止の前の画面"])
        // 再開の直後の1枚。ストリームは開かずに撮影だけを戻す。前の画面と同じなので撮らない。
        _ = recorder.resumeCapturing()
        recorder.observeForTesting(try image(0.2), label: "再開の直後の画面")
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.count == 1 && session.heldScreenCountForTesting == 0 && captures(url).count == 1)
    }

    @Test func 撮れなくなったら取得不能の行より前に保留を公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        try await show(recorder, 0.2, label: "最後の画面", at: 0, from: Date())
        recorder.reportUnavailableForTesting("画面を取得できなくなりました")
        await wait { session.screenEntriesForTesting.count == 2 }
        #expect(session.screenEntriesForTesting.map(\.screenEvent) == [nil, .unavailable("画面を取得できなくなりました")])
        #expect(session.heldScreenCountForTesting == 0)
    }

    @Test func 停止の待ちの中で保留を公開し_最終保存に入れる() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        try await show(recorder, 0.2, label: "停止の直前の画面", at: 0, from: Date())
        #expect(session.heldScreenCountForTesting == 1)
        await session.stop()
        #expect(session.snapshot.state == .idle && session.heldScreenCountForTesting == 0)
        #expect(session.snapshot.utterances.contains { $0.kind == .screen && $0.text == "停止の直前の画面" })
        let markdown = try String(contentsOf: url, encoding: .utf8)
        #expect(markdown.contains("画面: 停止の直前の画面"))
        #expect(captures(url).count == 1)
    }

    @Test func 一時停止の前に受け付けた保存が一時停止の後に届いても公開し_再開後の保留で消さない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        // 無音の中の画面Aの保存を受け付けた直後、MainActorを明け渡す前に一時停止する。操作の時点では保留は空。
        recorder.observeForTesting(try image(0.2), label: "一時停止の前の画面")
        #expect(recorder.pendingForTesting == 1)
        session.togglePause()
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["一時停止の前の画面"] && session.heldScreenCountForTesting == 0)
        // 無音のまま再開して別の画面Bを撮る。Bは保留になり、公開したAを置き換えない。
        _ = recorder.resumeCapturing()
        try await show(recorder, 0.8, label: "再開後の画面", at: 10, from: Date())
        #expect(session.heldScreenCountForTesting == 1 && session.screenEntriesForTesting.count == 1)
        let path = try #require(session.screenEntriesForTesting.first?.imagePaths.first)
        #expect(FileManager.default.fileExists(atPath: path) && captures(url).count == 2)
    }

    @Test func 取得不能より前に受け付けた保存が後から届いても公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        recorder.observeForTesting(try image(0.2), label: "最後の画面")
        recorder.reportUnavailableForTesting("画面を取得できなくなりました")
        await wait { recorder.pendingForTesting == 0 && session.screenEntriesForTesting.count == 2 }
        #expect(session.screenEntriesForTesting.contains { $0.text == "最後の画面" && $0.screenEvent == nil })
        #expect(session.screenEntriesForTesting.contains { $0.screenEvent == .unavailable("画面を取得できなくなりました") })
        #expect(session.heldScreenCountForTesting == 0 && captures(url).count == 1)
    }

    @Test func 話し始めがまだ届いていない保存を追い越しても_無音の区間から1枚だけ公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        try await show(recorder, 0.2, label: "探している画面", at: 0, from: base)
        #expect(session.heldScreenCountForTesting == 1)
        // 無音の中で次の画面Bの保存を受け付け、届く前に声が届く。
        recorder.observeForTesting(try image(0.8), observedAt: base.addingTimeInterval(10), label: "見つけた画面")
        recorder.observeForTesting(try image(0.8), observedAt: base.addingTimeInterval(12), label: "見つけた画面")
        #expect(recorder.pendingForTesting == 1)
        session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true))
        #expect(session.screenEntriesForTesting.isEmpty)
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["見つけた画面"])
        #expect(session.heldScreenCountForTesting == 0 && captures(url).count == 1)
    }

    @Test func いま撮るの完了が遅れても_押した後に受け取った保留は残す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let request = try #require(recorder.beginCapture())
        // 手動の撮影が終わる前に、自動の画面を受け取って保留する。手動の1件は未完了のまま残る。
        try await show(recorder, 0.2, label: "押した後の画面", at: 0, from: Date(), pending: 1)
        #expect(session.heldScreenCountForTesting == 1)
        recorder.deliverCapturedForTesting(request, image: try image(0.5))
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.map(\.text) == [request.label])
        #expect(session.heldScreenCountForTesting == 1 && captures(url).count == 2)
    }

    @Test func いま撮るで捨てた保留の画面へ戻って話すと_その画面を記録する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        try await show(recorder, 0.2, label: "画面A", at: 0, from: base)
        #expect(session.heldScreenCountForTesting == 1)
        // 別の画面Bを手動で撮る。押す前の保留Aは捨て、比較の基準はBにする。
        let request = try #require(recorder.beginCapture())
        recorder.deliverCapturedForTesting(request, image: try image(0.8))
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.heldScreenCountForTesting == 0 && session.screenEntriesForTesting.count == 1 && captures(url).count == 1)
        // Aへ戻る。Bと違うので撮り、無音なので保留し、話し始めに公開する。
        try await show(recorder, 0.2, label: "画面A", at: 10, from: base)
        #expect(session.heldScreenCountForTesting == 1)
        session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true))
        #expect(session.screenEntriesForTesting.map(\.text) == [request.label, "画面A"])
    }

    @Test func 保存中の自動の画面の後に受け付けたいま撮るで_その画面を捨てて基準をそろえる() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        // 自動の画面Aを受け付け、届く前に「いま撮る」を受け付ける。受付の番号はA、手動の順。
        recorder.observeForTesting(try image(0.2), observedAt: base, label: "画面A")
        let request = try #require(recorder.beginCapture())
        await wait { recorder.pendingForTesting == 1 }
        #expect(session.heldScreenCountForTesting == 1)
        // 手動の画像Bが完成すると、それより前に受け付けたAを捨て、比較の基準をBにする。
        recorder.deliverCapturedForTesting(request, image: try image(0.8))
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.heldScreenCountForTesting == 0 && session.screenEntriesForTesting.map(\.text) == [request.label])
        #expect(captures(url).count == 1)
        // Aへ戻ると、Bと違うので撮る。捨てたAが基準に残っていれば「変化なし」になる。
        try await show(recorder, 0.2, label: "画面A", at: 10, from: base)
        #expect(session.heldScreenCountForTesting == 1)
        session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true))
        #expect(session.screenEntriesForTesting.map(\.text) == [request.label, "画面A"])
    }

    @Test func 同じ境界に属する遅れた画面は_届いた順ではなく受付の順に置く() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        // 手動のMを受け付け、その後に自動のAを受け付ける。どちらも届く前に一時停止の境界を引き、手入力を足す。
        let request = try #require(recorder.beginCapture())
        // 観測の時刻を先に置き、音声位置を受け付けた位置にそろえる。
        recorder.observeForTesting(try image(0.2), observedAt: Date().addingTimeInterval(1), label: "自動の画面")
        session.togglePause()
        #expect(session.submitTyped("手入力の行"))
        // A → Mの順に届ける。音声位置はどれも4秒。
        await wait { recorder.pendingForTesting == 1 }
        recorder.deliverCapturedForTesting(request, image: try image(0.8))
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.entriesForTesting.map(\.text) == [request.label, "自動の画面", "手入力の行"])
        #expect(Set(session.entriesForTesting.map(\.start)).count == 1)
        #expect(captures(url).count == 2)
    }

    @Test func 受け入れた限界_話し始めが落ち着き待ちを追い越すと同じ無音の区間から2枚公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        try await show(recorder, 0.2, label: "画面A", at: 0, from: base)
        #expect(session.heldScreenCountForTesting == 1)
        // 無音の中でBを観測し、落ち着き待ちの途中で話し始める。Bはまだ保存を決めていないので、話し始めの待ちに入らない。
        recorder.observeForTesting(try image(0.8), observedAt: base.addingTimeInterval(10), label: "画面B")
        #expect(recorder.pendingForTesting == 0)
        session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true))
        #expect(session.screenEntriesForTesting.map(\.text) == ["画面A"])
        // 落ち着いてBの保存が決まる。Bは話し始めの後に公開され、同じ無音の区間から2枚になる。誤る向きは残しすぎる側。
        recorder.tickForTesting(at: base.addingTimeInterval(12))
        await wait { recorder.pendingForTesting == 0 && session.screenEntriesForTesting.count == 2 }
        #expect(session.screenEntriesForTesting.map(\.text) == ["画面A", "画面B"])
        #expect(session.heldScreenCountForTesting == 0 && captures(url).count == 2)
    }

    @Test func 境界で公開した画面より前に受け付けたいま撮るは_後から届いても前に置く() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        // 手動のMを受け付け、次に自動のAを受け付けて保留まで終える。音声位置はどれも4秒。
        let request = try #require(recorder.beginCapture())
        recorder.observeForTesting(try image(0.2), observedAt: Date().addingTimeInterval(1), label: "自動の画面")
        await wait { recorder.pendingForTesting == 1 }
        #expect(session.heldScreenCountForTesting == 1)
        // 一時停止でAを公開した後に、Mが届く。受付の順はM → A。
        session.togglePause()
        #expect(session.screenEntriesForTesting.map(\.text) == ["自動の画面"])
        recorder.deliverCapturedForTesting(request, image: try image(0.8))
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.entriesForTesting.map(\.text) == [request.label, "自動の画面"])
        #expect(Set(session.entriesForTesting.map(\.start)).count == 1 && captures(url).count == 2)
    }

    @Test func いま撮るで撮った画面のままなら_自動でもう1枚撮らない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        try await show(recorder, 0.2, label: "画面A", at: 0, from: base)
        let request = try #require(recorder.beginCapture())
        recorder.deliverCapturedForTesting(request, image: try image(0.8))
        await wait { recorder.pendingForTesting == 0 }
        try await show(recorder, 0.8, label: "画面B", at: 10, from: base)
        #expect(session.screenEntriesForTesting.map(\.text) == ["画面A", request.label])
    }

    @Test func 公開しなかった画像を消せなければ片付けで消し直し_公開した画像は消さない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var logs: [String] = []
        var failing = true
        let (session, url) = recording(root, voiced: false, log: { logs.append($0) }, removeScreenFile: { url in
            if failing { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        let base = Date()
        try await show(recorder, 0.2, label: "置き換わる画面", at: 0, from: base)
        try await show(recorder, 0.8, label: "最後の画面", at: 10, from: base)
        // 置き換えで捨てた画像を消せなかった。画像は残り、ログに出る。
        #expect(session.heldScreenCountForTesting == 1 && captures(url).count == 2)
        #expect(logs.contains { $0.contains("公開しなかった画面の画像を消せません") })
        session.acceptAudioForTesting(audio(seconds: 0.5, voiced: true))
        let published = try #require(session.screenEntriesForTesting.first?.imagePaths.first)
        // 停止の片付けで消し直す。公開した画像は残す。
        failing = false
        await session.stop()
        #expect(captures(url) == [URL(fileURLWithPath: published).lastPathComponent])
    }

    @Test func 無効にした後に届いて公開を拒んだ画像も_消せなければ片付けで消し直す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var logs: [String] = []
        var failing = true
        let (session, url) = recording(root, log: { logs.append($0) }, removeScreenFile: { url in
            if failing { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        recorder.observeForTesting(try image(0.2), label: "停止の期限を超えた画面")
        // 書き込みの後、MainActorでの公開より前に無効にする。停止の期限の超過と会議の切替が同じ経路を通る。
        for _ in 0..<300 where captures(url).isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        #expect(captures(url).count == 1, "書き込みの待ちの期限を超えた")
        recorder.invalidate()
        await wait { recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.isEmpty && captures(url).count == 1)
        #expect(logs.contains { $0.contains("公開しなかった画面の画像を消せません") })
        // 次の会議の準備の片付けで消し直す。古い会議の保存先のパスのまま消す。
        failing = false
        _ = session.installScreenRecorderForTesting(display: display, markdownURL: root.appendingPathComponent("next.md"))
        #expect(captures(url).isEmpty)
    }

    @Test func 取得不能のイベントと同じ位置で後から届いた画面を_イベントより前に置く() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false, seconds: 0)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        // 録音の開始直後。画面も取得不能のイベントも0秒で、イベントが先に公開される。
        recorder.observeForTesting(try image(0.2), label: "開始直後の画面")
        #expect(recorder.pendingForTesting == 1)
        recorder.reportUnavailableForTesting("画面を取得できなくなりました")
        await wait { recorder.pendingForTesting == 0 && session.screenEntriesForTesting.count == 2 }
        #expect(session.screenEntriesForTesting.map(\.start) == [0, 0])
        #expect(session.screenEntriesForTesting.map(\.screenEvent) == [nil, .unavailable("画面を取得できなくなりました")])
        let rows = session.snapshot.utterances.filter { $0.kind == .screen }
        #expect(rows.map(\.screenEvent) == [nil, .unavailable("画面を取得できなくなりました")])
    }

    @Test func いま撮るの直後_どちらも届く前に一時停止しても_両方を押した順に公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        // 無音の中の自動の画面Aを受け付け、すぐ「いま撮る」を押し、どちらも届く前に一時停止する。
        recorder.observeForTesting(try image(0.2), label: "自動の画面")
        let request = try #require(recorder.beginCapture())
        session.togglePause()
        recorder.deliverCapturedForTesting(request, image: try image(0.8))
        await wait { recorder.pendingForTesting == 0 }
        // Aは一時停止の境界より前の受付なので公開する。「いま撮る」はAより後に押したので、Aを捨てない。
        #expect(session.screenEntriesForTesting.map(\.text) == ["自動の画面", request.label])
        #expect(session.heldScreenCountForTesting == 0 && captures(url).count == 2)
    }

    @Test func 会議を替えると公開していない画面を画像ごと捨て_古い記録の保存は受け付けない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url) = recording(root, voiced: false)
        let old = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        try await show(old, 0.2, label: "前の会議の画面", at: 0, from: Date())
        #expect(session.heldScreenCountForTesting == 1 && captures(url).count == 1)
        _ = session.installScreenRecorderForTesting(display: display, markdownURL: url)
        #expect(session.heldScreenCountForTesting == 0 && captures(url).isEmpty)
        // 無効にした古い記録が後から観測しても、保存も保留もしない。
        old.observeForTesting(try image(0.8), label: "前の会議の画面")
        await wait { old.pendingForTesting == 0 }
        #expect(session.heldScreenCountForTesting == 0 && session.screenEntriesForTesting.isEmpty)
        // 話し始めても、前の会議の保留は出てこない。
        session.acceptAudioForTesting(audio(seconds: 1, voiced: true))
        #expect(session.screenEntriesForTesting.isEmpty)
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

    @Test func いま撮るは画面のメニューに移し_選んだ対象を撮っている録音中だけ出す() {
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        let other = ScreenDisplay(id: 2, name: "Built-in Retina Display", points: CGSize(width: 1800, height: 1169), menuBarFraction: 0.03)
        controller.connectedScreenDisplays = { [display, other] }
        var snapshot = SessionSnapshot(state: .recording)
        snapshot.screenControl = ScreenControlState(display: .on(display), selected: display, paused: false)
        controller.apply(snapshot)
        #expect(controller.screenMenu().items.map(\.title) == ["撮らない", "", "EV3895", "Built-in Retina Display"])
        // 「…」のメニューからは外した。
        snapshot.canCaptureScreenNow = true
        controller.apply(snapshot)
        #expect(!controller.footerMenu().items.map(\.title).contains("いま撮る"))
        let menu = controller.screenMenu()
        #expect(menu.items.map(\.title) == ["撮らない", "", "EV3895", "Built-in Retina Display", "", "いま撮る"])
        // 印は最後に選んだ対象に1つだけ付ける。
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["EV3895"])
        snapshot.screenControl = ScreenControlState(display: .off, selected: nil, paused: false)
        snapshot.canCaptureScreenNow = false
        controller.apply(snapshot)
        #expect(controller.screenMenu().items.filter { $0.state == .on }.map(\.title) == ["撮らない"])
        // 選ぶとつながっているディスプレイを渡す。「撮らない」はnil。
        var chosen: [ScreenDisplay?] = []
        controller.onSelectScreen = { chosen.append($0) }
        let items = controller.screenMenu().items
        for title in ["Built-in Retina Display", "撮らない"] {
            let item = items.first { $0.title == title }!
            NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        #expect(chosen == [other, nil])
    }

    @Test func フッターの画面の操作は録音中と一時停止中だけ出し_状態ごとに名前と色を替える() {
        let footer = AICompactFooter()
        var snapshot = SessionSnapshot(state: .recording)
        footer.update(snapshot, reduceMotion: true)
        #expect(footer.screen.isHidden)
        snapshot.screenControl = ScreenControlState(display: .off, selected: nil, paused: false)
        footer.update(snapshot, reduceMotion: true)
        #expect(!footer.screen.isHidden && footer.screen.accessibilityLabel() == "画面の記録: 撮らない")
        #expect(footer.screen.foreground == Washi.muted)
        snapshot.screenControl = ScreenControlState(display: .on(display), selected: display, paused: false)
        footer.update(snapshot, reduceMotion: true)
        #expect(footer.screen.accessibilityLabel() == "画面の記録: EV3895" && footer.screen.foreground == Washi.ink)
        snapshot.screenControl?.paused = true
        footer.update(snapshot, reduceMotion: true)
        #expect(footer.screen.accessibilityLabel() == "画面の記録: EV3895、一時停止中" && footer.screen.foreground == Washi.muted)
        snapshot.screenControl = ScreenControlState(display: .failed(display), selected: display, paused: false)
        footer.update(snapshot, reduceMotion: true)
        #expect(footer.screen.accessibilityLabel() == "画面の記録: EV3895、記録できません" && footer.screen.foreground == Washi.red)
        // 長い名前でも幅の上限を超えない。
        let long = ScreenDisplay(id: 3, name: "Built-in Retina Display (Sidecar 2)", points: CGSize(width: 1, height: 1), menuBarFraction: 0)
        snapshot.screenControl = ScreenControlState(display: .on(long), selected: long, paused: false)
        footer.update(snapshot, reduceMotion: true)
        #expect(footer.screen.intrinsicContentSize.width == ScreenTargetButton.maximumWidth)
    }

    // MARK: - 録音中の切り替え

    /// 撮らずに始めた録音中の会議。選び直すと、ScreenCaptureKitに触れずに撮影を始めたことにする。
    private func recordingWithoutScreen(_ root: URL, voiced: Bool = true,
                                        start: @escaping (ScreenDisplay) -> String? = { _ in nil }) -> (MeetingSession, URL, ScreenRecorder) {
        let (session, url) = recording(root, voiced: voiced)
        let recorder = session.installScreenRecorderForTesting(display: nil, markdownURL: url, start: start)
        return (session, url, recorder)
    }

    private var other: ScreenDisplay {
        ScreenDisplay(id: 2, name: "Built-in Retina Display", points: CGSize(width: 64, height: 36), menuBarFraction: 0)
    }

    @Test func 撮らずに始めた会議で途中から選ぶと撮り始め_行を出さず置き場とMarkdownも働く() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url, recorder) = recordingWithoutScreen(root)
        #expect(session.snapshot.screenControl == ScreenControlState(display: .off, selected: nil, paused: false))
        #expect(!session.snapshot.canCaptureScreenNow)
        recorder.observeForTesting(try image(0.2), label: "撮る前")
        #expect(recorder.pendingForTesting == 0)
        session.selectScreen(display)
        // 選んだ時点ではフッターを替えない。撮影を始められた時点で替える。
        #expect(session.snapshot.screenControl?.display == .off && session.snapshot.screenControl?.selected == display)
        await session.waitScreenOperationsForTesting()
        #expect(session.snapshot.screenControl?.display == .on(display) && session.snapshot.canCaptureScreenNow)
        recorder.observeForTesting(try image(0.2), label: "EV3895 · Keynote")
        await wait { session.screenEntriesForTesting.count == 1 }
        // 撮らずに始めて初めて入れたときは、イベントの行を出さない。
        #expect(session.entriesForTesting.map(\.text) == ["EV3895 · Keynote"])
        #expect(captures(url).count == 1)
        #expect(MeetingFiles.imageDirectories(for: url).last == ScreenCaptureFiles.directory(for: url).path)
        session.saveInterimForTesting()
        let markdown = try String(contentsOf: url, encoding: .utf8)
        #expect(markdown.contains("画面: EV3895 · Keynote ![画面1]"))
    }

    @Test func 対象を替えると行を出さず_替える前に受け付けた保存も後から公開し_替えた先の最初の1枚を撮る() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        let base = Date()
        try await show(recorder, 0.2, label: "EV3895 · 前", at: 0, from: base)
        // 保存を受け付けた直後に替える。届くのは替えた後。
        recorder.observeForTesting(try image(0.8), observedAt: base.addingTimeInterval(4), label: "EV3895 · 替える直前")
        recorder.tickForTesting(at: base.addingTimeInterval(6))
        session.selectScreen(other)
        #expect(session.snapshot.screenControl?.display == .on(display))
        await session.waitScreenOperationsForTesting()
        #expect(session.snapshot.screenControl?.display == .on(other))
        await wait { recorder.pendingForTesting == 0 }
        // 替えた先が替える前の最後の画面と同じでも、比較の基準を引き継がずに撮る。
        recorder.observeForTesting(try image(0.8), label: "Built-in Retina Display · 後")
        await wait { session.screenEntriesForTesting.count == 3 }
        #expect(session.entriesForTesting.map(\.text) == ["EV3895 · 前", "EV3895 · 替える直前", "Built-in Retina Display · 後"])
    }

    @Test func 撮らないで切ると記録を停止を残し_入れ直すと記録を再開を残す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        recorder.observeForTesting(try image(0.2), label: "EV3895 · 前")
        await wait { session.screenEntriesForTesting.count == 1 }
        session.selectScreen(nil)
        // 「撮らない」はその場で止め、フッターもその場で替える。
        #expect(session.snapshot.screenControl?.display == .off && !session.snapshot.canCaptureScreenNow)
        recorder.observeForTesting(try image(0.8), label: "切った後")
        #expect(recorder.pendingForTesting == 0)
        // 同じものを続けて選んでも、行を重ねない。
        session.selectScreen(nil)
        session.selectScreen(other)
        await session.waitScreenOperationsForTesting()
        recorder.observeForTesting(try image(0.8), label: "Built-in Retina Display · 後")
        // イベントの行も画面の行に数える。
        await wait { session.screenEntriesForTesting.count == 4 }
        #expect(session.entriesForTesting.map(\.text) == ["EV3895 · 前", "記録を停止", "記録を再開", "Built-in Retina Display · 後"])
    }

    @Test func 開始の途中で続けて選ぶと最後に選んだものだけが効き_途中で切ると何も残さない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        let (session, _, _) = recordingWithoutScreen(root) { started.append($0.name); return nil }
        session.selectScreen(display)
        session.selectScreen(other)
        await session.waitScreenOperationsForTesting()
        #expect(started == ["Built-in Retina Display"])
        #expect(session.snapshot.screenControl?.display == .on(other))
        // 撮っていない会議で始める途中に切ったら、何も撮っていないので行を出さない。
        let (quiet, _, _) = recordingWithoutScreen(try directory())
        quiet.selectScreen(display)
        quiet.selectScreen(nil)
        await quiet.waitScreenOperationsForTesting()
        #expect(quiet.snapshot.screenControl?.display == .off && quiet.entriesForTesting.isEmpty)
    }

    @Test func 撮れなくなった後に選び直すと撮り直し_始められた時点でヘッダーの1行を消す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var allowed = false
        let (session, _, recorder) = recordingWithoutScreen(root) { _ in allowed ? nil : "「画面収録」の許可がありません" }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        await wait { session.snapshot.screenControl?.display == .failed(display) }
        // 許可が無いときは、開始シートで選んだときと同じく取得不能の行とヘッダーの1行を出す。
        #expect(session.entriesForTesting.map(\.screenEvent) == [.unavailable("「画面収録」の許可がありません")])
        #expect(session.snapshot.headerMessage.text.contains("画面を記録できません"))
        #expect(!session.snapshot.canCaptureScreenNow && recorder.isUnavailable)
        allowed = true
        session.selectScreen(display)
        // 始められるまではヘッダーの1行を残す。
        #expect(session.snapshot.headerMessage.text.contains("画面を記録できません"))
        await session.waitScreenOperationsForTesting()
        #expect(!session.snapshot.headerMessage.text.contains("画面を記録できません"))
        #expect(session.snapshot.screenControl?.display == .on(display) && session.snapshot.canCaptureScreenNow)
        recorder.observeForTesting(try image(0.2), label: "EV3895 · 撮り直し")
        await wait { session.screenEntriesForTesting.count == 3 }
        #expect(session.entriesForTesting.map(\.text) == ["記録できません: 「画面収録」の許可がありません", "記録を再開", "EV3895 · 撮り直し"])
    }

    @Test func 一時停止中に替えると再開から効き_切ると一時停止中でも記録を停止を残す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        let (session, _, recorder) = recordingWithoutScreen(root) { started.append($0.name); return nil }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        session.togglePause()
        session.selectScreen(other)
        await session.waitScreenOperationsForTesting()
        // 一時停止中は撮り始めない。フッターは前の対象の一時停止のまま。
        #expect(started == ["EV3895"])
        #expect(session.snapshot.screenControl == ScreenControlState(display: .on(display), selected: other, paused: true))
        recorder.observeForTesting(try image(0.2), label: "休憩中")
        #expect(recorder.pendingForTesting == 0)
        session.togglePause()
        await session.waitScreenOperationsForTesting()
        #expect(started == ["EV3895", "Built-in Retina Display"])
        #expect(session.snapshot.screenControl?.display == .on(other))
        session.togglePause()
        session.selectScreen(nil)
        #expect(session.entriesForTesting.map(\.text) == ["記録を停止"])
        session.togglePause()
        await session.waitScreenOperationsForTesting()
        #expect(started.count == 2 && session.snapshot.screenControl?.display == .off)
    }

    /// グローバルキーの入れ直す先を決める材料をそろえる。音と通知の本文を捕捉する。
    private func hotkeyed(_ session: MeetingSession, sheet: String? = nil) -> (sounds: () -> [Bool], notices: () -> [String]) {
        var sounds: [Bool] = []
        var notices: [String] = []
        session.connectedScreenDisplays = { [display, other] }
        session.mainScreenDisplayID = { other.id }
        session.lastSheetScreenDisplayName = { sheet }
        session.playAutoSendSound = { sounds.append($0) }
        session.notifyScreenHotkey = { notices.append($0) }
        return ({ sounds }, { notices })
    }

    @Test func グローバルキーで切ると記録を停止を残し_もう一度押すと直前に撮っていたディスプレイで再開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        let (session, _, recorder) = recordingWithoutScreen(root) { started.append($0.name); return nil }
        let (sounds, notices) = hotkeyed(session, sheet: other.name)
        let hotkey = try #require(GlobalHotkey("ctrl+alt+cmd+s"))
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        recorder.observeForTesting(try image(0.2), label: "EV3895 · 資料")
        await wait { session.screenEntriesForTesting.count == 1 }
        #expect(session.toggleScreenCapture(hotkey: hotkey))
        #expect(session.snapshot.screenControl?.display == .off)
        // 開始シートの前回値やメインより、この会議で直前に撮っていたディスプレイを選ぶ。
        #expect(session.toggleScreenCapture(hotkey: hotkey))
        await session.waitScreenOperationsForTesting()
        #expect(started == ["EV3895", "EV3895"] && session.snapshot.screenControl?.display == .on(display))
        #expect(session.entriesForTesting.map(\.text) == ["EV3895 · 資料", "記録を停止", "記録を再開"])
        // 録音中は撮っている画面の印の知らせで結果が見えるので、音も通知も出さない。
        #expect(sounds().isEmpty && notices().isEmpty)
    }

    @Test func 撮らずに始めた会議でグローバルキーを押すと開始シートで最後に選んだディスプレイ_無ければメインで撮り始める() async throws {
        var started: [String] = []
        let (session, _, _) = recordingWithoutScreen(try directory()) { started.append($0.name); return nil }
        let hotkey = try #require(GlobalHotkey("f18"))
        _ = hotkeyed(session, sheet: display.name)
        #expect(session.toggleScreenCapture(hotkey: hotkey))
        await session.waitScreenOperationsForTesting()
        #expect(started == ["EV3895"])
        // 撮らずに始めて初めて撮り始めたときは、フッターと同じく行を出さない。
        #expect(session.entriesForTesting.isEmpty)
        var fallback: [String] = []
        let (main, _, _) = recordingWithoutScreen(try directory()) { fallback.append($0.name); return nil }
        _ = hotkeyed(main, sheet: "外したディスプレイ")
        #expect(main.toggleScreenCapture(hotkey: hotkey))
        await main.waitScreenOperationsForTesting()
        #expect(fallback == ["Built-in Retina Display"])
    }

    @Test func 一時停止中にグローバルキーを押すと再開から効き_通知で知らせる() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        let (session, _, _) = recordingWithoutScreen(root) { started.append($0.name); return nil }
        let (sounds, notices) = hotkeyed(session)
        let hotkey = try #require(GlobalHotkey("ctrl+alt+cmd+s"))
        session.togglePause()
        #expect(session.toggleScreenCapture(hotkey: hotkey))
        await session.waitScreenOperationsForTesting()
        #expect(started.isEmpty && session.snapshot.screenControl?.selected == other)
        session.togglePause()
        await session.waitScreenOperationsForTesting()
        #expect(started == ["Built-in Retina Display"])
        session.togglePause()
        #expect(session.toggleScreenCapture(hotkey: hotkey))
        #expect(session.entriesForTesting.map(\.text) == ["記録を停止"])
        #expect(notices() == ["再開するとBuilt-in Retina Displayの記録を始めます（⌃⌥⌘S）", "画面の記録を停止しました（⌃⌥⌘S）"])
        #expect(sounds().isEmpty)
    }

    @Test func 撮れなくなった後にグローバルキーで撮り直す途中にもう一度押すと止める() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var allowed = false
        var started: [String] = []
        let (session, _, _) = recordingWithoutScreen(root) { started.append($0.name); return allowed ? nil : "「画面収録」の許可がありません" }
        _ = hotkeyed(session)
        let hotkey = try #require(GlobalHotkey("f18"))
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        await wait { session.snapshot.screenControl?.display == .failed(display) }
        allowed = true
        // 撮り直しを頼んだ直後、始められる前にもう一度押す。フッターはまだ撮れないままだが、止める向きにする。
        #expect(session.toggleScreenCapture(hotkey: hotkey))
        #expect(session.toggleScreenCapture(hotkey: hotkey))
        await session.waitScreenOperationsForTesting()
        #expect(session.snapshot.screenControl?.display == .off && session.snapshot.screenControl?.selected == nil)
        // 一時停止中に2回押しても同じく止める。再開しても撮り始めない。
        let (paused, _, _) = recordingWithoutScreen(try directory()) { _ in "「画面収録」の許可がありません" }
        _ = hotkeyed(paused)
        paused.selectScreen(display)
        await paused.waitScreenOperationsForTesting()
        await wait { paused.snapshot.screenControl?.display == .failed(display) }
        paused.togglePause()
        #expect(paused.toggleScreenCapture(hotkey: hotkey) && paused.toggleScreenCapture(hotkey: hotkey))
        paused.togglePause()
        await paused.waitScreenOperationsForTesting()
        #expect(paused.snapshot.screenControl?.display == .off && paused.snapshot.screenControl?.selected == nil)
    }

    @Test func 開始シートの前回値は撮らないで始めても入れ直す先を残し_足す前に選んだ名前も移す() throws {
        let defaults = try #require(UserDefaults(suiteName: "ScreenCaptureAppTests.\(UUID())"))
        // このキーを足す前に外部ディスプレイを選んでいた。更新後の最初の会議は「撮らない」で始める。
        defaults.set("EV3895", forKey: StartSheet.screenDefaultsKey)
        StartSheet.rememberScreenDisplay(nil, in: defaults)
        #expect(defaults.string(forKey: StartSheet.screenDefaultsKey) == "")
        #expect(defaults.string(forKey: StartSheet.lastScreenDisplayDefaultsKey) == "EV3895")
        StartSheet.rememberScreenDisplay("Built-in Retina Display", in: defaults)
        StartSheet.rememberScreenDisplay(nil, in: defaults)
        #expect(defaults.string(forKey: StartSheet.lastScreenDisplayDefaultsKey) == "Built-in Retina Display")
    }

    @Test func 録音外と画面を撮らない会議ではグローバルキーを断る() throws {
        let hotkey = try #require(GlobalHotkey("f18"))
        let idle = MeetingSession(config: ResolvedConfig(config: KikigakiConfig(outputDir: try directory().path)),
                                  models: { throw CancellationError() }, log: { _ in })
        let (idleSounds, idleNotices) = hotkeyed(idle)
        #expect(!idle.toggleScreenCapture(hotkey: hotkey))
        #expect(idleSounds() == [false])
        #expect(idleNotices() == ["画面の記録を切り替えられませんでした。録音中・一時停止中だけ切り替えられます（F18）"])
        // 音声ファイルの書き起こしとreplayは画面の記録を持たない。
        let (session, _) = recording(try directory())
        let (sounds, notices) = hotkeyed(session)
        #expect(!session.toggleScreenCapture(hotkey: hotkey))
        #expect(sounds() == [false])
        #expect(notices() == ["画面の記録を切り替えられませんでした。この会議では画面を記録しません（F18）"])
    }

    @Test func 無音の間の保留は切り替えと切る操作の手前で公開し_替えた後に捨てない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root, voiced: false)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        try await show(recorder, 0.2, label: "EV3895 · 無音の中", at: 0, from: Date())
        #expect(session.heldScreenCountForTesting == 1 && session.screenEntriesForTesting.isEmpty)
        session.selectScreen(other)
        // 替える手前の最後の画面を、一時停止と同じく公開する。
        #expect(session.heldScreenCountForTesting == 0 && session.screenEntriesForTesting.map(\.text) == ["EV3895 · 無音の中"])
        await session.waitScreenOperationsForTesting()
        try await show(recorder, 0.8, label: "Built-in Retina Display · 無音の中", at: 0, from: Date())
        #expect(session.heldScreenCountForTesting == 1)
        session.selectScreen(nil)
        #expect(session.heldScreenCountForTesting == 0)
        #expect(session.entriesForTesting.map(\.text) == ["EV3895 · 無音の中", "Built-in Retina Display · 無音の中", "記録を停止"])
    }

    @Test func 替える前に押したいま撮るは替えた先の基準にしない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        let request = try #require(recorder.beginCapture())
        session.selectScreen(other)
        await session.waitScreenOperationsForTesting()
        // 替えた先の観測より前に届いても、押した時点の対象の画面として公開する。
        recorder.deliverCapturedForTesting(request, image: try image(0.8))
        await wait { session.screenEntriesForTesting.count == 1 && recorder.pendingForTesting == 0 }
        #expect(session.screenEntriesForTesting.first?.text.hasPrefix("EV3895") == true)
        // 替えた先の最初の1枚は、同じ画面でも待たずに撮る。替える前の手動の1枚を基準にしていたら、変化なしとして撮らない。
        recorder.observeForTesting(try image(0.8), label: "Built-in Retina Display · 後")
        await wait { session.screenEntriesForTesting.count == 2 }
        #expect(session.screenEntriesForTesting.last?.text == "Built-in Retina Display · 後")
    }

    @Test func 替える前の対象の取得不能がMainActorへ届く前に替えても_替えた先を取得不能にせずストリームも閉じない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        #expect(recorder.openStreamTargetForTesting == 1)
        // EV3895の取得不能を判定した直後、MainActorへ届く前に内蔵を選ぶ。
        // このテストはMainActorで動き、2つの呼び出しの間で中断しないので、知らせはまだ届かない。
        recorder.reportUnavailableForTesting("ディスプレイ「EV3895」を取得できなくなりました")
        session.selectScreen(other)
        // ここで知らせが届き、内蔵の開始も流れる。どちらが先でも結果は同じ。
        try? await Task.sleep(for: .milliseconds(50))
        await session.waitScreenOperationsForTesting()
        #expect(session.snapshot.screenControl?.display == .on(other) && session.snapshot.canCaptureScreenNow)
        #expect(recorder.openStreamTargetForTesting == 2 && !recorder.isUnavailable)
        #expect(session.entriesForTesting.isEmpty)
        #expect(!session.snapshot.headerMessage.text.contains("画面を記録できません"))
        recorder.observeForTesting(try image(0.2), label: "Built-in Retina Display · 後")
        await wait { session.screenEntriesForTesting.count == 1 }
    }

    @Test func 撮れなくなった対象のストリームだけを閉じる() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        recorder.reportUnavailableForTesting("ディスプレイ「EV3895」を取得できなくなりました")
        await wait { session.snapshot.screenControl?.display == .failed(display) }
        await session.waitScreenOperationsForTesting()
        #expect(recorder.openStreamTargetForTesting == nil)
        #expect(session.entriesForTesting.map(\.screenEvent) == [.unavailable("ディスプレイ「EV3895」を取得できなくなりました")])
    }

    @Test func 替える前の対象の世代で片付けても_替えた先のストリームは残す() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        #expect(recorder.openStreamTargetForTesting == 1)
        session.selectScreen(other)
        await session.waitScreenOperationsForTesting()
        #expect(recorder.openStreamTargetForTesting == 2)
        // EV3895の取得不能の片付けが、内蔵を開いた後に流れた。
        await recorder.closeStream(target: 1)
        #expect(recorder.openStreamTargetForTesting == 2 && session.snapshot.canCaptureScreenNow)
        await recorder.closeStream(target: 2)
        #expect(recorder.openStreamTargetForTesting == nil)
    }

    /// 撮影に要るものは受け付けた時点で要求が持つ。ストリームの片付けが流れたかどうかでは結果が変わらず、
    /// 撮影を始める時点の対象の世代の確認だけで決まる。
    @Test func いま撮るを受け付けた後_撮影を始める前に替えるか切ると撮らない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        let shot = try image(0.8)
        var shots: [String] = []
        recorder.screenshotForTesting = { shots.append($0.name); return shot }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        // 替えなければ、撮影を始める時点の確認を通って撮る。
        let kept = try #require(recorder.beginCapture())
        await recorder.capture(kept)
        await wait { session.screenEntriesForTesting.count == 1 && recorder.pendingForTesting == 0 }
        #expect(shots == ["EV3895"])
        // EV3895で受け付け、撮影を始める前に内蔵を選ぶ。前のストリームの片付けはまだ流れていない。
        let switched = try #require(recorder.beginCapture())
        session.selectScreen(other)
        #expect(recorder.openStreamTargetForTesting == 1)
        await recorder.capture(switched)
        await session.waitScreenOperationsForTesting()
        // 内蔵で受け付け、撮影を始める前に「撮らない」を選ぶ。
        let cut = try #require(recorder.beginCapture())
        session.selectScreen(nil)
        await recorder.capture(cut)
        await wait { recorder.pendingForTesting == 0 }
        #expect(shots == ["EV3895"])
        #expect(session.screenEntriesForTesting.filter { !$0.imagePaths.isEmpty }.count == 1)
        #expect(session.entriesForTesting.last?.screenEvent == .stopped)
    }

    @Test func いま撮るの撮影を始めた後に替えても_撮った画像は公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        let shot = try image(0.8)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        // 世代の確認を通り、撮影APIを呼んだ後で「撮らない」を選ぶ。
        recorder.screenshotForTesting = { _ in session.selectScreen(nil); return shot }
        let request = try #require(recorder.beginCapture())
        await recorder.capture(request)
        await wait { recorder.pendingForTesting == 0 }
        // 切る前に受け付けた1枚なので、`記録を停止` の行より前に並ぶ。
        #expect(session.entriesForTesting.map(\.screenEvent) == [nil, .stopped])
        #expect(session.screenEntriesForTesting.filter { !$0.imagePaths.isEmpty }.count == 1)
    }

    @Test func いま撮るを受け付けた後に一時停止してストリームを閉じても_押した対象を撮って公開する() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        let shot = try image(0.8)
        var shots: [String] = []
        recorder.screenshotForTesting = { shots.append($0.name); return shot }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        let request = try #require(recorder.beginCapture())
        session.togglePause()
        await session.waitScreenOperationsForTesting()
        // ストリームの終了を終えてから撮影が動く。対象の世代は変わっていない。
        #expect(recorder.openStreamTargetForTesting == nil)
        await recorder.capture(request)
        await wait { session.screenEntriesForTesting.count == 1 && recorder.pendingForTesting == 0 }
        #expect(shots == ["EV3895"])
    }

    @Test func 停止の待ちの期限内は受付済みのいま撮るを撮り_期限を超えて無効にした後は撮らない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        let shot = try image(0.8)
        var shots = 0
        recorder.screenshotForTesting = { _ in shots += 1; return shot }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        let inTime = try #require(recorder.beginCapture())
        let late = try #require(recorder.beginCapture())
        recorder.stopAccepting()
        // 期限内は撮れる。
        await recorder.capture(inTime)
        #expect(shots == 1)
        await recorder.drain(timeout: .zero)
        #expect(recorder.isInvalidated)
        // 期限を超えて無効にした後に遅れて動いた要求は、対象の世代が合っていても撮影を始めない。
        await recorder.capture(late)
        #expect(shots == 1)
    }

    @Test func 会議を替えて同じ世代の番号になっても_古い記録の要求では撮らない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, url, old) = recordingWithoutScreen(root)
        let shot = try image(0.8)
        var shots: [String] = []
        old.screenshotForTesting = { _ in shots.append("前の会議"); return shot }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        let request = try #require(old.beginCapture())
        #expect(request.target == 1)
        // 次の会議の記録へ替える。世代は会議ごとに振り直すので、同じ1になる。
        let fresh = session.installScreenRecorderForTesting(display: nil, markdownURL: url)
        fresh.screenshotForTesting = { _ in shots.append("次の会議"); return shot }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        #expect(fresh.canCaptureNow && old.isInvalidated)
        await old.capture(request)
        #expect(shots.isEmpty)
    }

    @Test func 一時停止から再開してストリームを準備し直す間は_いま撮るを出さない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = recordingWithoutScreen(root)
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        session.togglePause()
        await session.waitScreenOperationsForTesting()
        // 撮影を始められた知らせが届いた時点の表示を集める。
        var announced: [Bool] = []
        session.onChange = { if $0.screenControl?.display == .on(display), $0.state == .recording { announced.append($0.canCaptureScreenNow) } }
        session.togglePause()
        // 閉じたストリームを準備し直している間は出さず、押しても受け付けない。
        #expect(!session.snapshot.canCaptureScreenNow)
        session.captureScreenNow()
        #expect(recorder.pendingForTesting == 0)
        await session.waitScreenOperationsForTesting()
        #expect(session.snapshot.canCaptureScreenNow)
        // 始められた知らせの時点で、撮影に要るものが揃っている。
        #expect(announced.last == true)
        // 対象の世代は増やさない。
        #expect(recorder.openStreamTargetForTesting == 1)
    }

    @Test func 替えた後に元の対象へ戻すと_戻した開始を終えるまでいま撮るを出さない() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        let (session, _, _) = recordingWithoutScreen(root) { started.append($0.name); return nil }
        session.selectScreen(display)
        await session.waitScreenOperationsForTesting()
        #expect(session.snapshot.canCaptureScreenNow)
        session.selectScreen(other)
        session.selectScreen(display)
        // 表示も選んだ対象もEV3895だが、戻した開始はまだ流れていない。
        #expect(session.snapshot.screenControl == ScreenControlState(display: .on(display), selected: display, paused: false))
        #expect(!session.snapshot.canCaptureScreenNow)
        session.captureScreenNow()
        await session.waitScreenOperationsForTesting()
        // 間の内蔵の開始は世代が変わって開かずに戻る。
        #expect(started == ["EV3895", "EV3895"])
        #expect(session.snapshot.canCaptureScreenNow && session.entriesForTesting.isEmpty)
    }

    @Test func 音声ファイルの書き起こしとreplayでは画面の操作を出さない() {
        let (session, _) = recording(FileManager.default.temporaryDirectory)
        // 記録を据えていない会議は、録音中でも操作を持たない。
        #expect(session.snapshot.screenControl == nil)
        session.selectScreen(display)
        #expect(session.snapshot.screenControl == nil && session.entriesForTesting.isEmpty)
    }
}
}
