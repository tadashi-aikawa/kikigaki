import AppKit
import KikigakiCore
import Quartz

/// 画像レーンの組み立てとQuick Look。割り当てはCoreの `ScreenLane` が行の並びから毎回導く。
/// 表示専用で、保存するMarkdown・コピー・AIへ渡す会話は変えない。仕様は docs/screen-capture.md の「表示」
extension TranscriptWindowController {
    /// 1回の行の組み立てで使う、レーンの幅・割り当て・枠の作り方。
    struct ScreenLaneBuild {
        let width: CGFloat
        let assignment: ScreenLane.Assignment
        let items: ([Int]) -> [ScreenLaneView.Item]
    }

    /// 画面の行が1つも無い会議ではレーンを出さず、幅も今のまま。
    func screenLane() -> ScreenLaneBuild {
        let utterances = snapshot.utterances
        let timeline = snapshot.timeline
        let images = utterances.filter { $0.kind == .screen && !$0.imagePaths.isEmpty }
        screenPreview.update(images.compactMap(\.imagePaths.first))
        guard utterances.contains(where: { $0.kind == .screen }) else {
            return ScreenLaneBuild(width: 0, assignment: .init(), items: { _ in [] })
        }
        let shared = ScreenLane.sharedDisplayName(images.map(\.text))
        let expanded = screenLaneExpanded
        return ScreenLaneBuild(width: ScreenLaneView.width, assignment: ScreenLane.assign(utterances)) { screens in
            ScreenLane.slots(screens, utterances: utterances, expanded: expanded).map { slot in
                switch slot {
                case let .folded(indices):
                    return .folded(paths: indices.compactMap { utterances[$0].imagePaths.first })
                case let .expanded(indices):
                    return .collapse(paths: indices.compactMap { utterances[$0].imagePaths.first })
                case let .screen(index):
                    let row = utterances[index]
                    let time = TranscriptRenderer.clock(for: row, timeline: timeline)
                    guard let path = row.imagePaths.first else { return .event(time: time, text: row.text) }
                    return .image(path: path, time: time, caption: ScreenLane.caption(row.text, sharedDisplay: shared), label: row.text)
                }
            }
        }
    }

    func configureLane(_ lane: ScreenLaneView, row: NSView) {
        lane.onOpen = { [weak self] path in self?.openScreenPreview(path) }
        lane.onToggle = { [weak self] button in self?.toggleScreenLane(button) }
    }

    /// 「+N枚」で開き、「畳む」で畳む。開いた覚えは画像のパスで持ち、畳んだら消す。Quick Lookの一覧と見ている画像には触れない。
    ///
    /// 押したボタンの画面上の位置に、入れ替わったボタン(「畳む」なら「+N枚」、逆も同じ)を置く。
    /// 入れ替わる相手は並べ直した後に対象のパスで探す。行の上端を保つだけでは足りない。
    /// - 理由: 割り当て先の併合などで手前に別の「+N枚」があると、畳んだ分がそれと1つの「+N枚」にまとまり、
    ///   入れ替わる相手が押した位置より上に来る
    /// - 例外: 押したボタンが表示域の上へ出ていた場合(キーボード・読み上げで押した場合)は、相手を表示域の上端へ寄せる。
    ///   そのままだと、縮んだ分だけ下の内容が上がり、どこを開閉したのか見失うため
    /// - 受け入れた限界: 文書の末尾が表示域に入っていて縮むと、スクロールの上限で詰まり、相手はその分だけ下へずれる
    /// - フォーカス: 押したボタンにキーボードのフォーカスがあったときだけ、入れ替わった相手へ移す。
    ///   並べ直しで押したボタンは消えるので、移さないと同じ場所でスペースキーを続けて押せない
    func toggleScreenLane(_ control: ScreenLaneFoldButton) {
        let clip = scrollView.contentView.bounds
        let before = control.convert(control.bounds, to: transcriptDocument).minY - clip.minY
        let desired = before < 0 ? 8 : before
        let focused = window?.firstResponder === control
        let paths = Set(control.paths), opening = !control.collapses
        if opening { screenLaneExpanded.formUnion(paths) } else { screenLaneExpanded.subtract(paths) }
        // 一旦スクロール位置をそのまま保って並べ直し、相手の位置で補正する。末尾への追従もしない。
        refreshRows(anchor: .init(candidates: [], y: clip.minY, atBottom: false))
        guard let (target, y) = screenLaneButton(collapses: opening, overlapping: paths) else { return }
        let maximum = max(0, transcriptDocument.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y - desired), maximum)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrolled()
        if focused { window?.makeFirstResponder(target) }
    }

    /// 表示中の行のレーンから、対象のパスを含む「+N枚」か「畳む」を探し、文書の中の上端と一緒に返す。
    private func screenLaneButton(collapses: Bool, overlapping paths: Set<String>) -> (ScreenLaneFoldButton, CGFloat)? {
        for row in transcriptDocument.rows {
            guard let lane = (row as? TranscriptRow)?.lane ?? (row as? ScreenLaneRow)?.lane else { continue }
            // 載せる範囲の外の行もあるので、ビューの変換ではなく枠を足して位置を出す。
            row.layoutSubtreeIfNeeded()
            lane.layoutSubtreeIfNeeded()
            if let button = lane.foldButtons.first(where: { $0.collapses == collapses && !paths.isDisjoint(with: $0.paths) }) {
                return (button, row.frame.minY + lane.frame.minY + button.frame.minY)
            }
        }
        return nil
    }

    // MARK: - Quick Look

    /// 会議の全画面をパネルへ渡し、押したものから開く。←→で前後の画面へ送る。
    /// 手入力の添付画像は既定のアプリで開くまま。Quick Lookへ揃えるのは第2フェーズで決める。
    func openScreenPreview(_ path: String) {
        guard screenPreview.select(path) else { return }
        if let panel = screenPreview.controlledPanel, panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = screenPreview.index
            return
        }
        presentScreenPreview()
    }

    // パネルは応答チェーンから制御役を探すので、受け入れはウィンドウの次に居るこのコントローラーで行う。
    // データ源とデリゲートは別のオブジェクトに渡す。`QLPreviewPanelDelegate` は `NSWindowDelegate` を継承し、
    // このコントローラーを渡すと、パネルを閉じた・動かした通知まで書き起こしウィンドウの後片付けへ流れるため。
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !screenPreview.paths.isEmpty }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = screenPreview
        panel.delegate = screenPreview
        panel.reloadData()
        panel.currentPreviewItemIndex = screenPreview.index
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// Quick Lookへ渡す会議の全画像と、いま開いている番号。パネルのデータ源とデリゲートを兼ねる。
/// 書き起こしウィンドウのコントローラーと分けるのは、パネルのウィンドウの通知を受けても書き起こし側へ流さないため。
@MainActor final class ScreenPreviewSource: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    /// 観測の位置順。
    private(set) var paths: [String] = []
    private(set) var index = 0
    /// この一覧を出しているパネル。出していなければnil。
    var controlledPanel: QLPreviewPanel? {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self else { return nil }
        return panel
    }
    /// パネルがいま出している番号。パネル側の操作で移った画像を、一覧の更新で戻さないために読む。
    /// テストはパネルを出さずに差し替える。
    lazy var shownIndex: () -> Int? = { [weak self] in self?.controlledPanel?.currentPreviewItemIndex }

    /// 押した画像を開く番号にする。一覧に無ければ偽。
    func select(_ path: String) -> Bool {
        guard let found = paths.firstIndex(of: path) else { return false }
        index = found
        return true
    }

    /// 録音中に画面が増えたら、開いているパネルの一覧も揃える。いま見ている画像は動かさない。
    func update(_ next: [String]) {
        guard next != paths else { return }
        let shown = shownIndex().flatMap { paths.indices.contains($0) ? $0 : nil } ?? index
        let current: String? = paths.indices.contains(shown) ? paths[shown] : nil
        paths = next
        let kept: Int? = current.flatMap { path in next.firstIndex { $0 == path } }
        index = kept ?? min(shown, max(0, next.count - 1))
        guard let panel = controlledPanel else { return }
        if next.isEmpty { panel.orderOut(nil); return }
        panel.reloadData()
        panel.currentPreviewItemIndex = index
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { paths.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        paths.indices.contains(index) ? URL(fileURLWithPath: paths[index]) as NSURL : nil
    }
    /// ←→を前後の画面へ送る。パネルが処理しなかったキーだけがここへ届く。
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, !paths.isEmpty else { return false }
        let step: Int
        switch event.keyCode {
        case 123: step = -1
        case 124: step = 1
        default: return false
        }
        index = min(max(0, panel.currentPreviewItemIndex + step), paths.count - 1)
        panel.currentPreviewItemIndex = index
        return true
    }
}

/// Quick Lookのパネルを出す。書き起こしウィンドウを先にキーにし、応答チェーンから制御を渡す。
enum QLPreviewPanelPresenter {
    @MainActor static func present() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.updateController(); panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }
}
