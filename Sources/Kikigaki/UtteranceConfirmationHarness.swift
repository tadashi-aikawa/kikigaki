#if DEBUG
import AppKit
import KikigakiCore

/// 実寸検分用。トークン境界から本番Coreで導出したsnapshotを製品ウィンドウへ渡す。
@MainActor final class UtteranceConfirmationHarness: NSObject, NSApplicationDelegate {
    private var controller: TranscriptWindowController!
    private let output: URL
    private let suite = "kikigaki-row-confirmation-" + UUID().uuidString
    private let start = ISO8601DateFormatter().date(from: "2026-09-13T05:00:00Z")!
    private let texts = ["来週の公開に向けて、確認事項を整理します。", "録音と議事録の保存は、私が確認します。",
                         "AIへの依頼は、受領したか分かると助かります。", "話者が変わるところも、もう一度見ましょう。", "では、確認結果を今日中にまとめます。"]
    init(output: String) { self.output = URL(fileURLWithPath: output) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: UserDefaults(suiteName: suite)!)
            controller.window?.setFrameAutosaveName("")
            controller.window?.setContentSize(NSSize(width: 600, height: 740))
            controller.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                do { try renderAll(); NSApp.terminate(nil) }
                catch { FileHandle.standardError.write(Data("row confirmation: \(error)\n".utf8)); exit(1) }
            }
        } catch { FileHandle.standardError.write(Data("row confirmation: \(error)\n".utf8)); exit(1) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func snapshot(diarization: Bool = true, stopped: Bool = false, busy: Bool = false) throws -> SessionSnapshot {
        let count = busy ? 12 : 5
        let tokens = (0..<count).map { index in
            TimedToken(text: texts[index % texts.count], phraseId: index, start: Double(index * 8), end: Double(index * 8 + 6))
        }
        let live = LiveTranscript(tokens: tokens, speakers: tokens.indices.map { $0 % 2 },
                                  finalCount: stopped ? count : count - 1, frozenCount: stopped ? count : 2,
                                  diarizationEnabled: diarization)
        let timeline = MeetingTimeline(startedAt: start)
        var typed: [Utterance] = []
        if busy {
            for index in [3, 5, 7, 9] {
                let seconds = Double(index * 8 + 7)
                typed.append(try Utterance(typedText: "確認項目をメモに追記しました。", at: seconds,
                                          postedAt: timeline.date(at: seconds)))
            }
        }
        let merged = TranscriptEntries.merge(voice: live.utterances, typed: typed, timeline: timeline,
            pendingVoiceRows: live.pendingSpeakerRows,
            unconfirmedVoiceRows: stopped ? [] : live.unconfirmedRows(accurateFinalCount: busy ? 7 : 3))
        var value = SessionSnapshot()
        value.state = stopped ? .idle : .recording
        value.elapsed = Double(count * 8)
        value.timeline = timeline
        value.names = SpeakerNames([0: "田中", 1: "佐藤"])
        value.names.diarizationEnabled = diarization
        value.detectedSpeakerSlots = diarization ? [0, 1] : []
        value.markdownURL = output.appendingPathComponent("fixture.md")
        value.saved = stopped
        value.utterances = merged.utterances
        value.pendingSpeakerRows = merged.pendingSpeakerRows
        value.tentativeText = live.tentativeText
        value.unconfirmedRows = merged.unconfirmedRows
        if busy {
            // 確定済みと未確定の行を1つずつ除外し、除外の薄さが未確定と掛け合わないことを見比べる。
            value.excludedRows = Set([8.0, 64.0].compactMap { start in
                value.utterances.firstIndex { $0.start == start && $0.kind == .voice }
            })
        }
        return value
    }

    /// 同じ内容のまま、声の行をすべて未確定またはすべて確定にした比較用。暫定末尾は常に未確定。
    private func uniform(_ value: SessionSnapshot, unconfirmed: Bool) -> SessionSnapshot {
        var copy = value
        copy.unconfirmedRows = unconfirmed
            ? Set(value.utterances.indices.filter { value.utterances[$0].kind == .voice }) : []
        return copy
    }

    private func renderAll() throws {
        let on = try snapshot()
        try capture("on-unconfirmed", uniform(on, unconfirmed: true))
        try capture("on-confirmed", uniform(on, unconfirmed: false))
        try capture("on-live", on)
        try capture("on-stopped", snapshot(stopped: true))
        let off = try snapshot(diarization: false)
        try capture("off-unconfirmed", uniform(off, unconfirmed: true))
        try capture("off-confirmed", uniform(off, unconfirmed: false))
        try capture("off-live", off)
        // 先頭側に確定+除外、末尾側に未確定+除外が入る。
        try capture("busy-top", snapshot(busy: true))
        try capture("busy-bottom", snapshot(busy: true))
    }

    private func capture(_ name: String, _ snapshot: SessionSnapshot) throws {
        controller.apply(snapshot)
        guard let view = controller.window?.contentView else { throw AIError.invalid("content view") }
        view.layoutSubtreeIfNeeded()
        controller.transcriptDocument.layoutSubtreeIfNeeded()
        // 状態切替のスクロールアンカーを撮影へ持ち込まず、行頭から比較する。
        let document = controller.transcriptDocument
        if let scroll = document.enclosingScrollView {
            let maximum = max(0, document.frame.height - scroll.contentSize.height)
            let y = name.hasSuffix("bottom") ? maximum : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AIError.invalid("bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AIError.invalid("png") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        guard let actual = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 740,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw AIError.invalid("1x bitmap") }
        actual.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: actual)
        guard let actualPNG = actual.representation(using: .png, properties: [:]) else { throw AIError.invalid("1x png") }
        try actualPNG.write(to: output.appendingPathComponent(name + "-1x.png"))
        let rows = snapshot.utterances.indices.map { index in
            let kind = snapshot.utterances[index].kind == .typed ? "手入力" : snapshot.unconfirmedRows.contains(index) ? "未確定" : "確定"
            return snapshot.excludedRows.contains(index) ? kind + "+除外" : kind
        }.joined(separator: ",")
        print("\(name): \(Int(view.bounds.width))×\(Int(view.bounds.height))pt, rows=\(rows), tentative=\(snapshot.tentativeText == nil ? "なし" : "未確定")")
    }
}
#endif
