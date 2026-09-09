import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

/// 準備済みセッションの見た目を撮る。`KIKIGAKI_UI_CAPTURE` を渡したときだけ動く。
@Suite @MainActor struct AIPreparedReviewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ name: String, _ view: NSView, to output: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }

    @Test func 準備シートと紐づけシートを撮る() throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let profiles = [(slot: 1, name: "議事録"), (slot: 2, name: "相談")]

        // 一覧が空の準備シート。見出しごと出さない。
        let empty = AIPrepareSheet(profiles: profiles, selected: 1)
        empty.update(rows: [], launching: false)
        try capture("prepared-sheet-empty", empty.window.contentView!, to: output)

        // 溜まっている状態。設定が変わって使えない行も混ぜる。
        let filled = AIPrepareSheet(profiles: profiles, selected: 1)
        filled.update(rows: [
            .init(id: UUID(), label: "議事録 · Kikigaki 議事録抽出 · 13:05起動", stale: false),
            .init(id: UUID(), label: "相談 · 段取りの相談 · 13:10起動", stale: false),
            .init(id: UUID(), label: "相談 · 13:22起動", stale: true),
        ], launching: false)
        try capture("prepared-sheet-list", filled.window.contentView!, to: output)

        // 起動中。操作は面を足さず色を抜く。
        let launching = AIPrepareSheet(profiles: profiles, selected: 2)
        launching.update(rows: [.init(id: UUID(), label: "議事録 · Kikigaki 議事録抽出 · 13:05起動", stale: false)],
                         launching: true)
        try capture("prepared-sheet-launching", launching.window.contentView!, to: output)
        let popup = try #require(descendants(launching.window.contentView!).compactMap { $0 as? NSPopUpButton }.first)
        #expect(!popup.isEnabled)

        // 紐づけシート。相談には2件あるので、既定は最も古い1件。
        let attach = AIAttachSheet(choices: [
            .init(slot: 1, name: "議事録", prepared: [(UUID(), "Kikigaki 議事録抽出 · 13:05起動")]),
            .init(slot: 2, name: "相談", prepared: [(UUID(), "段取りの相談 · 13:10起動"), (UUID(), "13:22起動")]),
        ])
        try capture("prepared-attach-sheet", attach.window.contentView!, to: output)

        // 宛先ポップアップ。紐づけた枠は閉じたままでも何を使っているか判る。
        let picker = AIDestinationPicker()
        picker.update(items: [
            .init(slot: 1, name: "議事録", bound: "Kikigaki 議事録抽出 · 13:05起動"),
            .init(slot: 2, name: "相談", prepared: [.init(id: UUID(), label: "段取りの相談 · 13:10起動")]),
        ], selected: 1)
        picker.setFrameSize(NSSize(width: 460, height: 32))
        try capture("prepared-destination", picker, to: output)
        // 送信を始めた後。面を足さず色だけ抜く。
        picker.setEnabled(false)
        try capture("prepared-destination-disabled", picker, to: output)
    }

    @Test func 準備の行を幅ごとに撮る() throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_788_759_600)
        var ai = AIViewState()
        ai.participant = "迅雷"
        ai.profiles = [(1, "議事録"), (2, "相談")]
        ai.selectedSlot = 1
        ai.canPrepare = true
        ai.preparedSummary = "準備済み: 議事録 13:05 · 相談 13:10 · 議事録 13:22 ほか2件"
        ai.preparedToolTip = "議事録 · Kikigaki 議事録抽出 · 13:05起動"

        for width in [600, 900] {
            for (name, state) in [("idle", RecordingState.idle), ("recording", .recording)] {
                var snapshot = SessionSnapshot(ai: ai, state: state, utterances: state == .idle ? [] : [
                    .init(speaker: 0, start: 320, end: 324, text: "社内で体験会を開きます。"),
                ], timeline: .init(startedAt: started), elapsed: state == .idle ? 0 : 400,
                    markdownURL: root.appendingPathComponent("meeting.md"))
                snapshot.aiSchedule = AIScheduleViewState(schedule: nil, warning: nil, destination: "議事録")
                let window = TranscriptWindowController(shouldReduceMotion: { true })
                window.window!.setFrameAutosaveName("")
                window.window!.setFrame(NSRect(x: 20000, y: 20000, width: CGFloat(width), height: 700), display: false)
                window.apply(snapshot)
                let content = window.window!.contentView!
                content.layoutSubtreeIfNeeded()
                try capture("prepared-footer-\(name)-\(width)", content, to: output)
            }
        }
        // 台帳が読めないときは押させない。無効の理由は同じ行に出す。
        var broken = ai
        broken.canPrepare = false
        broken.preparedSummary = "準備済みAIセッションの台帳を読めません"
        var snapshot = SessionSnapshot(ai: broken, state: .idle, timeline: .init(startedAt: started))
        snapshot.aiSchedule = AIScheduleViewState(schedule: nil, warning: nil, destination: "議事録")
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 600, height: 700), display: false)
        window.apply(snapshot)
        window.window!.contentView!.layoutSubtreeIfNeeded()
        try capture("prepared-footer-disabled-600", window.window!.contentView!, to: output)
    }
}
