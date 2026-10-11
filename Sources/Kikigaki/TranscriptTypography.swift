import AppKit

/// 元のフォント属性を保ったまま倍率を掛ける。検索色・リンク・コピー本文は変更しない。
enum TranscriptTypography {
    static func withFont(_ source: NSAttributedString, _ font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func scaled(_ source: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
        guard scale != 1 else { return source }
        let result = NSMutableAttributedString(attributedString: source)
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            result.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale)!, range: range)
        }
        return result
    }
}
