import AppKit
import ImageIO
import KikigakiCore

/// 発言の行の右に置く画像レーンの中身。割り当てと畳み方はCoreの `ScreenLane` が決め、ここは描くだけ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「表示」
///
/// 行の不透明度(未確定・小音量の除外)の外に置く。画像は声の確定や除外と関係なく保存されるため。
final class ScreenLaneView: NSView {
    enum Item: Equatable {
        /// `caption` は共通のディスプレイ名を省いた題。`label` は省く前の見出しで、ツールチップに出す。
        case image(path: String, time: String, caption: String, label: String)
        case event(time: String, text: String)
        case folded(paths: [String])
        /// 開いた間の画像の頭に置く「畳む」。「+N枚」と同じ位置・同じ見た目で、文言だけが替わる。
        case collapse(paths: [String])
    }

    /// レーンの幅。発言の列はこの分だけウィンドウを広げて保つ。
    static let width: CGFloat = 180
    /// サムネイルの枠。文字の倍率を掛けない。16:9の画面を枠いっぱいに出し、ほかの縦横比は枠の中へ収める。
    nonisolated static let thumbnail = NSSize(width: 152, height: 86)
    /// 枠と枠の間。題の行と次のサムネイルを離して、どの題がどの画像かを読み分ける。
    static let spacing: CGFloat = 10

    override var isFlipped: Bool { true }
    var onOpen: ((String) -> Void)?
    /// 「+N枚」と「畳む」を押した。押したボタンも渡し、並べ直した後に入れ替わるボタンを同じ位置へ置くのに使う。
    var onToggle: ((ScreenLaneFoldButton) -> Void)?
    private(set) var items: [Item] = []
    private(set) var textScale: CGFloat = 1
    private var blocks: [(item: Item, views: [NSView], height: CGFloat)] = []
    /// イベントの行は3行まで折り返す。撮れなかった理由は倍率を上げても読めるようにする。
    /// 画像の題は1行で末尾を省く。全文はツールチップで読め、サムネイルの縦の並びを崩さないため。
    static let eventLines = 3

    var isEmpty: Bool { items.isEmpty }
    private var lineHeight: CGFloat { ceil(15 * textScale) }
    var contentHeight: CGFloat {
        blocks.isEmpty ? 0 : blocks.map(\.height).reduce(0, +) + Self.spacing * CGFloat(blocks.count - 1)
    }

    func update(_ items: [Item]) {
        guard items != self.items else { return }
        self.items = items
        rebuild()
    }
    func setTextScale(_ scale: CGFloat) {
        guard scale != textScale else { return }
        textScale = scale
        rebuild()
    }
    private func rebuild() {
        blocks.flatMap(\.views).forEach { $0.removeFromSuperview() }
        blocks = items.map { item in
            let views: [NSView]
            let height: CGFloat
            switch item {
            case let .image(path, time, caption, label):
                let thumbnail = ScreenThumbnailView(path: path)
                thumbnail.toolTip = "\(time) \(label)"
                thumbnail.setAccessibilityLabel("画面 \(time) \(label)")
                thumbnail.onClick = { [weak self] in self?.onOpen?(path) }
                views = [thumbnail, captionLabel(time: time, text: caption, tooltip: "\(time) \(label)", lines: 1)]
                height = Self.thumbnail.height + 3 + lineHeight
            case let .event(time, text):
                let label = captionLabel(time: time, text: text, tooltip: "\(time) \(text)", lines: Self.eventLines)
                let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.thumbnail.width,
                                                                      height: .greatestFiniteMagnitude)).height ?? lineHeight
                views = [label]
                height = min(CGFloat(Self.eventLines) * lineHeight, max(lineHeight, ceil(measured)))
            case let .folded(paths):
                let button = ScreenLaneFoldButton(paths: paths, collapses: false, scale: textScale)
                button.onPress = { [weak self, weak button] in if let button { self?.onToggle?(button) } }
                views = [button]
                height = lineHeight + 4
            case let .collapse(paths):
                let button = ScreenLaneFoldButton(paths: paths, collapses: true, scale: textScale)
                button.onPress = { [weak self, weak button] in if let button { self?.onToggle?(button) } }
                views = [button]
                height = lineHeight + 4
            }
            views.forEach(addSubview)
            return (item, views, height)
        }
        needsLayout = true
    }
    private func captionLabel(time: String, text: String, tooltip: String, lines: Int) -> NSTextField {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lines == 1 ? .byTruncatingTail : .byCharWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let value = NSMutableAttributedString(string: time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * textScale, weight: .regular), .foregroundColor: Washi.muted,
            .paragraphStyle: paragraph])
        if !text.isEmpty {
            value.append(NSAttributedString(string: "  " + text, attributes: [
                .font: NSFont.systemFont(ofSize: 11 * textScale), .foregroundColor: Washi.muted, .paragraphStyle: paragraph]))
        }
        let label = lines == 1 ? NSTextField(labelWithAttributedString: value) : NSTextField(wrappingLabelWithString: "")
        if lines != 1 { label.attributedStringValue = value }
        label.maximumNumberOfLines = lines
        label.cell?.truncatesLastVisibleLine = true
        label.toolTip = tooltip
        return label
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for block in blocks {
            switch block.item {
            case .image:
                block.views[0].frame = NSRect(origin: NSPoint(x: 0, y: y), size: Self.thumbnail)
                block.views[1].frame = NSRect(x: 0, y: y + Self.thumbnail.height + 3, width: bounds.width, height: lineHeight)
            case .event:
                block.views[0].frame = NSRect(x: 0, y: y, width: bounds.width, height: block.height)
            case .folded, .collapse:
                let button = block.views[0]
                button.frame = NSRect(x: -2, y: y, width: min(bounds.width, button.intrinsicContentSize.width + 4),
                                      height: block.height)
            }
            y += block.height + Self.spacing
        }
    }
    /// 「+N枚」と「畳む」。開閉の後に入れ替わる相手をパスで探すのに使う。
    var foldButtons: [ScreenLaneFoldButton] { blocks.flatMap(\.views).compactMap { $0 as? ScreenLaneFoldButton } }
#if DEBUG
    var thumbnailViews: [ScreenThumbnailView] { blocks.flatMap(\.views).compactMap { $0 as? ScreenThumbnailView } }
    var captionTexts: [String] { blocks.flatMap(\.views).compactMap { ($0 as? NSTextField)?.stringValue } }
#endif
}

/// 間の画像を開く「+N枚」と、開いた後の「畳む」。どちらも同じ位置に薄墨の文字だけで出す。
/// アイコンは付けない。送信文の引用の開閉と同じく、文字と押せることを示すホバーの背景だけにする。
final class ScreenLaneFoldButton: HoverButton {
    var onPress: (() -> Void)?
    /// 開く・畳む対象の画像のパス。
    let paths: [String]
    /// 「畳む」なら真、「+N枚」なら偽。
    let collapses: Bool
    init(paths: [String], collapses: Bool, scale: CGFloat) {
        self.paths = paths; self.collapses = collapses
        let title = collapses ? "畳む" : "+\(paths.count)枚"
        let help = collapses ? "間の\(paths.count)枚を畳む" : "間の\(paths.count)枚を開く"
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: Washi.muted])
        alignment = .left
        toolTip = help
        setAccessibilityLabel(help)
        target = self; action = #selector(pressed)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { onPress?() }
}

/// 画面の縮小画像を裏のキューで読み、読み終えたらメインスレッドで知らせる。会議をまたいで共有のキャッシュへ置く。
///
/// - 描くときに初めて読む。長い会議でも画面外の画像を読まないため
/// - 読み込みとデコードはメインスレッドで行わない。展開や速いスクロールで何枚も初めて出しても、UIを待たせないため
/// - 同じパスの読み込みが重なれば1回にまとめ、待っている全員へ知らせる
/// - 読めなかった画像も覚え、描くたびに読み直さない
@MainActor final class ScreenThumbnailLoader {
    static let shared = ScreenThumbnailLoader()
    enum State: Equatable { case loaded(NSImage), missing }
    private final class Entry { let image: NSImage?; init(_ image: NSImage?) { self.image = image } }
    private let cache = NSCache<NSString, Entry>()
    private var waiting: [String: [() -> Void]] = [:]
    private let queue = DispatchQueue(label: "kikigaki.screen-thumbnail", qos: .userInitiated)
    private let decode: @Sendable (String) -> CGImage?

    init(decode: @escaping @Sendable (String) -> CGImage? = ScreenThumbnailLoader.decodeFile) {
        self.decode = decode
    }

    /// 画面は1x寸法で保存している。枠の2倍まで縮めて、Retinaでも文字の形が分かる程度に保つ。
    nonisolated static func decodeFile(_ path: String) -> CGImage? {
        CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(ScreenLaneView.thumbnail.width * 2),
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary)
        }
    }

    /// 読めていればその状態、まだならnilを返し、読み終えたら `whenLoaded` を呼ぶ。待たない。
    func image(at path: String, whenLoaded: @escaping () -> Void) -> State? {
        if let entry = cache.object(forKey: path as NSString) { return entry.image.map(State.loaded) ?? .missing }
        if waiting[path] != nil { waiting[path]?.append(whenLoaded); return nil }
        waiting[path] = [whenLoaded]
        let decode = decode
        queue.async { [weak self] in
            let image = decode(path)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(path, image) } }
        }
        return nil
    }

    private func finish(_ path: String, _ image: CGImage?) {
        cache.setObject(Entry(image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }),
                        forKey: path as NSString)
        for callback in waiting.removeValue(forKey: path) ?? [] { callback() }
    }

    /// 全部を読み終えるまで待つ。撮影とテストで、描く前に画像を揃えるため。
    func preload(_ paths: [String]) async {
        for path in paths {
            await withCheckedContinuation { continuation in
                if image(at: path, whenLoaded: { continuation.resume() }) != nil { continuation.resume() }
            }
        }
    }
}

/// 画面の1枚。枠の中へ縦横比を保って収め、画像の輪郭に罫を引く。押すとQuick Lookで原寸を開く。
/// 縮小画像は `ScreenThumbnailLoader` が裏で読む。読み終えるまでは罫の枠だけを描き、枠の大きさは変えない。
final class ScreenThumbnailView: NSView {
    let path: String
    var onClick: (() -> Void)?
    var loader = ScreenThumbnailLoader.shared
    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let state = loader.image(at: path) { [weak self] in self?.needsDisplay = true }
        guard case let .loaded(image) = state, image.size.width > 0, image.size.height > 0 else {
            // 読み込み中と読めない画像は罫の枠だけにする。読めない画像は、押せば保存先のパスをQuick Lookが案内する。
            Washi.rule.setStroke()
            let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.25, dy: 0.25))
            frame.lineWidth = 0.5
            frame.stroke()
            return
        }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        Washi.rule.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25))
        outline.lineWidth = 0.5
        outline.stroke()
    }
}

/// 後ろに発言がまだ無い画面を出す末尾の行。発言の列は空のまま、レーンだけを持つ。
/// 次の発言が届けば、その画面は発言の横へ移り、この行は消える。
final class ScreenLaneRow: NSView, DocumentRow {
    let lane = ScreenLaneView()
    override var isFlipped: Bool { true }
    var spansLane: Bool { true }
    init() {
        super.init(frame: .zero)
        addSubview(lane)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(for width: CGFloat) -> CGFloat { lane.isEmpty ? 0 : 8 + lane.contentHeight + 8 }
    override func layout() {
        super.layout()
        lane.frame = ScreenLaneView.frame(in: bounds, height: lane.contentHeight)
    }
}

extension ScreenLaneView {
    /// 行の中のレーンの位置。上端は発言の名前の行に揃え、右端はスクローラーの分を空ける。
    static func frame(in bounds: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: bounds.width - width + 8, y: 8, width: thumbnail.width, height: height)
    }
}
