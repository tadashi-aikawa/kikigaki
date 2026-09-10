import AppKit
import KikigakiCore
import KikigakiAIIO

/// 実AIの返送を待ち、本番のパス確定・表示切替へ操作を渡すreplay専用ハーネス。
/// requestと通知は作成も改変もしない。証跡にtokenや会話本文を複製しない。
@MainActor final class ReplayMinutesVerification {
    private var phase = 0
    private var evidence: [[String: String]] = []
    private var failure: Error?
    func canAsk(index: Int) -> Bool { index == 0 || (index == 1 && phase >= 3) || (index == 2 && phase >= 5) }

    func step(session: MeetingSession, window: TranscriptWindowController, mode: String) throws {
        if let failure { throw failure }
        guard let markdown = session.snapshot.markdownURL, let store = try session.previewMinutesStore() else { return }
        let root = markdown.deletingLastPathComponent()
        let preview = window.minutesSplit.preview
        let questions = session.aiRecord?.controller.conversation.questions ?? []
        if phase == 0 {
            phase = 1
            if window.minutesSplit.isPreviewVisible { window.toggleMinutes() }
            try capture("00-hidden", window: window, root: root, store: store)
            if mode == "outside" {
                window.toggleMinutes()
                let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/kikigaki-minutes-denied-" + session.aiMeetingID.uuidString + ".md").path
                try select(path, window: window, store: store)
                try capture("01-outside-selected", window: window, root: root, store: store)
            }
        }
        if mode == "outside" {
            if phase == 1, let question = questions.first, let result = question.result {
                guard result.kind == .failed, result.reason == "work_failed",
                      question.request.envelope.participant.minutesPath == store.state.humanMinutesPath,
                      !FileManager.default.fileExists(atPath: store.state.humanMinutesPath ?? "") else { throw AIError.invalid("outside result") }
                phase = 7
                try capture("02-work-failed", window: window, root: root, store: store,
                    extra: ["request": question.request.id.uuidString, "reason": "work_failed"])
            }
            return
        }
        if phase == 1, store.hasUnseenMinutes, store.state.targetSource == .ai {
            phase = 2
            try capture("01-notice", window: window, root: root, store: store)
            window.toggleMinutes()
        }
        if phase == 2, !preview.scroll.isHidden, !preview.textView.string.isEmpty, questions.first?.result != nil {
            try capture("02-ai-body", window: window, root: root, store: store)
            phase = 3
            try select(root.appendingPathComponent("human.md").path, window: window, store: store)
            try capture("03-human-selected", window: window, root: root, store: store)
            window.toggleMinutes()
        }
        if phase == 3, questions.count >= 2, let result = questions[1].result {
            guard result.kind == .answered, questions[1].request.envelope.participant.minutesPath == root.appendingPathComponent("human.md").path,
                  store.state.minutesPath == root.appendingPathComponent("human.md").path else { throw AIError.invalid("human path result") }
            phase = 4; window.toggleMinutes()
        }
        if phase == 4, !preview.scroll.isHidden, !preview.textView.string.isEmpty {
            try capture("04-human-body", window: window, root: root, store: store,
                extra: ["request": questions[1].request.id.uuidString, "minutes_path": questions[1].request.envelope.participant.minutesPath ?? ""])
            phase = 5
            session.aiRecord?.controller.beforeMinutesScanForReplay = { [weak self, weak session, weak window] in
                guard let self, self.phase == 5, let session, let window,
                      let controller = session.aiRecord?.controller, controller.conversation.questions.count >= 3 else { return }
                let request = controller.conversation.questions[2].request
                do {
                    let filename = request.id.uuidString + ".minutes.json"
                    let bytes = try AIFileStore(root: root).read([".kikigaki-context", request.envelope.meetingID.uuidString, "ai", "inbox", filename], limit: AILimits.eventBytes)
                    let event = try AIInbox.decodeMinutes(bytes, filename: filename, for: request)
                    self.phase = 6
                    try self.select(root.appendingPathComponent("kept.md").path, window: window, store: store)
                    guard let selected = store.state.targetChangedAt, selected > event.recordedAt else { throw AIError.invalid("stale event ordering") }
                    try self.capture("05-before-old-notification", window: window, root: root, store: store,
                        extra: ["event": event.filename, "recorded_at": ISO8601DateFormatter().string(from: event.recordedAt)])
                } catch AIFileError.missing { return }
                catch { self.failure = error }
            }
        }
        if phase == 6, questions.count >= 3, questions[2].result != nil,
           store.state.lastEvent?.eventID == questions[2].request.id.uuidString + "/minutes" {
            guard store.state.minutesPath == root.appendingPathComponent("kept.md").path else { throw AIError.invalid("old event changed target") }
            phase = 7; session.aiRecord?.controller.beforeMinutesScanForReplay = nil
            try capture("06-old-notification-ignored", window: window, root: root, store: store)
        }
    }
    private func select(_ path: String, window: TranscriptWindowController, store: MinutesStore) throws {
        window.minutesSplit.preview.pathField.stringValue = path
        window.minutesSplit.preview.commitPath()
        guard store.state.humanMinutesPath == path else { throw AIError.invalid("replay path selection failed") }
    }
    private func capture(_ name: String, window: TranscriptWindowController, root: URL, store: MinutesStore,
                         extra: [String: String] = [:]) throws {
        let directory = root.appendingPathComponent("minutes-verification")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var row = extra
        row["phase"] = name; row["at"] = ISO8601DateFormatter().string(from: Date())
        row["path"] = store.state.minutesPath ?? ""; row["human_path"] = store.state.humanMinutesPath ?? ""
        row["target_changed_at"] = store.state.targetChangedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        row["last_event"] = store.state.lastEvent?.eventID ?? ""
        row["visible"] = String(window.minutesSplit.isPreviewVisible); row["notice"] = String(store.hasUnseenMinutes)
        evidence.append(row)
        try AIJSON.encode(evidence).write(to: directory.appendingPathComponent("evidence.json"), options: .atomic)
        if let view = window.window?.contentView?.superview {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        print("Kikigaki: minutes検証 \(name)")
    }
}
