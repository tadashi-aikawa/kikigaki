import AppKit

/// 開始シート専用。標準ポップアップの選択・キーボード操作を残し、文字の右へ札を描く。
final class StartSheetDestinationButton: NSPopUpButton {
    var showsSpeakerEstimation = false {
        didSet {
            (cell as? StartSheetDestinationCell)?.showsSpeakerEstimation = showsSpeakerEstimation
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero, pullsDown: false)
        let popupCell = StartSheetDestinationCell(textCell: "", pullsDown: false)
        popupCell.usesItemFromMenu = false
        cell = popupCell
        font = .systemFont(ofSize: 13)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class StartSheetDestinationCell: NSPopUpButtonCell {
    var showsSpeakerEstimation = false

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard showsSpeakerEstimation else { return super.drawTitle(title, withFrame: frame, in: controlView) }
        // AppKitから渡るframeは短い題では文字の自然幅しかない。
        // ボタン全体の右端から矢印の24ptを除き、札の置き場を確保する。
        let chip = NSRect(x: controlView.bounds.maxX - 24 - SpeakerEstimationChip.size.width,
                          y: frame.midY - SpeakerEstimationChip.size.height / 2,
                          width: SpeakerEstimationChip.size.width, height: SpeakerEstimationChip.size.height)
        let textFrame = NSRect(x: frame.minX, y: frame.minY,
                               width: max(0, chip.minX - frame.minX - 6), height: frame.height)
        let text = NSMutableAttributedString(attributedString: title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        // 標準セルは短い題を矩形の中央へ置くので、広げた文字枠では左揃えで直接描く。
        text.draw(with: textFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        SpeakerEstimationChip.draw(in: chip)
        return textFrame.union(chip)
    }
}

/// シートの操作部なので倍率を掛けない。ベクターの添付で一覧も同じ札を使う。
enum SpeakerEstimationChip {
    static let text = "話者を推定"
    static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static var size: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12, height: 18)
    }

    static func draw(in rect: NSRect, highlighted: Bool = false) {
        let color = highlighted ? NSColor.selectedMenuItemTextColor : Washi.ai.background
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        color.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(in: NSRect(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2,
                                         width: textSize.width, height: textSize.height), withAttributes: attributes)
    }

    static func attachment(for item: NSMenuItem) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let image = NSImage(size: size, flipped: false) { [weak item] rect in
            draw(in: rect, highlighted: item?.isHighlighted == true)
            return true
        }
        // 強調の切替で前の色の画像を再利用せず、行の状態から毎回描く。
        image.cacheMode = .never
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -4, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    static func truncated(_ text: String, font: NSFont, width: CGFloat) -> String {
        guard (text as NSString).size(withAttributes: [.font: font]).width > width else { return text }
        var prefix = text
        while !prefix.isEmpty {
            prefix.removeLast()
            if ((prefix + "…") as NSString).size(withAttributes: [.font: font]).width <= width { break }
        }
        return prefix + "…"
    }
}
