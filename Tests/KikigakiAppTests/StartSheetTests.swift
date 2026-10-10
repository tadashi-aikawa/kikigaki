import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

// 実シートの焦点と閉じる操作を確かめるため、同時に複数を開かない。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct StartSheetTests {
    @Test func システム音声の自動判定が追従し開始時に固定する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var kind: AudioOutputKind = .headphones
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(), outputKind: { kind })
        #expect(sheet.systemAudioAutomatic.title == "自動(いまは取り込む)")
        #expect(sheet.options?.recordSystemAudio == true)
        try capture("system-auto-include", sheet)
        kind = .builtInSpeaker
        sheet.refreshSystemAudioOutput()
        #expect(sheet.systemAudioAutomatic.title == "自動(いまは取り込まない)")
        #expect(sheet.options?.recordSystemAudio == false)
        try capture("system-auto-exclude", sheet)
        sheet.selectSystemAudio(.include)
        #expect(sheet.options?.recordSystemAudio == true)
        kind = .unknown
        #expect(sheet.options?.recordSystemAudio == true)
        sheet.selectSystemAudio(.exclude)
        #expect(sheet.options?.recordSystemAudio == false)
        var cancelled = false
        sheet.onCancel = { cancelled = true }
        sheet.cancelPressed()
        #expect(cancelled)
    }
    private func profiles(_ root: URL, toml: String) throws -> [ResolvedAIConfig] {
        ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: root).aiProfiles
    }
    private func twoProfiles(_ root: URL) throws -> [ResolvedAIConfig] {
        try profiles(root, toml: """
        [[ai]]
        name = "相談"
        cli = "claude"
        model = "claude-opus-5"
        effort = "max"
        cwd = "~/work/kikigaki"
        autoPrompt = "気になった点を3つまで挙げてください"

        [[ai]]
        name = "議事録"
        cli = "codex"
        model = "gpt-5.4"
        effort = "high"
        cwd = "~/work/minutes"
        autoStart = true
        autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください"
        autoIntervalMinutes = 5
        allowWork = false
        """)
    }

    @Test func AI未設定なら自動送信の区画ごと出さず開始できる() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], diarizationEnabled: false, exclusion: AudioExclusion())
        var started: StartSheet.Options?
        sheet.onStart = { started = $0 }
        #expect(sheet.destination.superview == nil)
        sheet.startPressed()
        #expect(started == StartSheet.Options(diarizationEnabled: false, exclusionEnabled: false))
        // 説明文は置かない。読めない議事録の理由だけを出す。
        #expect(sheet.minutesHintText.isEmpty)
        try capture("b-minimal", sheet)
    }

    @Test func 小音量除外はスイッチでON_OFFだけを決める() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], diarizationEnabled: true,
                               exclusion: AudioExclusion(enabled: true, thresholdDBFS: -50))
        #expect(sheet.exclusionSwitch.state == .on)
        #expect(sheet.options?.exclusionEnabled == true)
        sheet.exclusionSwitch.state = .off
        #expect(sheet.options?.exclusionEnabled == false)
    }

    @Test func 既定の宛先はautoStartのプロファイルで閉じた行に型式を出す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(enabled: true, thresholdDBFS: -45),
                               minutesPath: "/work/minutes/2026-09-16 定例.md")
        #expect(sheet.selectedSlot == 2)
        #expect(sheet.destinationTitle == "議事録 · Codex · gpt-5.4 (high)")
        #expect(!sheet.aiDetails.isHidden)
        #expect(sheet.interval.selectedTag() == 5)
        // 作業許可の初期値は宛先の設定から採る。
        #expect(sheet.work.state == .off && sheet.final.state == .on)
        let options = try #require(sheet.options)
        #expect(options.scheduleSlot == 2)
        #expect(options.schedule?.prompt == "会議の決定事項と担当・期限をMarkdown議事録へ更新してください")
        #expect(options.schedule?.interval == 300 && options.schedule?.workAllowed == false)
        #expect(options.minutesPath == "/work/minutes/2026-09-16 定例.md")
        try capture("a-full", sheet)
    }

    @Test func autoStartが無ければ送らないが既定で詳細を無効表示する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try profiles(root, toml: "[[ai]]\nname = \"相談\""),
                               diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(sheet.selectedSlot == nil)
        #expect(!sheet.aiDetails.isHidden && sheet.aiDetails.alphaValue == 0.4)
        #expect(!sheet.editor.isEditable && !sheet.editor.isSelectable)
        #expect(!sheet.interval.isEnabled && !sheet.work.isEnabled && !sheet.final.isEnabled)
        #expect(sheet.destinationTitle == "送らない")
        #expect(sheet.options?.scheduleSlot == nil && sheet.options?.schedule == nil)
    }

    @Test func 宛先を選び直すと下書きを覚え送らないで無効表示する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        sheet.editor.string = "議事録の下書き"
        sheet.destination.selectItem(withTag: 1)
        sheet.destinationChanged()
        #expect(sheet.selectedSlot == 1)
        #expect(sheet.editor.string == "気になった点を3つまで挙げてください")
        #expect(sheet.interval.selectedTag() == 3 && sheet.work.state == .on)
        sheet.destination.selectItem(withTag: 2)
        sheet.destinationChanged()
        #expect(sheet.editor.string == "議事録の下書き")
        sheet.destination.selectItem(withTag: 0)
        sheet.destinationChanged()
        #expect(sheet.selectedSlot == nil && !sheet.aiDetails.isHidden)
        #expect(sheet.aiDetails.alphaValue == 0.4)
        #expect(!sheet.editor.isEditable && !sheet.editor.isSelectable)
        #expect(!sheet.interval.isEnabled && !sheet.work.isEnabled && !sheet.final.isEnabled)
        #expect(sheet.options?.schedule == nil)
        try capture("send-none", sheet)
        sheet.destination.selectItem(withTag: 2); sheet.destinationChanged()
        #expect(sheet.editor.string == "議事録の下書き")
        #expect(sheet.aiDetails.alphaValue == 1 && sheet.editor.isEditable && sheet.editor.isSelectable)
        #expect(sheet.interval.isEnabled && sheet.work.isEnabled && sheet.final.isEnabled)
    }

    @Test func プロンプトは畳まずそのまま書き換えられ宛先メニューにも先頭が並ぶ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(sheet.editor.string == "会議の決定事項と担当・期限をMarkdown議事録へ更新してください")
        #expect(sheet.editor.enclosingScrollView?.frame.height ?? 0 >= StartSheet.promptHeight)
        sheet.editor.string = "決定事項だけ書いてください"
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        try capture("d-ai-edited", sheet)
        #expect(sheet.options?.schedule?.prompt == "決定事項だけ書いてください")
        // メニューの各行は名前・型式・プロンプトの3行。「送らない」だけ1行。
        let items = try #require(sheet.destination.menu?.items)
        #expect(items[0].title == "送らない" && items[0].attributedTitle == nil)
        let lines = items[2].attributedTitle?.string.split(separator: "\n").map(String.init) ?? []
        #expect(lines == ["議事録", "Codex · gpt-5.4 (high)","会議の決定事項と担当・期限をMarkdown議事録へ更新してください"])
        #expect(StartSheet.promptLine("一行目\n二行目") == "一行目 二行目")
        #expect(StartSheet.promptLine("   ") == nil)
        #expect(StartSheet.promptLine(String(repeating: "あ", count: 60)) == String(repeating: "あ", count: 48) + "…")
    }

    @Test func 議事録は履歴とドロップで指定し不正なパスでは開始しない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(),
                               minutesHistory: ["/work/a.md", "/work/b.md"])
        #expect(sheet.historyPaths == ["/work/a.md", "/work/b.md"])
        // 履歴のメニューはファイル名とディレクトリの2行。長いパスでもファイル名から欠けない。
        let items = sheet.historyMenu().items
        #expect(items.map(\.toolTip) == ["/work/a.md", "/work/b.md"])
        #expect(items[0].attributedTitle?.string == "a.md\n/work")
        #expect(sheet.historyButton.isEnabled)
        var started: StartSheet.Options?
        sheet.onStart = { started = $0 }
        sheet.minutesBox.stringValue = "relative.txt"
        sheet.startPressed()
        #expect(started == nil)
        // ドロップは .md のファイルだけ受ける。
        let pasteboard = NSPasteboard(name: .init("StartSheetTests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/work/dropped.md") as NSURL])
        #expect(sheet.minutesBox.droppedPath(pasteboard) == "/work/dropped.md")
        sheet.setMinutesPath("/work/dropped.md")
        sheet.startPressed()
        #expect(started?.minutesPath == "/work/dropped.md")
    }

    @Test func 実ウィンドウへシートとして出し幅と高さと焦点を保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "StartSheetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        controller.window?.setFrameAutosaveName("")
        let parent = try #require(controller.window)
        let next = try NextMeeting(minutesPath: root.appendingPathComponent("定例.md").path, ai: "議事録")
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion(),
                               nextMeetings: [next])
        sheet.present(on: parent)
        #expect(parent.attachedSheet === sheet.window && sheet.window.sheetParent === parent)
        #expect(!parent.ignoresMouseEvents)
        #expect(sheet.window.styleMask.contains(.titled))
        #expect((sheet.window as? AIQuestionWindow)?.monitorsOutsideClicks == true)
        #expect(sheet.window.firstResponder === sheet.startButton)
        #expect(sheet.startButton.focusRingType == .none)
        sheet.window.selectNextKeyView(nil)
        #expect(sheet.window.firstResponder != nil && sheet.window.firstResponder !== sheet.startButton)
        #expect(sheet.window.frame.width == StartSheet.width)
        // 「送らない」でも詳細を残し、窓の高さを保つ。
        let expanded = sheet.window.frame.height
        sheet.destination.selectItem(withTag: 0)
        sheet.destinationChanged()
        #expect(sheet.window.frame.width == StartSheet.width && sheet.window.frame.height == expanded)
        sheet.close()
        #expect(parent.attachedSheet == nil)
        #expect(sheet.window.parent == nil && !parent.ignoresMouseEvents)
        #expect((sheet.window as? AIQuestionWindow)?.monitorsOutsideClicks == false)
    }

    @Test func 取消は何も始めない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        var started = false, cancelled = false
        sheet.onStart = { _ in started = true }
        sheet.onCancel = { cancelled = true }
        sheet.cancelPressed()
        #expect(!started && cancelled)
    }

    @Test func 次の会議を先頭から選び議事録と宛先を切り替える() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let firstPath = root.appendingPathComponent("定例.md"), secondPath = root.appendingPathComponent("相談.md")
        try Data("---\nparticipants: [Tadashi]\n---\n# 定例の議事録\n\n本文".utf8).write(to: firstPath)
        try Data("# 相談の見出し\n".utf8).write(to: secondPath)
        let first = try NextMeeting(minutesPath: firstPath.path, at: "2026-10-10T13:00", ai: "議事録")
        let second = try NextMeeting(minutesPath: secondPath.path, title: "プロダクト相談", at: "2026-10-10T14:00", ai: "相談")
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion(),
                               nextMeetings: [second, first])
        #expect(sheet.nextMeetings == [first, second])
        #expect(sheet.nextButtons.count == 3 && sheet.nextButtons[0].state == .on)
        #expect(sheet.nextButtons.last?.title == "指定しない")
        #expect(sheet.nextTitles.map(\.stringValue) == ["13:00 定例の議事録", "14:00 プロダクト相談"])
        #expect(sheet.nextDetails[0].stringValue == "議事録 · 定例.md")
        #expect(sheet.minutesBox.stringValue == firstPath.path)
        #expect(sheet.options?.minutesPath == firstPath.path && sheet.options?.scheduleSlot == 2)
        #expect(sheet.interval.selectedTag() == 5 && sheet.work.state == .off)
        #expect(sheet.diarizeOn.state == .on && sheet.systemAudioAutomatic.state == .on)
        try capture("next-two", sheet)
        #expect(sheet.window.frame.width == 640)
        sheet.nextMeetingChanged(sheet.nextButtons[1])
        #expect(sheet.minutesBox.stringValue == secondPath.path && sheet.selectedSlot == 1)
        #expect(sheet.nextButtons[0].state == .off && sheet.nextButtons[1].state == .on)
        #expect(sheet.options?.schedule?.prompt == "気になった点を3つまで挙げてください")
        // 手で直した値は予約へ書き戻さず、開始時の指定としてそのまま使う。
        sheet.minutesBox.stringValue = "/手で変えた.md"
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        #expect(sheet.options?.minutesPath == "/手で変えた.md" && sheet.options?.scheduleSlot == nil)
        sheet.nextMeetingChanged(sheet.nextButtons[2])
        #expect(sheet.minutesBox.stringValue.isEmpty && sheet.selectedSlot == 2)
        #expect(sheet.options?.minutesPath == nil && sheet.options?.scheduleSlot == 2)
        sheet.close()
    }

    @Test func 設定にない宛先と未作成ファイルを金色で示して送らない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("未作成.md")
        let meeting = try NextMeeting(minutesPath: missing.path, ai: "廃止した宛先")
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: [meeting])
        #expect(sheet.nextTitles[0].stringValue == "未作成.md")
        #expect(sheet.nextDetails[0].stringValue == "廃止した宛先 · 未作成.md · 設定にありません · 見つかりません")
        #expect(sheet.nextDetails[0].textColor == Washi.gold)
        #expect(sheet.selectedSlot == nil && sheet.options?.schedule == nil)
        #expect(sheet.options?.minutesPath == missing.path)
        sheet.selectNextMeeting(at: 1)
        #expect(sheet.selectedSlot == 2 && sheet.minutesBox.stringValue.isEmpty)
    }

    @Test func 宛先省略は送らず指定しないで既定へ戻る() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("見出しなし.md")
        try Data("本文だけ\n".utf8).write(to: path)
        let meeting = try NextMeeting(minutesPath: path.path)
        let sheet = StartSheet(profiles: try profiles(root, toml: "[[ai]]\nname = \"相談\""),
                               diarizationEnabled: true, exclusion: AudioExclusion(), nextMeetings: [meeting])
        #expect(sheet.nextTitles[0].stringValue == "見出しなし.md")
        #expect(sheet.nextDetails[0].stringValue == "送らない · 見出しなし.md")
        #expect(sheet.nextDetails[0].textColor == Washi.muted)
        #expect(sheet.selectedSlot == nil)
        sheet.selectNextMeeting(at: 1)
        #expect(sheet.selectedSlot == nil && sheet.minutesBox.stringValue.isEmpty)
    }

    @Test func 次の会議は三件まで表示しゼロ件なら行を置かない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try (1...4).map { try NextMeeting(minutesPath: root.appendingPathComponent("\($0).md").path,
                                                        createdAt: Date(timeIntervalSince1970: Double($0))) }
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(), nextMeetings: meetings)
        #expect(sheet.nextMeetings.count == 3 && sheet.nextButtons.count == 4)
        var cancelled = false
        sheet.onCancel = { cancelled = true }; sheet.cancelPressed()
        #expect(cancelled && sheet.nextMeetings.count == 3)
        let empty = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(empty.nextButtons.isEmpty && empty.nextTitles.isEmpty)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        #expect(!labels(try #require(empty.window.contentView)).contains("次の会議"))
        try capture("next-none", empty)
    }

    @Test func 次の会議は題と二段目と行の余白をクリックして選べる() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try ["定例", "相談"].map {
            try NextMeeting(minutesPath: root.appendingPathComponent("\($0).md").path, title: $0, ai: $0 == "定例" ? "議事録" : "相談")
        }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: meetings)
        let content = try #require(sheet.window.contentView)
        func click(_ view: NSView, at point: NSPoint) throws {
            content.layoutSubtreeIfNeeded()
            let location = view.convert(point, to: nil)
            let hitPoint = try #require(content.superview).convert(location, from: nil)
            let hit = try #require(content.hitTest(hitPoint))
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: sheet.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            hit.mouseDown(with: event)
        }
        // 選択済みの行へのクリックでは成功を見逃すので、毎回「指定しない」へ戻す。
        for index in meetings.indices {
            for label in [sheet.nextTitles[index], sheet.nextDetails[index]] {
                sheet.selectNextMeeting(at: meetings.count)
                try click(label, at: NSPoint(x: 8, y: label.bounds.midY))
                #expect(sheet.options?.minutesPath == meetings[index].minutesPath)
                #expect(sheet.selectedSlot == (index == 0 ? 2 : 1))
                #expect(sheet.nextButtons.map(\.state) == (0...meetings.count).map { $0 == index ? .on : .off })
            }
            let choice = try #require(sheet.nextButtons[index].superview as? NSStackView)
            let text = try #require(choice.arrangedSubviews[1] as? NSStackView)
            let details = try #require(text.arrangedSubviews.last as? NSStackView)
            let avatar = try #require(details.arrangedSubviews.first)
            sheet.selectNextMeeting(at: meetings.count)
            try click(avatar, at: NSPoint(x: avatar.bounds.midX, y: avatar.bounds.midY))
            #expect(sheet.options?.minutesPath == meetings[index].minutesPath)
            sheet.selectNextMeeting(at: meetings.count)
            try click(choice, at: NSPoint(x: choice.bounds.maxX - 1, y: choice.bounds.midY))
            #expect(sheet.options?.minutesPath == meetings[index].minutesPath)
            // 丸のイベントは標準のラジオへ届く。
            let radio = sheet.nextButtons[index]
            let point = choice.convert(NSPoint(x: radio.bounds.midX, y: radio.bounds.midY), from: radio)
            #expect(choice.hitTest(choice.convert(point, to: choice.superview)) === radio)
            sheet.selectNextMeeting(at: meetings.count)
            radio.performClick(nil)
            #expect(sheet.options?.minutesPath == meetings[index].minutesPath)
        }
        sheet.nextButtons.last?.performClick(nil)
        #expect(sheet.options?.minutesPath == nil && sheet.selectedSlot == 2)
        sheet.close()
    }

    @Test func 乗せた行だけに薄墨の削除ボタンが出て押してもその行を選ばない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try ["定例", "相談"].map { title in
            let path = root.appendingPathComponent("\(title).md")
            try Data("# \(title)の議事録\n".utf8).write(to: path)
            return try NextMeeting(minutesPath: path.path, ai: title == "定例" ? "議事録" : "相談")
        }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: meetings)
        defer { sheet.close() }
        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()
        let row = try #require(sheet.nextButtons[1].superview)
        let button = sheet.nextRemoveButtons[1]
        let titleFrame = sheet.nextTitles[1].frame
        let windowFrame = sheet.window.frame
        #expect(sheet.nextRemoveButtons.allSatisfy { $0.isHidden })
        let enter = try hoverEvent(on: sheet, type: .mouseEntered)
        row.mouseEntered(with: enter)
        content.layoutSubtreeIfNeeded()
        #expect(sheet.nextRemoveButtons[0].isHidden && !button.isHidden)
        #expect(button.image != nil && button.contentTintColor == Washi.muted && !button.isBordered)
        #expect(button.toolTip == "この予約を削除" && button.accessibilityLabel() == "この予約を削除")
        #expect(button.alignmentRect(forFrame: button.frame).size == NSSize(width: 16, height: 16))
        #expect(sheet.nextTitles[1].frame == titleFrame && sheet.window.frame == windowFrame)
        try capture("next-remove-hover", sheet)
        row.mouseExited(with: try hoverEvent(on: sheet, type: .mouseExited))
        #expect(button.isHidden)
        row.mouseEntered(with: enter)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: row.superview)
        let hit = try #require(row.hitTest(point) as? NSButton)
        #expect(hit === button)
        var removed: [UUID] = []
        sheet.onRemoveNextMeeting = { removed.append($0) }
        try sendAction(hit)
        #expect(removed == [meetings[1].id] && sheet.nextMeetings == [meetings[0]])
        #expect(sheet.minutesBox.stringValue == meetings[0].minutesPath && sheet.selectedSlot == 2)
        #expect(sheet.options?.nextMeetingID == meetings[0].id && sheet.nextButtons[0].state == .on)
        #expect(row.superview == nil)
    }

    @Test(arguments: [0, 1, 2])
    func 選択中の予約を消すと残りの先頭で議事録と宛先を埋め直す(_ index: Int) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try (0..<3).map {
            try NextMeeting(minutesPath: root.appendingPathComponent("\($0).md").path,
                            ai: $0 == 0 ? "議事録" : "相談", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: meetings)
        defer { sheet.close() }
        sheet.selectNextMeeting(at: index)
        // 手編集していても、選択中の候補を削除した場合は残りの予約で埋め直す。
        sheet.minutesBox.stringValue = root.appendingPathComponent("手編集.md").path
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        var remaining = meetings
        remaining.remove(at: index)
        try sendAction(sheet.nextRemoveButtons[index])
        #expect(sheet.nextMeetings == remaining && sheet.nextTitles.count == 2 && sheet.nextDetails.count == 2)
        #expect(sheet.nextRemoveButtons.count == 2 && sheet.nextButtons.map(\.tag) == [0, 1, 2])
        #expect(sheet.nextButtons.map(\.state) == [.on, .off, .off])
        #expect(sheet.minutesBox.stringValue == remaining[0].minutesPath)
        #expect(sheet.selectedSlot == (remaining[0].ai == "議事録" ? 2 : 1))
        #expect(sheet.options?.nextMeetingID == remaining[0].id)
        // 削除後に詰め直したラジオと行全体のクリックも、現在の候補を選ぶ。
        sheet.nextButtons[1].performClick(nil)
        #expect(sheet.options?.nextMeetingID == remaining[1].id)
        let firstRow = try #require(sheet.nextButtons[0].superview)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: sheet.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        firstRow.mouseDown(with: click)
        #expect(sheet.options?.nextMeetingID == remaining[0].id)
    }

    @Test(arguments: [false, true])
    func 未選択の予約を消しても選択と手編集と下書きを保持する(_ chooseNone: Bool) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try (0..<3).map {
            try NextMeeting(minutesPath: root.appendingPathComponent("\($0).md").path,
                            ai: "議事録", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: meetings)
        defer { sheet.close() }
        sheet.selectNextMeeting(at: chooseNone ? 3 : 2)
        let editedPath = root.appendingPathComponent("手編集.md").path
        sheet.minutesBox.stringValue = editedPath
        sheet.destination.selectItem(withTag: 1); sheet.destinationChanged()
        sheet.editor.string = "手で直した依頼"; sheet.interval.selectItem(withTag: 3)
        try sendAction(sheet.nextRemoveButtons[0])
        #expect(sheet.nextMeetings == Array(meetings.dropFirst()))
        #expect(sheet.minutesBox.stringValue == editedPath && sheet.selectedSlot == 1)
        #expect(sheet.editor.string == "手で直した依頼" && sheet.interval.selectedTag() == 3)
        #expect(sheet.nextButtons.map(\.state) == (chooseNone ? [.off, .off, .on] : [.off, .on, .off]))
        try sendAction(sheet.nextRemoveButtons[0])
        #expect(sheet.nextMeetings == [meetings[2]])
        #expect(sheet.nextButtons.map(\.state) == (chooseNone ? [.off, .on] : [.on, .off]))
        #expect(sheet.minutesBox.stringValue == editedPath && sheet.editor.string == "手で直した依頼")
    }

    @Test func 最後まで候補を消すと次の会議行に指定しないだけを残す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try (0..<3).map {
            try NextMeeting(minutesPath: root.appendingPathComponent("\($0).md").path,
                            ai: "相談", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: meetings)
        defer { sheet.close() }
        let choices = try #require(sheet.nextButtons.last?.superview as? NSStackView)
        let row = try #require(choices.superview as? NSStackView)
        for _ in meetings {
            try sendAction(sheet.nextRemoveButtons[0])
            #expect(sheet.window.attachedSheet == nil && sheet.minutesHintText.isEmpty)
        }
        #expect(sheet.nextMeetings.isEmpty && sheet.nextRemoveButtons.isEmpty && sheet.nextTitles.isEmpty)
        #expect(choices.arrangedSubviews.count == 1 && row.superview != nil)
        #expect((row.arrangedSubviews.first as? NSTextField)?.stringValue == "次の会議")
        #expect(sheet.nextButtons.count == 1 && sheet.nextButtons[0].title == "指定しない")
        #expect(sheet.nextButtons[0].state == .on && sheet.minutesBox.stringValue.isEmpty)
        #expect(sheet.selectedSlot == 2 && sheet.options?.nextMeetingID == nil)
        try capture("next-remove-last", sheet)
    }

    private func hoverEvent(on sheet: StartSheet, type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    /// ヒットしたボタンのtarget/actionを検証する。削除でボタン自身が取り除かれるので、
    /// 一括テストのイベント処理を巻き込むperformClickの押下演出は再生しない。
    private func sendAction(_ button: NSButton) throws {
        let action = try #require(button.action)
        #expect(button.sendAction(action, to: button.target))
    }

    @Test func 次の会議の指定しないと仕切り線の間に上下と同じ余白を保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try ["定例", "相談"].map { title in
            let path = root.appendingPathComponent("\(title).md")
            try Data("# \(title)の議事録\n".utf8).write(to: path)
            return try NextMeeting(minutesPath: path.path, ai: title == "定例" ? "議事録" : "相談")
        }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: meetings)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        func checkPadding() throws {
            let content = try #require((sheet.window.contentView as? NSScrollView)?.documentView)
            content.layoutSubtreeIfNeeded()
            let choices = try #require(sheet.nextButtons.last?.superview)
            let row = try #require(choices.superview as? NSStackView)
            let rows = try #require(row.superview as? NSStackView)
            let none = try #require(sheet.nextButtons.last)
            let separator = rows.arrangedSubviews[1]
            let bottomGap = none.convert(none.bounds, to: content).minY - separator.convert(separator.bounds, to: content).maxY
            let topGap = row.convert(row.bounds, to: content).maxY - choices.convert(choices.bounds, to: content).maxY
            #expect(abs(bottomGap - 10) < 0.5)
            #expect(abs(topGap - bottomGap) < 0.5)
        }
        try checkPadding()
        sheet.present(on: parent)
        try checkPadding()
        try capture("next-two-sheet", sheet)
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        try checkPadding()
        sheet.destination.selectItem(withTag: 2); sheet.destinationChanged()
        try checkPadding()
        sheet.close()
    }

    @Test func 候補と指定しないと全宛先とエラー表示でシートの高さと上端が変わらない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let screen = try #require(NSScreen.main)
        let meetings = try ["議事録", "送らない"].map {
            try NextMeeting(minutesPath: root.appendingPathComponent("\($0).md").path,
                            ai: $0 == "議事録" ? $0 : nil)
        }
        let parent = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 400,
                                                  y: screen.visibleFrame.maxY - 260,
                                                  width: 800, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.orderFront(nil)
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: meetings)
        defer { sheet.close(); parent.orderOut(nil) }
        sheet.present(on: parent)
        try await Task.sleep(for: .milliseconds(300))
        #expect(parent.attachedSheet === sheet.window && sheet.window.sheetParent === parent)
        let initial = sheet.window.frame
        let scroll = try #require(sheet.window.contentView as? NSScrollView)
        let document = try #require(scroll.documentView)
        try capture("fixed-height-next-two", sheet)
        for _ in 0..<2 {
            for index in 0...2 {
                sheet.selectNextMeeting(at: index)
                try await Task.sleep(for: .milliseconds(100))
                #expect(sheet.window.frame == initial)
            }
        }
        sheet.selectNextMeeting(at: 0)
        for slot in [0, 1, 2] {
            sheet.destination.selectItem(withTag: slot); sheet.destinationChanged()
            try await Task.sleep(for: .milliseconds(100))
            #expect(sheet.window.frame == initial)
            #expect(document.frame.height <= scroll.contentSize.height)
            #expect(!scroll.hasVerticalScroller)
            if slot == 0 { try capture("fixed-height-send-none", sheet) }
        }
        sheet.showMinutesHint("議事録は絶対パスの.mdを指定してください")
        sheet.editor.string = String(repeating: "長いプロンプト\n", count: 100)
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        try await Task.sleep(for: .milliseconds(100))
        #expect(sheet.window.frame == initial)
        #expect(document.frame.height <= scroll.contentSize.height)
        sheet.setMinutesPath("/手入力.md")
        #expect(sheet.window.frame == initial)
        // 実シートの候補を最後まで削除しても、初回に確保した高さと上端は維持する。
        let documentHeight = document.frame.height
        for _ in meetings {
            try sendAction(sheet.nextRemoveButtons[0])
            try await Task.sleep(for: .milliseconds(100))
            #expect(sheet.window.frame == initial && document.frame.height == documentHeight)
        }
        #expect(sheet.nextButtons.count == 1 && sheet.nextButtons[0].state == .on)
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        sheet.showMinutesHint("絶対パスの.mdファイルを指定してください")
        #expect(sheet.window.frame == initial)
    }

    @Test func 表示前に画面を超える本文でもシート高を固定してスクロールできる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let screen = try #require(NSScreen.main)
        let parent = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 400,
                                                  y: screen.visibleFrame.minY + 180,
                                                  width: 800, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.orderFront(nil)
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion())
        defer { sheet.close(); parent.orderOut(nil) }
        // 大きい画面でも必ず高さの上限を検証する。表示前に自然な本文高を増やす。
        let scroll = try #require(sheet.window.contentView as? NSScrollView)
        let document = try #require(scroll.documentView as? NSStackView)
        let extra = NSView()
        extra.heightAnchor.constraint(equalToConstant: screen.visibleFrame.height).isActive = true
        document.insertArrangedSubview(extra, at: document.arrangedSubviews.count - 1)
        sheet.present(on: parent)
        try await Task.sleep(for: .milliseconds(300))
        let initial = sheet.window.frame
        sheet.destination.selectItem(withTag: 2); sheet.destinationChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sheet.window.sheetParent === parent)
        #expect(sheet.window.frame == initial)
        #expect(scroll.contentSize.height <= screen.visibleFrame.height - 40)
        #expect(scroll.hasVerticalScroller)
        #expect(document.frame.height > scroll.contentView.bounds.height)
        #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) < 0.5)
        try capture("screen-limited-top", sheet)
        let actions = sheet.startButton.convert(sheet.startButton.bounds, to: document)
        document.scroll(NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.maxY < document.bounds.maxY)
        #expect(scroll.documentVisibleRect.contains(actions))
        try capture("screen-limited-bottom", sheet)
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sheet.window.frame == initial && scroll.hasVerticalScroller)
    }

    @Test func シート外の親へのクリックは取消だけに使い録音を始めない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion())
        defer { sheet.close(); parent.orderOut(nil) }
        var starts = 0, cancels = 0
        sheet.onStart = { _ in starts += 1 }
        sheet.onCancel = { cancels += 1 }
        sheet.present(on: parent)
        sheet.present(on: parent)
        #expect(parent.sheets.count == 1 && !parent.ignoresMouseEvents)
        let window = try #require(sheet.window as? AIQuestionWindow)
        let inside = try mouseEvent(on: sheet.window, screenPoint: NSPoint(x: window.frame.midX, y: window.frame.midY))
        #expect(window.handleOutsideClick(inside) === inside)
        let covered = try mouseEvent(on: parent, screenPoint: NSPoint(x: window.frame.midX, y: window.frame.midY))
        #expect(window.handleOutsideClick(covered) === covered)
        let outside = try mouseEvent(on: parent, screenPoint: NSPoint(x: window.frame.minX - 10, y: window.frame.midY))
        #expect(window.handleOutsideClick(outside) == nil)
        #expect(cancels == 1 && starts == 0)
        #expect(parent.attachedSheet == nil && !sheet.window.isVisible && !window.monitorsOutsideClicks)
        #expect(window.handleOutsideClick(outside) === outside)
        #expect(cancels == 1)
    }

    @Test func シートで改行と開始と取消を保ち開始後のTaskが動く() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        defer { sheet.close(); parent.orderOut(nil) }
        var starts = 0, cancels = 0, taskRan = false
        sheet.onStart = { _ in starts += 1; Task { @MainActor in taskRan = true } }
        sheet.onCancel = { cancels += 1 }
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: sheet.window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        sheet.present(on: parent)
        sheet.window.makeFirstResponder(sheet.editor)
        sheet.editor.string = "議事録"; sheet.editor.setSelectedRange(NSRange(location: 3, length: 0))
        sheet.window.sendEvent(try key(36, "\r"))
        #expect(sheet.editor.string == "議事録\n" && starts == 0)
        sheet.window.sendEvent(try key(36, "\r", .command))
        try await Task.sleep(for: .milliseconds(50))
        #expect(starts == 1 && taskRan && !sheet.window.isVisible)
        sheet.present(on: parent)
        sheet.window.makeFirstResponder(sheet.startButton)
        sheet.window.sendEvent(try key(36, "\r"))
        #expect(starts == 2)
        sheet.present(on: parent)
        sheet.window.sendEvent(try key(53, "\u{1b}"))
        #expect(cancels == 1 && starts == 2)
    }

    @Test func ファイル選択パネル中は親の外側クリックでも開始シートを閉じない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion())
        defer { sheet.close(); parent.orderOut(nil) }
        sheet.present(on: parent)
        // NSOpenPanelのXPCサービスはswift testを途中終了させるため、同じ
        // シート機構で開始シートに付くパネルへの入力と取消を確認する。
        let panel = AIQuestionWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        var cancelled = false
        panel.onDismiss = { sheet.window.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
        sheet.window.beginSheet(panel) { cancelled = $0 == .cancel }
        #expect(panel.sheetParent === sheet.window)
        #expect(!parent.ignoresMouseEvents)
        var starts = 0, cancels = 0
        sheet.onStart = { _ in starts += 1 }; sheet.onCancel = { cancels += 1 }
        let outside = try mouseEvent(on: parent, screenPoint: NSPoint(x: sheet.window.frame.minX - 10, y: sheet.window.frame.midY))
        let window = try #require(sheet.window as? AIQuestionWindow)
        #expect(window.handleOutsideClick(outside) === outside)
        #expect(cancels == 0 && starts == 0 && sheet.window.isVisible)
        sheet.focus()
        #expect(sheet.window.attachedSheet === panel)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(cancelled && sheet.minutesBox.stringValue.isEmpty && sheet.window.isVisible)
        #expect(window.handleOutsideClick(outside) == nil)
        #expect(cancels == 1 && starts == 0 && !sheet.window.isVisible)
    }

    private func mouseEvent(on window: NSWindow, screenPoint: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func 送らないで開いても全宛先の高さを確保し再表示で下書きを失わない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion())
        defer { sheet.close(); parent.orderOut(nil) }
        sheet.destination.selectItem(withTag: 1); sheet.destinationChanged()
        sheet.editor.string = "保存する下書き"
        sheet.interval.selectItem(withTag: 3)
        sheet.work.state = .off; sheet.final.state = .off
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        sheet.present(on: parent)
        try await Task.sleep(for: .milliseconds(300))
        let initial = sheet.window.frame
        #expect(sheet.selectedSlot == nil && sheet.editor.string == "保存する下書き")
        for slot in [2, 1] {
            sheet.destination.selectItem(withTag: slot); sheet.destinationChanged()
            try await Task.sleep(for: .milliseconds(100))
            #expect(sheet.window.frame == initial)
        }
        #expect(sheet.editor.string == "保存する下書き")
        #expect(sheet.interval.selectedTag() == 3 && sheet.work.state == .off && sheet.final.state == .off)
        sheet.close()
        sheet.present(on: parent)
        #expect(sheet.editor.string == "保存する下書き" && sheet.selectedSlot == 1)
        #expect(sheet.interval.selectedTag() == 3 && sheet.work.state == .off && sheet.final.state == .off)
    }

    @Test func 送らないからボード宛先へ戻してもプロンプトは読取専用を保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try profiles(root, toml: "[[ai]]\nboard = \"## ボード\"\nautoStart = true"),
                               diarizationEnabled: true, exclusion: AudioExclusion())
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        #expect(!sheet.editor.isEditable && !sheet.editor.isSelectable)
        sheet.destination.selectItem(withTag: 1); sheet.destinationChanged()
        #expect(!sheet.editor.isEditable && sheet.editor.isSelectable)
        #expect(sheet.aiDetails.alphaValue == 1 && sheet.interval.isEnabled)
    }

    /// 検証用の撮影。モックとの突き合わせに使い、通常のテストでは何もしない。
    private func capture(_ name: String, _ sheet: StartSheet) throws {
        guard let directory = ProcessInfo.processInfo.environment["KIKIGAKI_START_SHEET_CAPTURE"],
              let scroll = sheet.window.contentView as? NSScrollView,
              let view = scroll.documentView else { return }
        view.layoutSubtreeIfNeeded()
        // スクロールビュー越しのキャッシュでは、入れ子のプロンプト欄のクリップがずれる。
        // 本文の可視範囲を直接撮り、画面内に収めた高さも画像へ反映する。
        let bounds = scroll.documentVisibleRect
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct StartSheetScheduleTests {
    /// 開始シートの値で自動送信を始める。設定の `autoStart` は使わない。
    @Test func シートの宛先と依頼で自動送信を始める() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"

        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        autoStart = true
        autoPrompt = "設定の依頼"
        """), home: root).aiProfiles
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
                                     config: config, aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.setScheduleTranscriptForTesting("開始時の発話")
        session.pendingAutomaticSchedule = .init(slot: 1, options: try AIScheduleOptions(prompt: "シートの依頼", interval: 120))
        session.startAutomaticSchedule()
        #expect(session.snapshot.aiSchedule.active)
        #expect(session.aiScheduleConfiguration?.name == "相談")
        #expect(session.lastScheduleOptions?.prompt == "シートの依頼")
        #expect(session.lastScheduleOptions?.interval == 120)
        await session.submissionTaskForTesting?.value
        session.stopAISchedule()
    }

    /// 「送らない」を選んだ会議では、設定に `autoStart` があっても始めない。
    @Test func シートで送らないを選ぶと設定のautoStartでも始めない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        autoStart = true
        autoPrompt = "設定の依頼"
        """), home: root).aiProfiles
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
                                     config: config, aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.pendingAutomaticSchedule = .init(slot: nil, options: nil)
        session.startAutomaticSchedule()
        #expect(!session.snapshot.aiSchedule.active)
        // 指定は1回だけ効き、次の会議へは持ち越さない。
        session.startAutomaticSchedule()
        #expect(session.snapshot.aiSchedule.active)
        session.stopAISchedule()
    }

    /// 開始シートの議事録は表示中の会議へ当てず、次の録音の準備で引き継ぐ。
    @Test func 開始シートの議事録は次の会議へ持ち越す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let records = AIRecordStore(directory: root)
        let session = MeetingSession(config: ResolvedConfig(config: KikigakiConfig(), home: root),
                                     models: { throw CancellationError() }, log: { _ in }, aiStore: records)
        session.setMinutesPreparationForTesting()
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("first.md"))
        try session.prepareMinutes("/tmp/次の会議.md")
        // 表示中の会議には当たらない。次の準備で待機指定へ移る。
        #expect(try session.previewMinutesStore()?.state.humanMinutesPath == nil)
        #expect(session.waitingMinutesPath == nil)
        session.setMinutesPreparationForTesting()
        #expect(session.waitingMinutesPath == "/tmp/次の会議.md")
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("second.md"))
        #expect(try session.previewMinutesStore()?.state.humanMinutesPath == "/tmp/次の会議.md")
        #expect(throws: (any Error).self) { try session.prepareMinutes("relative.md") }
    }
}
