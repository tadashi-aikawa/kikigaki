import AppKit

@MainActor
enum ApplicationMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "KIKIGAKI")
        application.submenu?.addItem(NSMenuItem(title: "KIKIGAKIを終了",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.addItem(application)

        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "編集")
        // accessoryアプリにも編集キーの定義が必要。targetを指定せず、
        // シートのフィールドエディタや本文の選択へ標準の経路で送る。
        for (title, action, key) in [
            ("切り取り", #selector(NSText.cut(_:)), "x"),
            ("コピー", #selector(NSText.copy(_:)), "c"),
            ("ペースト", #selector(NSText.paste(_:)), "v"),
            ("すべてを選択", #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            edit.submenu?.addItem(item)
        }
        menu.addItem(edit)
        edit.submenu?.addItem(.separator())
        for (title, action, key, modifiers) in [
            ("検索…", #selector(TranscriptWindowController.kikigakiShowSearch(_:)), "f", NSEvent.ModifierFlags.command),
            ("次を検索", #selector(TranscriptWindowController.kikigakiFindNext(_:)), "g", NSEvent.ModifierFlags.command),
            ("前を検索", #selector(TranscriptWindowController.kikigakiFindPrevious(_:)), "G", NSEvent.ModifierFlags([.command, .shift]))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.submenu?.addItem(item)
        }
        let view = NSMenuItem()
        view.submenu = NSMenu(title: "表示")
        view.submenu?.addItem(NSMenuItem(title: "議事録を表示", action: #selector(TranscriptWindowController.toggleMinutes), keyEquivalent: ""))
        view.submenu?.addItem(.separator())
        for (title, action, key) in [
            ("文字を大きく", #selector(TranscriptWindowController.increaseTextSize(_:)), "+"),
            ("文字を小さく", #selector(TranscriptWindowController.decreaseTextSize(_:)), "-"),
            ("実際のサイズ", #selector(TranscriptWindowController.resetTextSize(_:)), "0")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.allowsAutomaticKeyEquivalentLocalization = false
            view.submenu?.addItem(item)
        }
        // USの=とJISの;はShiftなしでも拡大する。表示する項目は⌘+の1つだけ。
        for key in ["=", ";"] {
            let alias = NSMenuItem(title: "文字を大きく", action: #selector(TranscriptWindowController.increaseTextSize(_:)), keyEquivalent: key)
            alias.keyEquivalentModifierMask = .command
            alias.allowsAutomaticKeyEquivalentLocalization = false
            alias.isHidden = true
            alias.allowsKeyEquivalentWhenHidden = true
            view.submenu?.addItem(alias)
        }
        menu.addItem(view)
        return menu
    }
}
