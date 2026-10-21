import AppKit
import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
@Suite(.timeLimit(.minutes(1))) @MainActor struct InterimSaveAppTests {
    private func session(_ url: URL, root: URL) throws -> MeetingSession {
        MeetingSession(testingRecordingAt: url, config: ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root),
                       aiStore: AIRecordStore(directory: root), recordedSamples: 48_000)
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func 途中保存は半透明の行と手入力を含め暫定末尾を含めず停止で状態の行が消える() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.md")
        let session = try session(url, root: root)
        session.publishForTesting(tokens: [.init(text: "確定した声", phraseId: 0, start: 0, end: 1),
                                           .init(text: "半透明の声", phraseId: 1, start: 1.2, end: 2),
                                           .init(text: "揺れる末尾", phraseId: 2, start: 2.2, end: 2.8)],
                                  speakers: [0, 1, 1], elapsed: 3, finalCount: 2, accurateFinalCount: 1, frozenCount: 1)
        #expect(session.snapshot.unconfirmedRows == [1] && session.snapshot.tentativeText == "揺れる末尾")
        #expect(session.submitTyped("手入力のメモ"))
        session.saveInterimForTesting()
        let interim = try read(url)
        #expect(interim.contains("- 状態: 録音中の途中保存 ("))
        #expect(interim.contains("話者A: 確定した声") && interim.contains("話者B: 半透明の声") && interim.contains("手入力: 手入力のメモ"))
        #expect(!interim.contains("揺れる末尾"))
        #expect(session.snapshot.interimSaveWarning == nil)

        await session.stop()
        let final = try read(url)
        #expect(!final.contains("状態") && final.contains("手入力: 手入力のメモ"))
    }

    @Test func 一時停止した時点で保存し休憩中は書き直さない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.md")
        let session = try session(url, root: root)
        session.publishForTesting(tokens: [.init(text: "休憩前の声", phraseId: 0, start: 0, end: 1)], speakers: [0], elapsed: 2)
        session.togglePause()
        let paused = try read(url)
        #expect(paused.contains("休憩前の声") && paused.contains("- 状態: 録音中の途中保存 ("))
        try FileManager.default.removeItem(at: url)
        session.saveInterimForTesting(now: Date().addingTimeInterval(60))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        session.togglePause()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func 失敗はヘッダーに赤で出し次の成功で消す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("missing").appendingPathComponent("meeting.md")
        let session = try session(url, root: root)
        session.publishForTesting(tokens: [.init(text: "残したい声", phraseId: 0, start: 0, end: 1)], speakers: [0], elapsed: 2)
        session.saveInterimForTesting()
        let warning = try #require(session.snapshot.interimSaveWarning)
        #expect(warning.hasPrefix("途中保存に失敗: ") && warning.hasSuffix("1分後に再試行します"))
        #expect(session.snapshot.headerMessage.text.hasPrefix("途中保存に失敗: ") && session.snapshot.headerMessage.isError)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.saveInterimForTesting()
        #expect(session.snapshot.interimSaveWarning == nil && !session.snapshot.headerMessage.isError)
        #expect(try read(url).contains("残したい声"))
    }

    @Test func 小音量の除外は未完の音量窓を読まずコピーと同じ行を残す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.md")
        let session = try session(url, root: root)
        var meter = AudioLevelMeter()
        meter.append(Array(repeating: 0.1, count: 16000))
        meter.append(Array(repeating: 0.0001, count: 800))
        let loud = Utterance(speaker: nil, start: 0, end: 1, text: "大きな声")
        let tail = Utterance(speaker: nil, start: 1, end: 1.05, text: "計測途中の声")
        session.setAudioTranscriptForTesting([loud, tail], meter: meter, url: url)
        session.setAudioExclusion(.init(enabled: true))
        #expect(session.snapshot.includedUtterances == [loud, tail])
        session.saveInterimForTesting()
        let interim = try read(url)
        #expect(interim.contains(": 計測途中の声") && !interim.contains("## 小音量で除外した発話"))
    }

    @Test func 途中保存の失敗は消えないコピー失敗の通知に隠れない() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        var value = SessionSnapshot()
        value.state = .recording
        value.handoffMessage = "コピーできません: 試験"
        value.handoffFailed = true
        window.apply(value)
        #expect(window.noticeText == "コピーできません: 試験")
        value.interimSaveWarning = "途中保存に失敗: 試験。1分後に再試行します"
        window.apply(value)
        #expect(window.noticeText == "途中保存に失敗: 試験。1分後に再試行します / コピーできません: 試験")
    }

    @Test func 間隔ごとに書き停止後は途中保存しない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.md")
        let session = try session(url, root: root)
        session.publishForTesting(tokens: [.init(text: "周期で残す声", phraseId: 0, start: 0, end: 1)], speakers: [0], elapsed: 2)
        session.startInterimSavesForTesting(intervalSeconds: 1)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try read(url).contains("周期で残す声"))

        await session.stop()
        let final = try read(url)
        #expect(!final.contains("状態"))
        try await Task.sleep(for: .milliseconds(1500))
        #expect(try read(url) == final)
    }
}
}
