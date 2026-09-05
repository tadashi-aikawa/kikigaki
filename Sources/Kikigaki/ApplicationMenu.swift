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
            ("検索…", #selector(TranscriptWindowController.showSearch(_:)), "f", NSEvent.ModifierFlags.command),
            ("次を検索", #selector(TranscriptWindowController.findNext(_:)), "g", NSEvent.ModifierFlags.command),
            ("前を検索", #selector(TranscriptWindowController.findPrevious(_:)), "G", NSEvent.ModifierFlags([.command, .shift]))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.submenu?.addItem(item)
        }
        return menu
    }
}
