#if DEBUG
import AppKit
import KikigakiCore

/// 実寸検分用。トークン境界から本番Coreで導出したsnapshotを製品ウィンドウへ渡す。
@MainActor final class UtteranceGaugeHarness: NSObject, NSApplicationDelegate {
    private var controller: TranscriptWindowController!
    private let output: URL
    private let suite = "kikigaki-row-gauge-" + UUID().uuidString
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
                catch { FileHandle.standardError.write(Data("row gauge: \(error)\n".utf8)); exit(1) }
            }
        } catch { FileHandle.standardError.write(Data("row gauge: \(error)\n".utf8)); exit(1) }
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
            voiceProgress: stopped ? nil : live.progress(accurateFinalCount: busy ? 7 : 3))
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
        value.utteranceProgress = merged.progress
        if busy, let index = value.utterances.firstIndex(where: { $0.start == 64 && $0.kind == .voice }) {
            value.excludedRows = [index]
        }
        return value
    }

    private func renderAll() throws {
        let live = try snapshot()
        var before = live; before.utteranceProgress = nil
        try capture("row-before", before)
        try capture("row-live", live)
        try capture("row-stopped", snapshot(stopped: true))
        let off = try snapshot(diarization: false)
        var offBefore = off; offBefore.utteranceProgress = nil
        try capture("row-off-before", offBefore)
        try capture("row-off-live", off)
        try capture("row-off-stopped", snapshot(diarization: false, stopped: true))
        let busy = try snapshot(busy: true)
        var busyBefore = busy; busyBefore.utteranceProgress = nil
        try capture("row-busy-before", busyBefore)
        try capture("row-busy-live", busy)
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
            let y = name.contains("busy") ? maximum : 0
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
        let stages = snapshot.utteranceProgress?.rows.map { $0?.label ?? "非表示" }.joined(separator: ",") ?? "全て非表示"
        print("\(name): \(Int(view.bounds.width))×\(Int(view.bounds.height))pt, rows=\(stages), tentative=\(snapshot.utteranceProgress?.tentative?.label ?? "非表示")")
    }
}
#endif
