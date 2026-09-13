import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct UtteranceGaugeTests {
    private let tokens = [TimedToken(text: "前の発言。", phraseId: 0, start: 0, end: 1),
                          TimedToken(text: "次の発言。", phraseId: 1, start: 1.1, end: 2),
                          TimedToken(text: "聞き取り中", phraseId: 2, start: 2.1, end: 3)]

    @Test(arguments: [true, false]) func 手入力と再描画で高精度境界を失わず停止で消す(diarization: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: try ConfigLoader.parse(toml: "outputDir = \"\(root.path)\""))
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root), diarizationEnabled: diarization)
        if diarization {
            session.publishForTesting(tokens: tokens, speakers: [0, 1, 1], elapsed: 3,
                                      finalCount: 2, accurateFinalCount: 1)
        } else {
            session.undiarizedSnapshotHandlerForTesting(.init(tokens: tokens, finalCount: 2, accurateFinalCount: 1))
        }
        let expected: [UtteranceProgress.Stage?] = [diarization ? .accurateFinal : nil, .fastFinal]
        #expect(session.snapshot.utteranceProgress?.rows == expected)
        #expect(session.submitTyped("手入力"))
        session.togglePause()
        session.rename(slot: 0, to: "田中")
        if diarization { session.setSpeakerMapping(source: 0, target: 1) }
        let snapshot = session.snapshot
        let progress = try #require(snapshot.utteranceProgress)
        #expect(progress.rows.count == snapshot.utterances.count)
        let voiceStages = snapshot.utterances.indices.filter { snapshot.utterances[$0].kind == .voice }.map { progress.rows[$0] }
        #expect(voiceStages == (diarization ? [.fastFinal] : expected))
        for index in snapshot.utterances.indices where snapshot.utterances[index].kind == .typed {
            #expect(progress.rows[index] == nil)
        }
        #expect(progress.tentative == .tentative)
        await session.stop()
        #expect(session.snapshot.utteranceProgress == nil)
        #expect(session.snapshot.tentativeText == nil)
        session.rename(slot: 0, to: "停止後")
        #expect(session.snapshot.utteranceProgress == nil)
    }

    @Test func オフは同じ確定数のまま高精度へ置き換わっても即時反映する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: try ConfigLoader.parse(toml: "outputDir = \"\(root.path)\""))
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root), diarizationEnabled: false)
        let receive = session.undiarizedSnapshotHandlerForTesting
        receive(.init(tokens: tokens, finalCount: 2, accurateFinalCount: 0))
        #expect(session.snapshot.utteranceProgress?.rows == [.fastFinal, .fastFinal])
        receive(.init(tokens: tokens, finalCount: 2, accurateFinalCount: 2))
        #expect(session.snapshot.utteranceProgress?.rows == [nil, nil])
        #expect(session.pendingUndiarizedDrawForTesting == nil)
        #expect(session.snapshot.utteranceProgress?.steps.count == 3)
    }

    @Test func 段だけの変更は点灯せず行高と除外状態を保つ() throws {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1], finalCount: 2)
        let row = TranscriptRow()
        let timeline = MeetingTimeline(startedAt: Date())
        row.update(live.utterances[0], names: SpeakerNames(), timeline: timeline, speakerPending: true)
        let height = row.height(for: 600)
        let steps = live.progress(accurateFinalCount: 0).steps
        row.updateProgress(.fastFinal, steps: steps)
        row.updateProgress(.accurateFinal, steps: steps)
        #expect(!row.update(live.utterances[0], names: SpeakerNames(), timeline: timeline, speakerPending: true))
        #expect(row.height(for: 600) == height)
        let gauge = try #require(row.subviews.compactMap { $0 as? UtteranceGaugeView }.first)
        #expect(gauge.stage == .accurateFinal && !gauge.isHidden)
        #expect(gauge.accessibilityValue() as? String == "高精度の確定(4段中3段目)")
        #expect(gauge.accessibilityChildren()?.isEmpty == true)
        #expect(gauge.subviews.last?.toolTip == "話者固定(4段中4段目)。停止時に全体を再判定します")
        row.updateExclusion(true)
        #expect(!gauge.isHidden && gauge.stage == .accurateFinal)
        #expect(row.layer?.opacity == 1 && row.content.layer?.opacity == 0.4)
        row.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        row.layoutSubtreeIfNeeded()
        #expect(gauge.frame.maxY <= row.bounds.height)
        #expect(gauge.frame.minX + 1 == 2)
        row.updateProgress(.fastFinal, steps: [.tentative, .fastFinal, .accurateFinal])
        #expect(gauge.accessibilityValue() as? String == "速報の確定(3段中2段目)")
        row.updateProgress(nil, steps: steps)
        #expect(gauge.isHidden)
        #expect(!row.update(live.utterances[0], names: SpeakerNames(), timeline: timeline, speakerPending: false))
    }
}
