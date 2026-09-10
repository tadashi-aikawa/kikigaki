import AppKit

/// シートと宛先メニューで共通の、紫のイニシャルを持つ20ptアバター。
@MainActor enum AIProfileAvatar {
    static func image(name: String, source: String?, store: AvatarStore) -> NSImage {
        let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 25, height: 26))
        avatar.accent = Washi.ai
        avatar.initial = String(name.prefix(1))
        avatar.image = store.image(for: source)
        let image = NSImage(size: avatar.bounds.size, flipped: true) { rect in
            avatar.draw(rect)
            return true
        }
        image.size = NSSize(width: 20, height: 21)
        return image
    }
}
