import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct UtteranceConfirmationRowTests {
    private let tokens = [TimedToken(text: "前の発言。", phraseId: 0, start: 0, end: 1),
                          TimedToken(text: "次の発言。", phraseId: 1, start: 1.1, end: 2),
                          TimedToken(text: "聞き取り中", phraseId: 2, start: 2.1, end: 3)]

    @Test(arguments: [true, false]) func 手入力と再描画で高精度境界を失わず停止で全て確定する(diarization: Bool) async throws {
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
        // オンは話者が未凍結なので両行とも未確定、オフは高精度の届いた先頭行だけ確定する。
        let expected: Set<Int> = diarization ? [0, 1] : [1]
        #expect(session.snapshot.unconfirmedRows == expected)
        #expect(session.submitTyped("手入力"))
        session.togglePause()
        session.rename(slot: 0, to: "田中")
        if diarization { session.setSpeakerMapping(source: 0, target: 1) }
        let snapshot = session.snapshot
        let voiceRows = snapshot.utterances.indices.filter { snapshot.utterances[$0].kind == .voice }
        #expect(snapshot.unconfirmedRows.isSubset(of: Set(voiceRows)))
        #expect(voiceRows.map { snapshot.unconfirmedRows.contains($0) } == (diarization ? [true] : [false, true]))
        #expect(snapshot.tentativeText != nil)
        await session.stop()
        #expect(session.snapshot.unconfirmedRows.isEmpty)
        #expect(session.snapshot.tentativeText == nil)
        session.rename(slot: 0, to: "停止後")
        #expect(session.snapshot.unconfirmedRows.isEmpty)
    }

    @Test func オフは同じ確定数のまま高精度へ置き換わっても即時反映する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: try ConfigLoader.parse(toml: "outputDir = \"\(root.path)\""))
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root), diarizationEnabled: false)
        let receive = session.undiarizedSnapshotHandlerForTesting
        receive(.init(tokens: tokens, finalCount: 2, accurateFinalCount: 0))
        #expect(session.snapshot.unconfirmedRows == [0, 1])
        receive(.init(tokens: tokens, finalCount: 2, accurateFinalCount: 2))
        #expect(session.snapshot.unconfirmedRows.isEmpty)
        #expect(session.pendingUndiarizedDrawForTesting == nil)
    }

    @Test func 確定の切替は行全体の濃さだけを変え点灯も行高も変えない() throws {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1], finalCount: 2)
        let row = TranscriptRow()
        let timeline = MeetingTimeline(startedAt: Date())
        row.update(live.utterances[0], names: SpeakerNames(), timeline: timeline)
        let height = row.height(for: 600)
        #expect(row.content.layer?.opacity == 1)
        row.updateConfirmation(unconfirmed: true)
        #expect(row.unconfirmed && row.content.layer?.opacity == TranscriptRow.unconfirmedOpacity)
        #expect(row.layer?.opacity == 1)
        #expect(!row.update(live.utterances[0], names: SpeakerNames(), timeline: timeline))
        #expect(row.height(for: 600) == height)
        let body = try #require(row.content.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "前の発言。" })
        #expect(body.accessibilityHelp()?.hasPrefix("未確定の発言") == true)
        #expect(!row.subviews.contains { $0 !== row.content })

        // 除外は未確定と掛け合わせず、除外の薄さだけにする。
        row.updateExclusion(true)
        #expect(row.content.layer?.opacity == TranscriptRow.excludedOpacity)
        let labels = row.content.subviews.compactMap { $0 as? NSTextField }
        #expect(labels.contains { !$0.isHidden && $0.stringValue == "小音量のため除外" })
        row.updateConfirmation(unconfirmed: false)
        #expect(row.content.layer?.opacity == TranscriptRow.excludedOpacity)
        row.updateExclusion(false)
        #expect(row.content.layer?.opacity == 1)
        #expect(body.accessibilityHelp() == "確定した発言")
        row.stopAnimations()
        #expect(row.content.layer?.opacity == 1)
        row.updateConfirmation(unconfirmed: true)
        row.stopAnimations()
        #expect(row.content.layer?.opacity == TranscriptRow.unconfirmedOpacity)
    }

    @Test func 手入力は薄くせず暫定末尾は文字色を変えずに常に未確定() throws {
        let timeline = MeetingTimeline(startedAt: Date())
        let typedRow = TranscriptRow()
        typedRow.update(try Utterance(typedText: "メモ", at: 1, postedAt: timeline.date(at: 1)),
                        names: SpeakerNames(), timeline: timeline)
        typedRow.updateConfirmation(unconfirmed: true)
        #expect(!typedRow.unconfirmed && typedRow.content.layer?.opacity == 1)

        let tentative = TranscriptRow(tentative: true)
        tentative.updateTentative("まだ聞き取っています")
        #expect(tentative.unconfirmed && tentative.content.layer?.opacity == TranscriptRow.unconfirmedOpacity)
        tentative.updateConfirmation(unconfirmed: false)
        #expect(tentative.unconfirmed)
        let labels = tentative.content.subviews.compactMap { $0 as? NSTextField }
        #expect(labels.contains { !$0.isHidden && $0.stringValue == "聞き取り中…" })
        let body = try #require(labels.first { $0.stringValue == "まだ聞き取っています" })
        let color = body.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == Washi.ink)
        tentative.updateExclusion(true)
        #expect(tentative.content.layer?.opacity == TranscriptRow.excludedOpacity)
    }
}
