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
    private func show(_ recorder: ScreenRecorder, _ value: CGFloat, label: String, at offset: Double, from base: Date,
                      pending: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) async throws {
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
        recorder.captureForTesting(request, image: try image(0.5))
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
        recorder.captureForTesting(request, image: try image(0.8))
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
        recorder.captureForTesting(request, image: try image(0.8))
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
        recorder.captureForTesting(request, image: try image(0.8))
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
        recorder.captureForTesting(request, image: try image(0.8))
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
        recorder.captureForTesting(request, image: try image(0.8))
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
        recorder.captureForTesting(request, image: try image(0.8))
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
