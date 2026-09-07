import AppKit
import KikigakiCore

/// 明示的に有効にしたreplayだけで、本番のコピー・改名・統合と保存を通す。
/// クリップボードは変更せず、手動コピーの出力先を検証ファイルへ差し替える。
@MainActor enum ReplayTypedVerification {
    private struct TimelineEvidence: Encodable {
        let startedAt: Date
        let pauses: [MeetingTimeline.Pause]
    }
    static func capture(_ session: MeetingSession, phase: String, window: NSWindow? = nil) throws {
        guard let markdown = session.snapshot.markdownURL else { throw AIError.invalid("missing replay meeting") }
        let directory = markdown.deletingLastPathComponent().appendingPathComponent("typed-verification/" + phase)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AIJSON.encode(session.snapshot.utterances).write(to: directory.appendingPathComponent("utterances.json"), options: .atomic)
        let timeline = session.snapshot.timeline
        try AIJSON.encode(TimelineEvidence(startedAt: timeline.startedAt, pauses: timeline.pauses))
            .write(to: directory.appendingPathComponent("timeline.json"), options: .atomic)
        if let view = window?.contentView?.superview {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("window.png"))
            }
        }
        var copyError: Error?
        session.copyContext(full: true) { prompt in
            do { try prompt.write(to: directory.appendingPathComponent("manual-copy.txt"), atomically: true, encoding: .utf8); return true }
            catch { copyError = error; return false }
        }
        if let copyError { throw copyError }
        guard !session.snapshot.handoffFailed else { throw AIError.invalid("replay copy failed") }
        for (source, name) in [(markdown, "meeting.md"), (MeetingFiles.rawURL(for: markdown), "meeting.raw.md")] {
            if FileManager.default.fileExists(atPath: source.path) {
                try Data(contentsOf: source).write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
    }
    static func finish(_ session: MeetingSession, rename: (slot: Int, name: String)?, window: NSWindow? = nil) throws {
        try capture(session, phase: "saved", window: window)
        let slots = session.snapshot.detectedSpeakerSlots
        if let slot = rename?.slot ?? slots.first {
            session.rename(slot: slot, to: rename?.name ?? "改名確認")
            try capture(session, phase: "renamed")
        }
        if slots.count >= 2 {
            session.setSpeakerMapping(source: slots[0], target: slots[1])
            try capture(session, phase: "merged")
            session.setSpeakerMapping(source: slots[0], target: nil)
            try capture(session, phase: "restored")
        }
    }
}
