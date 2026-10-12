import AppKit
import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIAppendixRowTests {
    private final class CaptureCanvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { Washi.paper.setFill(); dirtyRect.fill() }
    }
    @Test func 追記の件数と反映結果に文字倍率を掛け撮影する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), now = Date(timeIntervalSince1970: 100)
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["[12:00:00] タダシ: 資料を更新して"], outputDirectory: root)
        let p = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/ai/sessions/1.json").path,
            requestToken: "token", question: "資料を更新して", capturedAt: now, audioCutoffSeconds: 1)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: p), number: 1)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: now); try $0.submitted() }
        try conversation.receive(AIReceiveEvent(request: request, kind: .accept, recordedAt: now), at: now)
        var samples: [AIConversation] = [conversation]
        for number in 1...2 {
            let extra = try history.prepare(lines: snapshot.lines + ["[12:00:01] タダシ: \(number)枚目も修正"], outputDirectory: root)
            let appendix = AIAppendix(number: number, requestID: request.id, snapshot: extra, question: "\(number)枚目も修正して",
                capturedAt: now, audioCutoffSeconds: 2, tentativeTail: nil, sentAt: now)
            try conversation.update(request.id) { try $0.addAppendix(appendix) }
            samples.append(conversation)
        }
        try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: now.addingTimeInterval(4),
            body: "資料を更新しました。\n\n1枚目に追加の指示を反映しました。", appliedAppendices: [1]), at: now.addingTimeInterval(4))
        let followupP = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: p.sessionPath, requestToken: "token", question: "2枚目も修正して",
            capturedAt: now, audioCutoffSeconds: 2)
        let followup = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: followupP), number: 2)
        try conversation.append(followup)
        try conversation.update(followup.id) { try $0.beginSending(at: now); try $0.submitted() }
        try conversation.update(request.id) { try $0.forwardAppendices([2], to: followup.id) }
        samples.append(conversation)
        _ = NSApplication.shared
        for scale: CGFloat in [1, 2] {
            for (index, sample) in samples.enumerated() {
                let q = sample.questions[0]
                let item = try #require(AITimeline.items(conversation: sample, utterances: [], timeline: .init(startedAt: now))
                    .first { $0.requestID == request.id && !$0.isSend })
                let row = AIReplyRow(item: item, state: AIViewState(conversation: sample))
                row.setTextScale(scale)
                let progress = AIProgress(question: q, connection: .working, connectionGeneration: 1, report: .editing(total: 2))
                row.updateProgress(progress, reduceMotion: true, now: now.addingTimeInterval(4))
                if index < 3 {
                    #expect(row.noteText == "追記 \(index)件")
                    #expect(progress.currentStage == .editing)
                } else { #expect(row.noteText.contains("追記 1: 反映済み") && row.noteText.contains("追記 2: #2へ送り直し")) }
                let notes = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == row.noteText })
                #expect((notes.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 12 * scale)
                for width: CGFloat in [420, 900] {
                    row.frame = NSRect(x: 0, y: 0, width: width, height: row.height(for: width))
                    row.layoutSubtreeIfNeeded()
                    #expect(notes.frame.maxY <= row.frame.height && notes.frame.maxX <= width)
                }
                if let output = ProcessInfo.processInfo.environment["KIKIGAKI_APPENDIX_CAPTURE"] {
                    let url = URL(fileURLWithPath: output).standardizedFileURL
                    guard url.path.hasPrefix("/tmp/") || url.path.hasPrefix("/private/tmp/") else { throw AIError.unsafeFile }
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let canvas = CaptureCanvas(frame: row.bounds)
                    canvas.appearance = NSAppearance(named: .aqua)
                    canvas.addSubview(row)
                    let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                    // 描画キャッシュの中間物。確認用はcwebpで非可逆WebPへ変換する。
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("appendix-\(index)-\(Int(scale * 100)).png"))
                }
            }
        }
    }
}
