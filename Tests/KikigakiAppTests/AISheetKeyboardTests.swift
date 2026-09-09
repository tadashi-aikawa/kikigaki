import AppKit
import Testing
@testable import Kikigaki

@Suite @MainActor struct AISheetKeyboardTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func enter(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 36) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
        window.sendEvent(event)
    }

    @Test(arguments: [false, true]) func 本文はEnterで改行しCommandEnterだけ一度送信する(automatic: Bool) throws {
        _ = NSApplication.shared
        let ask = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "依頼", voice: "", range: "", tentative: false, canSubmit: true)
        let schedule = AIScheduleSheet(prompt: "依頼", minutes: 3, workAllowed: true)
        let window = automatic ? schedule.window : ask.window
        var sent: [String] = []
        ask.onSubmit = { text, _ in sent.append(text) }; schedule.onStart = { sent.append($0.prompt) }
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AIQuestionEditor }.first)
        window.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        try enter(window); try enter(window, modifiers: .shift)
        #expect(editor.string == "依頼\n\n" && sent.isEmpty)
        #expect(descendants(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("⌘Enterで送信") })
        let button = try #require(descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == (automatic ? "開始" : "送信") })
        #expect(button.keyEquivalentModifierMask == .command)
        try enter(window, modifiers: .command)
        try enter(window, modifiers: .command)
        #expect(sent.count == 1 && sent.first?.contains("依頼") == true)
    }

    @Test(arguments: [NSEvent.ModifierFlags(), .command]) func IME未確定文字があれば送信しない(modifiers: NSEvent.ModifierFlags) throws {
        _ = NSApplication.shared
        let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "", voice: "", range: "", tentative: false, canSubmit: true)
        let editor = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? AIQuestionEditor }.first)
        sheet.window.makeFirstResponder(editor)
        var count = 0; sheet.onSubmit = { _, _ in count += 1 }
        editor.setMarkedText("かくにん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        try enter(sheet.window, modifiers: modifiers)
        #expect(count == 0)
    }

    @Test func テンキーEnterも同じ挙動で編集不可なら送信しない() throws {
        _ = NSApplication.shared
        let editor = AIQuestionEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let window = AIQuestionWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor; window.makeFirstResponder(editor)
        var count = 0; editor.onSubmit = { count += 1 }
        try enter(window, keyCode: 76)
        #expect(editor.string == "\n" && count == 0)
        try enter(window, modifiers: .command, keyCode: 76)
        #expect(count == 1)
        editor.isEditable = false
        try enter(window, modifiers: .command)
        #expect(count == 1)
    }
}
