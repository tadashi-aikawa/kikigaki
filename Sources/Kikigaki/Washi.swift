import AppKit

/// 和紙の帳面。配色はここだけに定義する。
enum Washi {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let paper = color(0xF5EAD9)
    static let shade = color(0xEDE0CD)
    static let rule = color(0xD5C6B1)
    static let ink = color(0x221F1C)
    static let muted = color(0x6B6157)
    static let tentative = color(0x4A443D)
    static let red = color(0xAA1405)
    static let brightRed = color(0xCF321F)
    static let white = NSColor.white
    static let gold = color(0xC4801F)
    static let searchMatch = color(0xE09C3C).withAlphaComponent(0.25)
    static let searchCurrent = color(0xE09C3C).withAlphaComponent(0.6)
    struct SpeakerColor { let background: NSColor; let foreground: NSColor }
    /// AI参加者の色。話者枡の4色とは別に固定し、4人喋る会議で人と同色にならないようにする。
    /// 宛先が複数あってもこの1色のままにし、名前で区別する。
    static let ai = SpeakerColor(background: color(0x2F4A7A), foreground: paper)
    static let slots = [SpeakerColor(background: red, foreground: paper),
                        SpeakerColor(background: color(0xC4801F), foreground: ink),
                        SpeakerColor(background: color(0x514A43), foreground: paper),
                        SpeakerColor(background: color(0x3E706C), foreground: paper)]
    static func speakerColor(for slot: Int?) -> SpeakerColor {
        guard let slot, slot >= 0 else { return SpeakerColor(background: muted, foreground: paper) }
        // パレットはエンジンの枡数とは独立。5枡目以降の色はここへ足せる。
        // 未定義の枡も、黙って不明話者の色にせず既存の色を循環させる。
        return slots[slot % slots.count]
    }
    static let logo: NSImage? = {
        if let url = Bundle.main.url(forResource: "kikigaki", withExtension: "icns") { return NSImage(contentsOf: url) }
        // swift run用。配布アプリはmake-app.sh同梱の同じロゴを使う。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: root.appendingPathComponent("Resources/kikigaki.png"))
    }()
    static func logoView(size: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = logo
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("KIKIGAKI")
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }
    static func surface(_ view: NSView, color: NSColor = shade) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }
    static func label(_ text: String = "", size: CGFloat = 12, color: NSColor = ink,
                      weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
}
