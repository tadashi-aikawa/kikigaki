import AppKit
import KikigakiCore

extension NSAttributedString.Key {
    /// 箇条書きの行頭のラベルの字に付ける印。値は `BulletLabelStyle.Mark`。塗りは `BulletLabelLayoutManager` が描く。
    static let markdownBulletLabel = NSAttributedString.Key("KikigakiMarkdownBulletLabel")
    /// ラベルの後ろの見せない `:` に付ける印。コロンから始まる選択を写すときにも見つけられるようにする。
    static let markdownBulletLabelColon = NSAttributedString.Key("KikigakiMarkdownBulletLabelColon")
}

/// 箇条書きの行頭の「ラベル: 」の見た目(判定は `MarkdownBulletLabel`)。
///
/// 1段目は**墨の塗りに和紙の色で抜いた字**、2段目以降は**淡い塗りに本文の字の色**。parliamentの
/// 灰の塗り・白抜き・子だけ淡い塗りの考え方を、既存の `Washi` の色で写す。灰の系統の `muted` は
/// 箇条書きの記号・引用と同じ色で、朱・金・紫の意味の色を使わない。
/// 子を淡くするのは、親だけを縦に拾うときに子の塗りで目が止まらないため。
///
/// `:` は字として残し、大きさを潰して透明にする。選んでコピーした文字列は `理由: …` のまま。
/// 太字・背景色の付いた行内コードとは、角丸の塗りと抜いた字で見分ける。
enum BulletLabelStyle {
    final class Mark: NSObject {
        let nested: Bool
        let long: Bool
        init(nested: Bool, long: Bool) { self.nested = nested; self.long = long }
    }

    /// 本文の字に対するラベルの字の大きさ。parliamentの0.86em
    static let fontRatio: CGFloat = 0.86
    /// 塗りの左右の余白。ラベルの字の0.45em
    static func padding(base: CGFloat) -> CGFloat { base * fontRatio * 0.45 }

    static func fill(nested: Bool) -> NSColor {
        nested ? Washi.paper.blended(withFraction: 0.24, of: Washi.muted) ?? Washi.shade : Washi.muted
    }

    /// 描いた直後のラベルの字とその後ろの `:` に見た目を付ける。字そのものは変えない。
    static func apply(to text: NSMutableAttributedString, at location: Int, length: Int, nested: Bool, long: Bool) {
        let size = (text.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 15
        text.addAttributes([
            .font: NSFont.systemFont(ofSize: size * fontRatio, weight: .semibold),
            .foregroundColor: nested ? Washi.ink : Washi.paper,
            .markdownBulletLabel: Mark(nested: nested, long: long)
        ], range: NSRange(location: location, length: length))
        text.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear,
                            .markdownBulletLabelColon: true],
                           range: NSRange(location: location + length, length: 1))
    }

    /// リッチテキストへ写す文字列。塗りは字の属性でないので写らず、抜いた字の色と潰した `:` だけが残る。
    /// ラベルの字を本文の字の色に、`:` をラベルと同じ大きさに戻し、`理由: …` と読める形にする。
    /// 本文全体を直してから選択を切り出すので、ラベルの途中や `:` から始まる選択でも直る。
    static func copyable(_ source: NSAttributedString) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.markdownBulletLabel, in: whole) { value, range, _ in
            guard value is Mark else { return }
            text.removeAttribute(.kern, range: range)
            text.addAttribute(.foregroundColor, value: Washi.ink, range: range)
        }
        text.enumerateAttribute(.markdownBulletLabelColon, in: whole) { value, range, _ in
            guard value != nil, range.location > 0 else { return }
            text.setAttributes(text.attributes(at: range.location - 1, effectiveRange: nil), range: range)
        }
        text.removeAttribute(.markdownBulletLabel, range: whole)
        text.removeAttribute(.markdownBulletLabelColon, range: whole)
        return text
    }

    /// ラベルか見せない `:` を範囲に含むか
    static func touches(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        var found = false
        for key in [NSAttributedString.Key.markdownBulletLabel, .markdownBulletLabelColon] where !found {
            text.enumerateAttribute(key, in: range) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
        }
        return found
    }

    /// 文字の倍率を掛けた後に、字の大きさから塗りの右の余白とラベルの後ろの間を置く。
    /// 字送り(kern)は倍率の対象外なので、倍率を掛ける前に置くと拡大で余白が痩せる。
    static func space(_ text: NSMutableAttributedString) {
        text.enumerateAttribute(.markdownBulletLabel, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value is Mark, range.length > 0,
                  let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            text.addAttribute(.kern, value: font.pointSize * 0.45, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            if NSMaxRange(range) < text.length {
                text.addAttribute(.kern, value: font.pointSize * 0.2, range: NSRange(location: NSMaxRange(range), length: 1))
            }
        }
    }
}

/// ラベルの塗りを字の下に描く。行の高さでなく字の高さに合わせ、角を丸める。
/// 短いラベルは途中で折り返さない。長いラベルは折り返し、行ごとに塗る。
final class BulletLabelLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // 選択の背景は塗りの上へ重ね、選んだことが見えるようにする。
        drawLabels(in: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawLabels(in glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownBulletLabel, in: characters) { value, range, _ in
            guard let mark = value as? BulletLabelStyle.Mark,
                  let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let pad = font.pointSize * 0.45
            BulletLabelStyle.fill(nested: mark.nested).setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, lineGlyphs, _ in
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                // 左の余白は字の前の空き(1行目は本文の開始位置を送った分)へ出す。右の余白は最後の字の字送り。
                // 長いラベルを折り返した途中の行は字送りの余白を持たないので、右の余白を足す。
                let right = NSMaxRange(part) < NSMaxRange(glyphs) ? pad : 0
                let rect = NSRect(x: bounds.minX - pad, y: baseline - font.ascender - 1,
                                  width: bounds.width + pad + right, height: font.ascender - font.descender + 2)
                    .offsetBy(dx: origin.x, dy: origin.y)
                let radius = font.pointSize * 0.31
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    /// 12字までのラベルは1かたまりで描き、折り返しで塗りを割らない。字は変えないので、
    /// コピーで連続した空白も畳まれない。
    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard charIndex > 0, let storage = textStorage, charIndex - 1 < storage.length,
              let mark = storage.attribute(.markdownBulletLabel, at: charIndex - 1, effectiveRange: nil) as? BulletLabelStyle.Mark
        else { return true }
        return mark.long
    }
}
