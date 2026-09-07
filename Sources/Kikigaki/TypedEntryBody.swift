import AppKit

/// NSTextFieldはリンクの描画色を上書きするため、手入力の本文はTextKit 1で表示する。
/// 色指定・選択・検索強調を同じtextStorageに載せ、スクロールは会話全体へ任せる。
final class TypedEntryBody: NSTextView {
    init() {
        let storage = NSTextStorage(), manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false; container.heightTracksTextView = false
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true
        allowsUndo = false; drawsBackground = false
        isHorizontallyResizable = false; isVerticallyResizable = false
        textContainerInset = NSSize(width: 2, height: 0)
        linkTextAttributes = [.foregroundColor: Washi.red, .underlineStyle: NSUnderlineStyle.single.rawValue]
        setAccessibilityLabel("手入力の本文")
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(for width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 20 }
        container.containerSize = NSSize(width: max(1, width - 4), height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).maxY)
    }
}
