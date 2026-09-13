#if DEBUG
import AppKit
import KikigakiCore

/// replayの本番snapshot適用後を観測するだけの証跡採取。request・受信箱は変更しない。
@MainActor final class ReplayAIProgressVerification {
    private var previous = ""
    private var evidence: [[String: String]] = []
    func capture(snapshot: SessionSnapshot, window: TranscriptWindowController, directory: String) throws {
        guard let ai = snapshot.ai, let question = ai.conversation?.questions.last,
              let row = window.transcriptDocument.rows.compactMap({ $0 as? AIReplyRow }).first(where: {
                  $0.progressView.progress?.requestID == question.request.id
              }),
              let progress = row.progressView.progress else { return }
        let key = "\(question.request.id)-\(question.state)-\(progress.status)"
        guard previous != key else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = String(format: "%02d", evidence.count) + "-\(question.state)-\(progress.status)"
        let entry = ["phase": name, "at": ISO8601DateFormatter().string(from: Date()),
            "request": question.request.id.uuidString, "state": String(describing: question.state),
            "connection": String(describing: ai.connection(for: question.request)),
            "accepted": String(question.acceptance != nil), "result": String(question.result != nil),
            "status": String(describing: progress.status),
            "stages": progress.observedStages.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " → "),
            "progress_hidden": String(row.progressView.isHidden), "text": row.progressView.displayText]
        guard let view = window.window?.contentView?.superview else { throw AIError.invalid("capture window") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AIError.invalid("capture bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AIError.invalid("capture png") }
        try png.write(to: root.appendingPathComponent(name + ".png"))
        evidence.append(entry)
        try AIJSON.encode(evidence).write(to: root.appendingPathComponent("evidence.json"), options: .atomic)
        previous = key
        print("Kikigaki: AI進行検証 \(name)")
    }
}
#endif
