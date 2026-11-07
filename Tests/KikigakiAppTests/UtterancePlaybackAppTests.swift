import AppKit
import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

/// 発言ごとの音声再生。仕様は docs/utterance-playback.md
extension AppKitTests {
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct UtterancePlaybackAppTests {
    private func window() throws -> (TranscriptWindowController, () -> Void) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "UtterancePlaybackAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        controller.window?.setFrameAutosaveName("")
        return (controller, { controller.player.stop(); controller.window?.orderOut(nil); defaults.removePersistentDomain(forName: suite) })
    }

    private func stopped(audio: URL?) throws -> SessionSnapshot {
        var value = SessionSnapshot()
        value.state = .idle
        value.markdownURL = URL(fileURLWithPath: "/tmp/2026-11-07_1800.md")
        value.utterances = [
            Utterance(speaker: 0, start: 1, end: 3, text: "では次の議題に移ります"),
            try Utterance(typedText: "メモ", at: 3.5, postedAt: Date()),
            Utterance(speaker: 1, start: 4, end: 6, text: "来週までに見積もりを出します"),
        ]
        value.playbackAudioURL = audio
        return value
    }

    private func capture(_ view: NSView, _ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }

    private func voiceRows(_ controller: TranscriptWindowController) -> [TranscriptRow] {
        controller.rows.filter { $0.key.kind == .voice }.sorted { $0.key.start < $1.key.start }.map(\.value)
    }

    @Test func 元の音声がある会議の声の行だけを再生できる() throws {
        let (controller, close) = try window(); defer { close() }
        controller.apply(try stopped(audio: URL(fileURLWithPath: "/tmp/2026-11-07_1800.wav")))
        #expect(voiceRows(controller).allSatisfy { $0.playbackAvailable })
        #expect(controller.rows.filter { $0.key.kind == .typed }.allSatisfy { !$0.value.playbackAvailable })
        // マウスを載せていない行には▶を出さない。
        #expect(voiceRows(controller).allSatisfy { $0.playButton.isHidden })
        // マウスの出入りは行の矩形の中だけで受ける。行の外まで広げると隣の行でも▶が出る
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let tracked = voiceRows(controller).filter { $0.window != nil }
        #expect(!tracked.isEmpty)
        for row in tracked {
            row.updateTrackingAreas()
            let owned = row.trackingAreas.filter { $0.owner === row }
            #expect(owned.count == 1)
            for area in owned {
                #expect(!area.options.contains(.inVisibleRect) && row.bounds.contains(area.rect))
            }
        }
        // 再生中の行はマウスが無くても■を残す。時刻の直後に置き、時刻と重ねない。
        let row = voiceRows(controller)[1]
        row.updatePlayback(available: true, playing: true)
        row.frame = NSRect(x: 0, y: 0, width: 560, height: row.height(for: 560))
        row.layoutSubtreeIfNeeded()
        #expect(!row.playButton.isHidden)
        let time = try #require(row.content.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains(":") })
        #expect(row.playButton.frame.minX >= time.frame.minX + time.intrinsicContentSize.width)
        try capture(row, "utterance-playback-playing")

        // 録音中・元の音声を残さなかった会議は再生できない。
        var recording = try stopped(audio: nil)
        recording.state = .recording
        controller.apply(recording)
        #expect(controller.rows.values.allSatisfy { !$0.playbackAvailable })
    }

    @Test func 元の音声を開けなければヘッダーへ理由を出す() throws {
        let (controller, close) = try window(); defer { close() }
        var failure: String?
        controller.onPlaybackFailure = { failure = $0 }
        let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).wav")
        controller.apply(try stopped(audio: missing))
        voiceRows(controller)[1].onPlay?()
        #expect(controller.player.playingID == nil)
        #expect(failure?.hasPrefix("音声を再生できません: \(missing.lastPathComponent)") == true)
    }

    /// 音声の出力装置を使う。出力の無い環境では `AVAudioEngine` を始められないので、通常のテストでは鳴らさない
    @Test func 押した行を流し同じ行で止め別の行へ切り替える() throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_TEST_AUDIO_OUTPUT"] == "1" else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("2026-11-07_1800.wav")
        let writer = try WavWriter(url: url)
        try writer.write(Array(repeating: 0, count: 16000 * 8))
        writer.close()
        let (controller, close) = try window(); defer { close() }
        controller.apply(try stopped(audio: url))
        let rows = voiceRows(controller)
        rows[0].onPlay?()
        #expect(rows[0].playing && !rows[0].playButton.isHidden && !rows[1].playing)
        rows[1].onPlay?()
        #expect(!rows[0].playing && rows[0].playButton.isHidden && rows[1].playing)
        rows[1].onPlay?()
        #expect(!rows[1].playing && controller.player.playingID == nil)

        // 新しい録音を始めたら止める。
        rows[0].onPlay?()
        var next = SessionSnapshot()
        next.state = .preparing
        controller.apply(next)
        #expect(controller.player.playingID == nil)
    }

    /// 音声の出力装置を使う。区間の終わりで止まり、切り替えた後に届く前の行の完了通知では止まらない
    @Test func 区間を流し終えたら止まり前の行の完了通知では止まらない() async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_TEST_AUDIO_OUTPUT"] == "1" else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("2026-11-07_1800.wav")
        let writer = try WavWriter(url: url)
        try writer.write(Array(repeating: 0, count: 16000 * 8))
        writer.close()
        let (controller, close) = try window(); defer { close() }
        controller.apply(try stopped(audio: url))
        let rows = voiceRows(controller)
        // 1行目は0.5〜3.5秒、2行目は3.5〜6.5秒を流す。切り替えで止めた1行目の完了通知が後から届く
        rows[0].onPlay?()
        let old = controller.player.generation
        rows[1].onPlay?()
        // 前の行の完了通知を確実に届けてから確かめる。届く時刻は音声スレッド次第なので待つだけでは保証できない
        controller.player.finished(old)
        #expect(rows[1].playing && controller.player.playingID != nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(rows[1].playing && controller.player.playingID != nil)
        let deadline = Date().addingTimeInterval(6)
        while controller.player.playingID != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(controller.player.playingID == nil && !rows[1].playing)
    }

    /// オンデバイスSpeechを使う結合検証。通常のテストではモデル・言語アセットを要求しない。
    @Test func 録音WAVは停止して閉じてから再生の音源にする() async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_TEST_SPEECH"] == "1" else { return }
        final class Silence: AudioSource {
            func start(onSamples: @escaping ([Float]) -> Void) throws { onSamples(Array(repeating: 0, count: 16000)) }
            func stop() {}
        }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var settings = try ConfigLoader.parse(toml: "outputDir = \"\(root.path)\"")
        settings.saveRecording = true
        let session = MeetingSession(config: ResolvedConfig(config: settings), models: { throw CancellationError() }, log: { _ in })
        session.setDiarizationEnabled(false)
        #expect(await session.start(source: Silence()))
        #expect(session.snapshot.playbackAudioURL == nil)
        await session.stop()
        let markdown = try #require(session.snapshot.markdownURL)
        #expect(session.snapshot.playbackAudioURL == MeetingFiles.wavURL(for: markdown))

        // WAVを残さない会議は再生の音源を持たない。
        settings.saveRecording = false
        session.update(config: ResolvedConfig(config: settings))
        #expect(await session.start(source: Silence()))
        await session.stop()
        #expect(session.snapshot.playbackAudioURL == nil)
    }
}
}
