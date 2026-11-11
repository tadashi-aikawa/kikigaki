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
        /// 畳んだトレイ。小さな見本と「+N枚」。トレイの全体が押せる。
        case folded(paths: [String])
        /// 開いたトレイの頭の行。「N枚」と「畳む」。「+N枚」があった位置に替わって出す。
        case collapse(paths: [String])
        /// 開いたトレイの末尾の行。頭の「畳む」と同じ位置・同じ見た目。
        case collapseEnd(paths: [String])

        /// 間隔とトレイの範囲を決める種類。
        var part: ScreenLaneTransition.Part {
            switch self {
            case .image, .event: return .block
            case .folded, .collapse: return .trayHead
            case .collapseEnd: return .trayEnd
            }
        }
    }

    /// 枠と枠の間。題と次のサムネイルを、画像と題の間より広く離す。どの題がどの画像かを間隔だけで読み分ける。
    static let spacing = CGFloat(ScreenLaneLayout.blockSpacing)
    /// 画像と題の間。
    static let captionGap = CGFloat(ScreenLaneLayout.captionGap)

    override var isFlipped: Bool { true }
    var onOpen: ((String) -> Void)?
    /// 「+N枚」と「畳む」を押した。押したボタンも渡し、並べ直した後に入れ替わるボタンを同じ位置へ置くのに使う。
    var onToggle: ((ScreenLaneFoldButton) -> Void)?
    private(set) var items: [Item] = []
    private(set) var textScale: CGFloat = 1
    /// レーンの幅。サムネイルの幅はここから左右の余白を引く。文字の倍率を掛けない。
    private(set) var laneWidth = CGFloat(ScreenLaneLayout.defaultWidth)
    var thumbnailWidth: CGFloat { CGFloat(ScreenLaneLayout.thumbnailWidth(laneWidth: Double(laneWidth))) }
    /// 1つの枠。ビューは `container` に載せ、伸び縮みの間は見えている高さで切り取る。
    private final class Block {
        var item: Item
        let key: String
        var views: [NSView]
        let container = ScreenLaneBlockView()
        var height: CGFloat = 0
        /// 見えている割合。伸び縮みの間だけ1未満になる。
        var visible: Double = 1
        var from: Double = 1
        /// 動かし終えた時点の割合。0なら終わったときに消す。
        var to: Double = 1
        /// 間隔とトレイの範囲を決める種類。トレイの中の画像は `trayItem`。消えていく枠は消える前の種類のまま。
        var part: ScreenLaneTransition.Part = .block
        /// 頭の行の小さな見本の濃さを、伸び縮みに合わせてどこからどこへ動かすか。動かしていなければnil。
        /// 始めの値はその時点の濃さ。途中で反対の操作をしても、濃さが途切れない。
        var minis: (from: CGFloat, to: CGFloat)?
        init(item: Item, key: String, views: [NSView]) {
            self.item = item; self.key = key; self.views = views
            views.forEach(container.addSubview)
        }
        var alive: Bool { to > 0 }
        var foldButton: ScreenLaneFoldButton? { views.first as? ScreenLaneFoldButton }
    }
    private var blocks: [Block] = []
    /// トレイの背景。枠の入れ物より下に描く。
    private let trayBackground = ScreenLaneTrayBackground()
    /// 伸び縮みを始めた時刻。動かしていなければnil。
    private var transitionStart: CFTimeInterval?
    var isTransitioning: Bool { transitionStart != nil }
    /// 伸び縮みで中身の高さが変わった。持ち主の行が高さを決め直す。
    var onContentHeightChange: (() -> Void)?
    /// イベントの行は3行まで折り返す。撮れなかった理由は倍率を上げても読めるようにする。
    /// 画像の題は1行で末尾を省く。全文はツールチップで読め、サムネイルの縦の並びを崩さないため。
    static let eventLines = 3

    var isEmpty: Bool { items.isEmpty }
    private var lineHeight: CGFloat { ceil(15 * textScale) }
    private var placement: (origins: [Double], total: Double) {
        let gaps = blocks.indices.map { index in
            index == 0 ? 0 : ScreenLaneTransition.gap(before: blocks[index].part, after: blocks[index - 1].part,
                                                      spacing: Double(Self.spacing))
        }
        return ScreenLaneTransition.layout(heights: blocks.map { Double($0.height) }, visibles: blocks.map(\.visible), gaps: gaps)
    }
    var contentHeight: CGFloat { CGFloat(placement.total) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(trayBackground)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 並びの各枠の種類。開いたトレイの頭から末尾までの画像を `trayItem` にする。
    private static func parts(_ items: [Item]) -> [ScreenLaneTransition.Part] {
        var inside = false
        return items.map { item in
            switch item {
            case .collapse: inside = true; return .trayHead
            case .collapseEnd: inside = false; return .trayEnd
            case .folded: inside = false; return .trayHead
            case .image, .event: return inside ? .trayItem : .block
            }
        }
    }

    /// - animated: 「+N枚」「畳む」を押したときだけ真。増える枠と消える枠を `ScreenLaneTransition.duration` で伸び縮みさせる。
    ///   時刻は呼び出し側が `advance(now:)` で進める。偽なら、動かしている途中でも次の並びへすぐ切り替える
    func update(_ items: [Item], animated: Bool = false, now: CFTimeInterval = CACurrentMediaTime()) {
        guard items != self.items else { return }
        self.items = items
        guard animated, !blocks.isEmpty else { rebuild(); return }
        let keys = Self.keys(items), parts = Self.parts(items)
        let previous = blocks
        var next: [Block] = []
        for entry in ScreenLaneTransition.merge(current: previous.map { ($0.key, $0.visible) }, next: keys) {
            let block: Block
            if let index = entry.current {
                block = previous[index]
                if let n = entry.next, block.item != items[n] {
                    if let button = block.foldButton, items[n].part == .trayHead, block.item.part == .trayHead {
                        // トレイの頭の行は作り直さず、文言と山形を押した時点で替える。小さな見本は伸び縮みに合わせて薄く・濃くする。
                        let wasOpen = button.collapses
                        configure(button, items[n])
                        if wasOpen != button.collapses { block.minis = (button.minisAlpha, button.collapses ? 0 : 1) }
                    } else {
                        block.views.forEach { $0.removeFromSuperview() }
                        block.views = makeViews(items[n])
                        block.views.forEach(block.container.addSubview)
                    }
                    block.item = items[n]
                    block.height = height(of: block.item, views: block.views)
                }
            } else {
                let n = entry.next!
                block = Block(item: items[n], key: keys[n], views: makeViews(items[n]))
                block.height = height(of: block.item, views: block.views)
                addSubview(block.container)
            }
            if let n = entry.next { block.part = parts[n] }
            block.from = entry.from; block.to = entry.to; block.visible = entry.from
            next.append(block)
        }
        blocks = next
        transitionStart = now
        needsStart = true
        needsLayout = true
    }
    /// 今回の並べ直しで組み直した伸び縮み。開始の時刻をまだ揃えていない。
    private(set) var needsStart = false
    /// 伸び縮みの開始の時刻を揃える。並べ直しの後に、進める側の時計で呼ぶ。
    /// 今回組み直したレーンだけに効く。動いている途中の別のレーンの時刻を置き直すと、割合が始めの値へ戻って跳ねるため。
    func startTransition(at now: CFTimeInterval) {
        guard needsStart, transitionStart != nil else { return }
        transitionStart = now
        needsStart = false
    }
    /// 伸び縮みを時刻まで進める。まだ動いていれば真。
    @discardableResult
    func advance(now: CFTimeInterval) -> Bool {
        guard let start = transitionStart else { return false }
        let progress = ScreenLaneTransition.progress(elapsed: now - start)
        guard progress < 1 else { finishTransition(); return false }
        for block in blocks {
            block.visible = block.from + (block.to - block.from) * progress
            // 開くときは前半で見本を消し、畳むときは後半で出す。中の画像と重なって見えないようにするため。
            if let minis = block.minis {
                let shape = minis.to < minis.from ? min(1, 2 * progress) : max(0, 2 * progress - 1)
                block.foldButton?.minisAlpha = minis.from + (minis.to - minis.from) * CGFloat(shape)
            }
        }
        needsLayout = true
        onContentHeightChange?()
        return true
    }
    /// 伸び縮みを終えた状態へ揃える。消える枠を外す。
    func finishTransition() {
        guard transitionStart != nil else { return }
        transitionStart = nil
        needsStart = false
        for block in blocks where !block.alive { block.container.removeFromSuperview() }
        blocks = blocks.filter(\.alive)
        for block in blocks {
            block.visible = 1; block.from = 1; block.to = 1
            block.minis = nil
            block.foldButton?.finishMinisFade()
        }
        needsLayout = true
        onContentHeightChange?()
    }
    func setTextScale(_ scale: CGFloat) {
        guard scale != textScale else { return }
        textScale = scale
        rebuild()
    }
    /// 幅だけが変わったときは枠を作り直さず、高さを測り直す。境目のドラッグで毎回ビューを作らないため。
    func setLaneWidth(_ width: CGFloat) {
        guard width != laneWidth else { return }
        laneWidth = width
        for block in blocks { block.height = height(of: block.item, views: block.views) }
        needsLayout = true
    }
    /// 伸び縮みで枠を突き合わせる鍵。画像はパス、イベントは時刻と文言、「+N枚」と「畳む」は最初の画像のパス。
    /// 「+N枚」と「畳む」を同じ鍵にし、押したボタンの位置で入れ替える。同じ鍵が重なれば出現順を添える。
    private static func keys(_ items: [Item]) -> [String] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let base: String
            switch item {
            case let .image(path, _, _, _): base = "image|" + path
            case let .event(time, text): base = "event|\(time)|\(text)"
            case let .folded(paths), let .collapse(paths): base = "fold|" + (paths.first ?? "")
            case let .collapseEnd(paths): base = "foldEnd|" + (paths.first ?? "")
            }
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base)#\(count)"
        }
    }
    private func rebuild() {
        transitionStart = nil
        needsStart = false
        blocks.forEach { $0.container.removeFromSuperview() }
        blocks = zip(zip(items, Self.keys(items)), Self.parts(items)).map { pair, part in
            let (item, key) = pair
            let block = Block(item: item, key: key, views: makeViews(item))
            block.height = height(of: item, views: block.views)
            block.part = part
            addSubview(block.container)
            return block
        }
        needsLayout = true
    }
    private func configure(_ button: ScreenLaneFoldButton, _ item: Item) {
        switch item {
        case let .folded(paths): button.configure(paths: paths, collapses: false)
        case let .collapse(paths): button.configure(paths: paths, collapses: true)
        default: break
        }
    }
    private func makeViews(_ item: Item) -> [NSView] {
        switch item {
        case let .image(path, time, caption, label):
            let thumbnail = ScreenThumbnailView(path: path)
            thumbnail.toolTip = "\(time) \(label)"
            thumbnail.setAccessibilityLabel("画面 \(time) \(label)")
            thumbnail.onClick = { [weak self] in self?.onOpen?(path) }
            return [thumbnail, captionLabel(time: time, text: caption, tooltip: "\(time) \(label)", lines: 1)]
        case let .event(time, text):
            return [captionLabel(time: time, text: text, tooltip: "\(time) \(text)", lines: Self.eventLines)]
        case let .folded(paths), let .collapse(paths), let .collapseEnd(paths):
            let button: ScreenLaneFoldButton
            switch item {
            case .collapse: button = ScreenLaneFoldButton(paths: paths, collapses: true)
            case .collapseEnd: button = ScreenLaneFoldButton(paths: paths, collapses: true, isEnd: true)
            default: button = ScreenLaneFoldButton(paths: paths, collapses: false)
            }
            button.onPress = { [weak self, weak button] in if let button { self?.onToggle?(button) } }
            return [button]
        }
    }
    private func height(of item: Item, views: [NSView]) -> CGFloat {
        switch item {
        case .image:
            return thumbnailSize(views[0]).height + Self.captionGap + lineHeight
        case .event:
            let measured = (views[0] as? NSTextField)?.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: thumbnailWidth,
                                                                                         height: .greatestFiniteMagnitude)).height ?? lineHeight
            return min(CGFloat(Self.eventLines) * lineHeight, max(lineHeight, ceil(measured)))
        case .folded, .collapse, .collapseEnd:
            return ScreenLaneFoldButton.height
        }
    }
    /// 画像の縦横比に合わせた枠。縦横比はファイルの頭から読む。
    private func thumbnailSize(_ view: NSView) -> NSSize {
        let pixels = (view as? ScreenThumbnailView).flatMap { $0.loader.pixelSize(at: $0.path) }
        let size = ScreenLaneLayout.thumbnailSize(laneWidth: Double(laneWidth), pixelWidth: pixels.map { Double($0.width) },
                                                  pixelHeight: pixels.map { Double($0.height) })
        return NSSize(width: size.width, height: size.height)
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
        let origins = placement.origins
        for (block, origin) in zip(blocks, origins) {
            // 伸び縮みの間だけ切り取る。止まっている間は切り取らず、ボタンのフォーカスリングを枠の外へ描けるようにする。
            block.container.clipsToBounds = block.visible < 1
            block.container.frame = NSRect(x: 0, y: CGFloat(origin), width: bounds.width, height: block.height * CGFloat(block.visible))
            switch block.item {
            case .image:
                // 題は画像のすぐ下。枠の高さは画像に合わせてあるので、枠の下端が画像の下端になる。
                let size = thumbnailSize(block.views[0])
                block.views[0].frame = NSRect(origin: .zero, size: size)
                block.views[1].frame = NSRect(x: 0, y: size.height + Self.captionGap, width: bounds.width, height: lineHeight)
            case .event:
                block.views[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: block.height)
            case .folded, .collapse, .collapseEnd:
                // トレイの行はトレイと同じく左右へはみ出させる。押せるのはレーンの幅の中だけ。
                let bleed = ScreenLaneFoldButton.bleed
                block.views[0].frame = NSRect(x: -bleed, y: 0, width: bounds.width + bleed * 2, height: block.height)
            }
        }
        // トレイの背景は枠の入れ物より下。左右へはみ出す分だけ広げて置く。
        let bleed = ScreenLaneFoldButton.bleed
        trayBackground.frame = bounds.insetBy(dx: -bleed, dy: 0)
        trayBackground.trays = trays(origins: origins).map { $0.offsetBy(dx: bleed, dy: 0).insetBy(dx: -bleed, dy: 0) }
        if subviews.first !== trayBackground { addSubview(trayBackground, positioned: .below, relativeTo: nil) }
        trayBackground.needsDisplay = true
    }
    /// トレイの範囲。頭の行から、続く中の画像と末尾の行の見えている下端まで。レーンの座標で、はみ出す分は含めない。
    private func trays(origins: [Double]) -> [NSRect] {
        var result: [NSRect] = []
        for (block, origin) in zip(blocks, origins) {
            let top = CGFloat(origin), bottom = CGFloat(origin) + block.height * CGFloat(block.visible)
            switch block.part {
            case .trayHead:
                result.append(NSRect(x: 0, y: top, width: bounds.width, height: bottom - top))
            case .trayItem, .trayEnd:
                guard var last = result.popLast() else { continue }
                last.size.height = max(last.height, bottom - last.minY)
                result.append(last)
            case .block:
                continue
            }
        }
        return result
    }
    /// その行の、いま見えている下端。消えていく途中の行も含める。レーンの座標。並びに無ければnil。
    /// 末尾の「畳む」で畳む間は、押した末尾の行のいまの位置を基準にする。合流先の頭は、縮み終えるまで別のトレイに見えるため。
    func visibleBottom(of button: ScreenLaneFoldButton) -> CGFloat? {
        for (block, origin) in zip(blocks, placement.origins) where block.foldButton === button {
            return CGFloat(origin) + block.height * CGFloat(block.visible)
        }
        return nil
    }
    /// 頭か末尾の行を含むトレイの範囲。レーンの座標。伸び縮みの途中でも、その時点の高さで返す。
    /// 末尾の「畳む」で畳んだとき、畳んだ後のトレイを押した位置に見せるスクロールに使う。
    func trayFrame(containing button: ScreenLaneFoldButton) -> NSRect? {
        let origins = placement.origins
        var head: Int?
        for (index, block) in blocks.enumerated() {
            if block.part == .trayHead { head = index }
            guard block.foldButton === button, let head else { continue }
            return trays(origins: origins).first { abs($0.minY - CGFloat(origins[head])) < 0.5 }
        }
        return nil
    }
    /// 「+N枚」と「畳む」。開閉の後に入れ替わる相手をパスで探すのに使う。伸び縮みで消えていく枠のボタンは含めない。
    var foldButtons: [ScreenLaneFoldButton] { blocks.filter(\.alive).flatMap(\.views).compactMap { $0 as? ScreenLaneFoldButton } }
#if DEBUG
    var thumbnailViews: [ScreenThumbnailView] { blocks.filter(\.alive).flatMap(\.views).compactMap { $0 as? ScreenThumbnailView } }
    var captionTexts: [String] { blocks.filter(\.alive).flatMap(\.views).compactMap { ($0 as? NSTextField)?.stringValue } }
    /// 消えていく枠も含めた、見えている割合。
    var blockVisibles: [Double] { blocks.map(\.visible) }
#endif
}

/// 画像レーンの1枠を載せる入れ物。伸び縮みの間は高さで中身を切り取る。
final class ScreenLaneBlockView: NSView {
    override var isFlipped: Bool { true }
}

/// トレイの背景。トレイは、畳んだ画像の連なりを載せる角丸の受け皿。
/// 畳んでいる間は頭の行だけで、開くと下端が伸びて中の画像と末尾の「畳む」を載せる。縁が開いた分の範囲を示す。
/// 色は罫色 `rule` の45%。影・グラデーションは付けない。
final class ScreenLaneTrayBackground: NSView {
    static let radius: CGFloat = 6
    override var isFlipped: Bool { true }
    var trays: [NSRect] = [] { didSet { if trays != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Washi.rule.withAlphaComponent(0.45).setFill()
        for tray in trays where tray.height > 0 {
            NSBezierPath(roundedRect: tray, xRadius: Self.radius, yRadius: Self.radius).fill()
        }
    }
}

/// トレイの頭の行と末尾の行。押すとトレイを開く・畳む。背景はトレイが描き、ここは文言・山形・小さな見本とポインタの濃さを描く。
/// - 畳んでいるとき(頭): 畳んだ画像の小さな見本、「+N枚」、右端に下向きの山形。トレイの全体が押せる
/// - 開いているとき(頭): 「N枚」を薄墨で、右端に「畳む」と上向きの山形
/// - 開いているとき(末尾): 右端に「畳む」と上向きの山形。頭と同じ位置・同じ見た目
/// - 押せるのは頭の行と末尾の行だけ。中の画像は今までどおりQuick Lookで開く
/// - 行はトレイと同じく左右へ6ptはみ出す。はみ出した分は押せない(レーンの枠の外のため)
/// - 文字の倍率は掛けない。操作部なので固定の大きさ
final class ScreenLaneFoldButton: HoverButton {
    /// 行の高さ。
    static let height: CGFloat = 28
    /// トレイが左右へはみ出す幅。
    static let bleed: CGFloat = 6
    /// 小さな見本の幅と、見本どうしの間。
    static let miniWidth: CGFloat = 28
    static let miniGap: CGFloat = 4
    /// 小さな見本の上限。あふれた分は見本を出さず、「+N枚」の数で伝える。
    static let miniLimit = 3
    private static let chevronGap: CGFloat = 4
    var onPress: (() -> Void)?
    /// 開く・畳む対象の画像のパス。
    private(set) var paths: [String]
    /// 「畳む」なら真、「+N枚」なら偽。
    private(set) var collapses: Bool
    /// 開いたトレイの末尾の行なら真。
    let isEnd: Bool
    /// 小さな見本の濃さ。開く・畳む途中で薄く・濃くする。
    var minisAlpha: CGFloat = 1 {
        didSet {
            minis.forEach { $0.alphaValue = minisAlpha }
            // 見本の大きさと枚数の文言の位置も濃さに合わせて動かすので、並べ直して描き直す。
            needsLayout = true
            needsDisplay = true
        }
    }
#if DEBUG
    /// 撮影用。ポインタを乗せた状態で描く。
    var showsHoverForCapture = false { didSet { needsDisplay = true } }
    var miniCount: Int { minis.count }
    /// 枚数の文言の左端。見本と重ならないことを確かめるのに使う。
    var countX: CGFloat { countOrigin }
    /// 枚数の文言の右端と、右端の山形・「畳む」の左端。重ならないことを確かめるのに使う。
    var countMaxX: CGFloat { countOrigin + ceil(count.size().width) }
    var rightControlsX: CGFloat { rightControlsMinX }
#endif
    private var minis: [ScreenThumbnailView] = []
    init(paths: [String], collapses: Bool, isEnd: Bool = false) {
        self.paths = paths; self.collapses = collapses; self.isEnd = isEnd
        super.init(frame: .zero)
        isBordered = false
        target = self; action = #selector(pressed)
        apply(keepingMinis: false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { onPress?() }
    override var isFlipped: Bool { true }
    override var drawsHoverBackground: Bool { false }

    /// 頭の行を開いた・畳んだ形へ替える。文言と山形は押した時点で替え、小さな見本は伸び縮みに合わせて薄くする。
    /// - 開くとき: 見本を残し、薄くして消す
    /// - 畳むとき: 見本が無ければ濃さ0で作り、濃くして出す。開く途中で畳むなら、残っている見本をいまの濃さのまま使う
    func configure(paths: [String], collapses: Bool) {
        let opening = collapses && !self.collapses
        let closing = !collapses && self.collapses
        let reusable = minis.map(\.path) == Array(paths.prefix(Self.miniLimit))
        self.paths = paths; self.collapses = collapses
        if closing && minis.isEmpty { minisAlpha = 0 }
        apply(keepingMinis: opening || (closing && reusable && !minis.isEmpty))
    }
    /// 伸び縮みを終えた。開いた頭の行に残した見本を外す。
    func finishMinisFade() {
        if collapses { minis.forEach { $0.removeFromSuperview() }; minis = [] }
        minisAlpha = 1
    }
    private func apply(keepingMinis: Bool) {
        title = collapses ? "畳む" : "+\(paths.count)枚"
        let help = collapses ? "間の\(paths.count)枚を畳む" : "間の\(paths.count)枚を開く"
        toolTip = help
        setAccessibilityLabel(help)
        // 読み上げで、いま開いているか畳んでいるかを伝える。
        setAccessibilityExpanded(collapses)
        setAccessibilityValue(collapses ? "開いています" : "畳んでいます")
        if !keepingMinis {
            minis.forEach { $0.removeFromSuperview() }
            minis = collapses ? [] : paths.prefix(Self.miniLimit).map { path in
                let mini = ScreenThumbnailView(path: path)
                mini.setAccessibilityElement(false)
                return mini
            }
            minis.forEach(addSubview)
            minis.forEach { $0.alphaValue = minisAlpha }
        }
        needsLayout = true
        needsDisplay = true
    }

    private static let font = NSFont.systemFont(ofSize: 11)
    private var count: NSAttributedString {
        // 開いた頭は枚数だけを薄墨で。畳んだ頭は「+N枚」を墨で。末尾は出さない。
        let text = collapses ? (isEnd ? "" : "\(paths.count)枚") : "+\(paths.count)枚"
        return NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: collapses ? Washi.muted : Washi.ink])
    }
    private var collapseText: NSAttributedString? {
        collapses ? NSAttributedString(string: "畳む", attributes: [.font: Self.font, .foregroundColor: Washi.ink]) : nil
    }
    private var chevron: NSImage? {
        NSImage(systemSymbolName: collapses ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Washi.muted])))
    }
    /// サムネイルの幅の中の左端と右端。行ははみ出す分だけ広い。
    private var inner: (left: CGFloat, right: CGFloat) { (Self.bleed, bounds.width - Self.bleed) }
    /// 右端の山形と「畳む」の左端。枚数の文言はこれより左に収める。
    private var rightControlsMinX: CGFloat {
        var right = inner.right - (chevron?.size.width ?? 0)
        if let collapseText { right -= Self.chevronGap + ceil(collapseText.size().width) }
        return right
    }
    /// 枚数の文言の後ろに空ける幅。右端の山形・「畳む」との間。
    private static let countGap: CGFloat = 4
    /// 見本の数。狭いレーンや桁の多い枚数で、枚数の文言が右端の山形・「畳む」と重なるなら減らす。
    /// 開く途中の頭の行は右端に「畳む」があるので、その幅も引く。
    private var fittingMinis: Int {
        let room = rightControlsMinX - Self.countGap - inner.left - ceil(count.size().width) - 2
        return max(0, min(minis.count, Int((room + Self.miniGap) / (Self.miniWidth + Self.miniGap))))
    }
    /// 見本と枚数の文言の大きさの割合。見本の濃さと同じ。
    /// 見本は薄くなるのと一緒に左端へ縮み、枚数の文言もその右に付いて動く。薄くなる途中の見本にも配置の幅を取り、文言と重ねない。
    private var minisScale: CGFloat { minis.isEmpty ? 0 : min(1, max(0, minisAlpha)) }
    /// 枚数の文言の左端。
    private var countOrigin: CGFloat {
        let shownMinis = min(minis.count, fittingMinis)
        let reserve = shownMinis > 0 ? CGFloat(shownMinis) * (Self.miniWidth + Self.miniGap) + 2 : 0
        return inner.left + reserve * minisScale
    }
    override func layout() {
        super.layout()
        let shown = fittingMinis, scale = minisScale
        for (index, mini) in minis.enumerated() {
            mini.isHidden = index >= shown || scale == 0
            let pixels = mini.loader.pixelSize(at: mini.path)
            let size = ScreenLaneLayout.thumbnailSize(laneWidth: Double(Self.miniWidth) + ScreenLaneLayout.leadingInset + ScreenLaneLayout.trailingInset,
                                                      pixelWidth: pixels.map { Double($0.width) }, pixelHeight: pixels.map { Double($0.height) })
            let width = Self.miniWidth * scale, height = CGFloat(size.height) * scale
            mini.frame = NSRect(x: inner.left + CGFloat(index) * (Self.miniWidth + Self.miniGap) * scale,
                                y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        var hovered = isEnabled && isHovered
#if DEBUG
        hovered = hovered || showsHoverForCapture
#endif
        if isHighlighted || hovered {
            // 開いたトレイでは、頭は上の角だけ、末尾は下の角だけを丸め、トレイの縁に重ねる。
            NSGraphicsContext.saveGraphicsState()
            Washi.muted.withAlphaComponent(isHighlighted ? 0.22 : 0.12).setFill()
            hoverPath().fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let middle = bounds.height / 2
        let countText = count
        let countSize = countText.size()
        countText.draw(at: NSPoint(x: countOrigin, y: (middle - countSize.height / 2).rounded()))
        var right = inner.right
        if let chevron {
            right -= chevron.size.width
            chevron.draw(in: NSRect(x: right, y: (middle - chevron.size.height / 2).rounded(), width: chevron.size.width, height: chevron.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let collapseText {
            let size = collapseText.size()
            right -= Self.chevronGap + ceil(size.width)
            collapseText.draw(at: NSPoint(x: right, y: (middle - size.height / 2).rounded()))
        }
    }
    private func hoverPath() -> NSBezierPath {
        let radius = ScreenLaneTrayBackground.radius
        guard collapses else { return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius) }
        // 丸める角だけを丸めた矩形。上下を反対側の角の分だけ広げて丸め、行の中で切り取る。
        let extended = isEnd ? NSRect(x: 0, y: -radius, width: bounds.width, height: bounds.height + radius)
            : NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + radius)
        NSBezierPath(rect: bounds).setClip()
        return NSBezierPath(roundedRect: extended, xRadius: radius, yRadius: radius)
    }
    /// 見本は押した行の一部。個々の見本は押せない。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point), !isHidden else { return nil }
        return self
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: ScreenLaneTrayBackground.radius, yRadius: ScreenLaneTrayBackground.radius).fill()
    }
}

/// 画面の縮小画像を裏のキューで読み、読み終えたらメインスレッドで知らせる。会議をまたいで共有のキャッシュへ置く。
///
/// - 描くときに初めて読む。長い会議でも画面外の画像を読まないため
/// - 読み込みとデコードはメインスレッドで行わない。展開や速いスクロールで何枚も初めて出しても、UIを待たせないため
/// - 同じパスの読み込みが重なれば1回にまとめ、待っている全員へ知らせる
/// - 読めなかった画像も覚え、描くたびに読み直さない
/// - 読む大きさはサムネイルの幅の刻みで決める(`ScreenLaneLayout.decodePixels`)。広げたレーンでぼやけないため
///   - 境目のドラッグの間は新しく読まず、読めている別の大きさで描く。離してから読む
/// - 縦横比はファイルの頭だけをメインスレッドで読み、パスごとに覚える。枠の高さを読み込みの前に決め、
///   読み終えた後に行の高さを変えないため。デコードはしない。実測で1枚0.2ms(初回)、0.06ms(2回目以降)
@MainActor final class ScreenThumbnailLoader {
    static let shared = ScreenThumbnailLoader()
    enum State: Equatable { case loaded(NSImage), missing }
    private final class Entry { let image: NSImage?; init(_ image: NSImage?) { self.image = image } }
    private final class Size { let value: NSSize?; init(_ value: NSSize?) { self.value = value } }
    private let cache = NSCache<NSString, Entry>()
    private let sizes = NSCache<NSString, Size>()
    /// パスごとに、読めている大きさ。読み直しの間に描く代わりの画像を探すのに使う。
    private var loadedPixels: [String: Set<Int>] = [:]
    private var waiting: [String: [() -> Void]] = [:]
    private var deferred: [() -> Void] = []
    private let queue = DispatchQueue(label: "kikigaki.screen-thumbnail", qos: .userInitiated)
    private let decode: @Sendable (String, Int) -> CGImage?
    /// 既定の幅のサムネイルを読む大きさ。
    nonisolated static let defaultPixels = ScreenLaneLayout.decodePixels(thumbnailWidth: ScreenLaneLayout.thumbnailWidth(laneWidth: ScreenLaneLayout.defaultWidth))

    init(decode: @escaping @Sendable (String, Int) -> CGImage? = ScreenThumbnailLoader.decodeFile) {
        self.decode = decode
    }

    /// 画面は1x寸法で保存している。長辺を `pixels` まで縮める。
    nonisolated static func decodeFile(_ path: String, pixels: Int) -> CGImage? {
        CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary)
        }
    }

    /// 画像の画素の寸法。ファイルの頭だけを読む。読めなければnil。
    func pixelSize(at path: String) -> NSSize? {
        if let size = sizes.object(forKey: path as NSString) { return size.value }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let properties = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, options) as? [CFString: Any] }
        var value: NSSize?
        if let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int {
            // 回転の指定があれば縦横を入れ替える。縮小画像は回転を適用して読むため。
            let rotated = ((properties?[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            value = rotated ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
        }
        sizes.setObject(Size(value), forKey: path as NSString)
        return value
    }

    /// 境目のドラッグの間は真。新しい大きさを読まず、離したときに待っていた枠へ描き直しを知らせる。
    var defersLoads = false {
        didSet {
            guard oldValue, !defersLoads else { return }
            let callbacks = deferred
            deferred = []
            for callback in callbacks { callback() }
        }
    }

    /// 読めていればその状態、まだならnilを返し、読み終えたら `whenLoaded` を呼ぶ。待たない。
    func image(at path: String, pixels: Int = ScreenThumbnailLoader.defaultPixels, whenLoaded: @escaping () -> Void) -> State? {
        let key = "\(pixels)|\(path)"
        if let entry = cache.object(forKey: key as NSString) { return entry.image.map(State.loaded) ?? .missing }
        if defersLoads { deferred.append(whenLoaded); return nil }
        if waiting[key] != nil { waiting[key]?.append(whenLoaded); return nil }
        waiting[key] = [whenLoaded]
        let decode = decode
        queue.async { [weak self] in
            let image = decode(path, pixels)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(path, pixels, image) } }
        }
        return nil
    }

    /// 読めている別の大きさの画像。大きいものを先に返す。読み直しの間とドラッグの間に、枠を空にしないため。
    func anyLoaded(at path: String) -> NSImage? {
        for pixels in (loadedPixels[path] ?? []).sorted(by: >) {
            if let image = cache.object(forKey: "\(pixels)|\(path)" as NSString)?.image { return image }
        }
        return nil
    }

    private func finish(_ path: String, _ pixels: Int, _ image: CGImage?) {
        let key = "\(pixels)|\(path)"
        cache.setObject(Entry(image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }),
                        forKey: key as NSString)
        if image != nil { loadedPixels[path, default: []].insert(pixels) }
        for callback in waiting.removeValue(forKey: key) ?? [] { callback() }
    }

    /// 全部を読み終えるまで待つ。撮影とテストで、描く前に画像を揃えるため。
    func preload(_ paths: [String], pixels: Int = ScreenThumbnailLoader.defaultPixels) async {
        for path in paths {
            await withCheckedContinuation { continuation in
                if image(at: path, pixels: pixels, whenLoaded: { continuation.resume() }) != nil { continuation.resume() }
            }
        }
    }
}

/// 画面の1枚。枠は画像の縦横比に合わせてあり、縦長の画面だけ枠の中へ縦横比を保って収める。画像の輪郭に罫を引く。
/// 押すとQuick Lookで原寸を開く。
/// 縮小画像は `ScreenThumbnailLoader` が裏で読む。読み終えるまでは、読めている別の大きさか罫の枠だけを描き、枠の大きさは変えない。
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
        let pixels = ScreenLaneLayout.decodePixels(thumbnailWidth: Double(bounds.width))
        let state = loader.image(at: path, pixels: pixels) { [weak self] in self?.needsDisplay = true }
        let shown: NSImage?
        if case let .loaded(image) = state { shown = image } else if state == nil { shown = loader.anyLoaded(at: path) } else { shown = nil }
        guard let image = shown, image.size.width > 0, image.size.height > 0 else {
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
        lane.onContentHeightChange = { [weak self] in self?.needsLayout = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(for width: CGFloat) -> CGFloat { lane.isEmpty ? 0 : 8 + lane.contentHeight + 8 }
    override func layout() {
        super.layout()
        lane.frame = lane.frame(in: bounds)
    }
}

extension ScreenLaneView {
    /// 行の中のレーンの位置。上端は発言の名前の行に揃え、右端はスクローラーの分を空ける。
    func frame(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.width - laneWidth + CGFloat(ScreenLaneLayout.leadingInset), y: 8, width: thumbnailWidth, height: contentHeight)
    }
}
