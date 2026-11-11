import AppKit
import KikigakiCore
import Quartz

/// 画像レーンの組み立てとQuick Look。割り当てはCoreの `ScreenLane` が行の並びから毎回導く。
/// 表示専用で、保存するMarkdown・コピー・AIへ渡す会話は変えない。仕様は docs/screen-capture.md の「表示」
extension TranscriptWindowController {
    /// 1回の行の組み立てで使う、レーンの出し方・割り当て・枠の作り方。
    struct ScreenLaneBuild {
        /// 画面の行があればレーンを出す。
        let shown: Bool
        /// 画像があれば境目をつかめる。イベントの行だけの会議ではつかめない。
        let hasImages: Bool
        /// 出すレーンの幅。会話側の幅で決まるので、レーンの出入りでウィンドウを直した後に `minutesSplit` から入れる。
        var width: CGFloat = 0
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
            return ScreenLaneBuild(shown: false, hasImages: false, assignment: .init(), items: { _ in [] })
        }
        // 題は画像の並びで決める。録音中に対象を替えた会議では、直前の画像と同じディスプレイの名前だけを省く。
        let captions = Dictionary(zip(images.compactMap(\.imagePaths.first), ScreenLane.captions(images.map(\.text))),
                                  uniquingKeysWith: { first, _ in first })
        let expanded = screenLaneExpanded
        return ScreenLaneBuild(shown: true, hasImages: !images.isEmpty, assignment: ScreenLane.assign(utterances)) { screens in
            ScreenLane.slots(screens, utterances: utterances, expanded: expanded).map { slot in
                switch slot {
                case let .folded(indices):
                    return .folded(paths: indices.compactMap { utterances[$0].imagePaths.first })
                case let .expanded(indices):
                    return .collapse(paths: indices.compactMap { utterances[$0].imagePaths.first })
                case let .expandedEnd(indices):
                    return .collapseEnd(paths: indices.compactMap { utterances[$0].imagePaths.first })
                case let .screen(index):
                    let row = utterances[index]
                    let time = TranscriptRenderer.clock(for: row, timeline: timeline)
                    guard let path = row.imagePaths.first else { return .event(time: time, text: row.text) }
                    return .image(path: path, time: time, caption: captions[path] ?? row.text, label: row.text)
                }
            }
        }
    }

    /// レーンを出している間に幅だけが変わった。境目のドラッグ・ウィンドウの伸縮・議事録の区切り線が当たる。
    /// 行の中身は作り直さず、幅を渡して高さを測り直す。出入りは `updateRows` が受け持つ。
    func applyScreenLaneWidth() {
        let width = minutesSplit.laneWidth
        guard transcriptDocument.laneWidth > 0, width > 0, width != transcriptDocument.laneWidth else { return }
        let anchor = transcriptDocument.anchor()
        transcriptDocument.laneWidth = width
        for row in rows.values { row.updateLane(row.lane.items, width: width) }
        tentativeRow.updateLane(tentativeRow.lane.items, width: width)
        screenLaneTrailing.lane.setLaneWidth(width)
        transcriptDocument.reflow(anchor: anchor)
        scrolled()
    }

    /// 発言の列と画像レーンの境目のドラッグ。幅の範囲と発言の列に残す幅は `ScreenLaneLayout` が決める。
    /// ドラッグの間は縮小画像を新しく読まず、離してから今の幅に合う大きさで読む。
    func dragScreenLane(_ drag: TranscriptDocument.LaneDrag) {
        let dx: CGFloat
        switch drag {
        case .began:
            screenLaneDragStart = minutesSplit.laneWidth
            ScreenThumbnailLoader.shared.defersLoads = true
            return
        case let .changed(value), let .ended(value): dx = value
        }
        guard let start = screenLaneDragStart else { return }
        let ended: Bool
        if case .ended = drag { ended = true } else { ended = false }
        let width = ScreenLaneLayout.dragged(from: Double(start), by: Double(dx), pane: Double(minutesSplit.left.frame.width))
        minutesSplit.dragLane(to: CGFloat(width), commit: ended)
        if ended {
            screenLaneDragStart = nil
            ScreenThumbnailLoader.shared.defersLoads = false
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
    /// - 末尾の「畳む」: 畳んだ後のトレイの下端を、押した行の下端に置く。伸び縮みの間も毎コマ合わせ、
    ///   上の内容がトレイと一緒に下りてきて、畳んだトレイが押した所に収まる。押した行が表示域の上へ出ていれば、上端へ寄せる
    func toggleScreenLane(_ control: ScreenLaneFoldButton) {
        let clip = scrollView.contentView.bounds
        let pressed = control.convert(control.bounds, to: transcriptDocument)
        let before = pressed.minY - clip.minY
        let desired = before < 0 ? 8 : before
        let focused = window?.firstResponder === control
        let paths = Set(control.paths), opening = !control.collapses
        if opening { screenLaneExpanded.formUnion(paths) } else { screenLaneExpanded.subtract(paths) }
        screenLaneEndAnchor = control.isEnd ? (paths, desired + pressed.height, control) : nil
        // 一旦スクロール位置をそのまま保って並べ直し、相手の位置で補正する。末尾への追従もしない。
        // 伸び縮みは並べ直しの時点では始まりの高さのままにし、相手の位置は増減する枠より上にあるので、補正は終わりまで効く。
        screenLaneAnimates = !shouldReduceMotion()
        refreshRows(anchor: .init(candidates: [], y: clip.minY, atBottom: false))
        screenLaneAnimates = false
        startScreenLaneTransitions()
        if screenLaneEndAnchor != nil {
            let target = applyScreenLaneEndAnchor()
            if screenLaneTransitions.isEmpty { screenLaneEndAnchor = nil }
            if focused, let target { window?.makeFirstResponder(target) }
            return
        }
        guard let (target, y) = screenLaneButton(collapses: opening, overlapping: paths) else { return }
        let maximum = max(0, transcriptDocument.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y - desired), maximum)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrolled()
        if focused { window?.makeFirstResponder(target) }
    }

    // MARK: - 伸び縮み

    /// 並べ直しで伸び縮みを組み直したレーンを集め、開始の時刻を置いて進め始める。
    /// 動いている途中の別のレーンは時刻を置き直さず、そのまま進める。
    /// 動かしている途中の並べ直し(連打、録音中の行の追加、絞り込み、幅のドラッグ)は、レーンが次の並びへ切り替える。
    private func startScreenLaneTransitions() {
        let now = screenLaneClock()
        // 絞り込みで畳んだ行のレーンも集める。集めないと、動かし始めたまま止まる。
        let lanes = (rows.values.map(\.lane) + [tentativeRow.lane, screenLaneTrailing.lane]).filter(\.needsStart)
        guard !lanes.isEmpty else { return }
        for lane in lanes {
            lane.startTransition(at: now)
            if !screenLaneTransitions.contains(where: { $0 === lane }) { screenLaneTransitions.append(lane) }
        }
        guard screenLaneTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepScreenLaneTransitions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenLaneTimer = timer
    }

    /// 1コマ進める。行の高さを決め直し、スクロールの位置を保ったまま文書を並べ直す。
    /// 増減する枠は押したボタンより下にあるので、上の内容は動かない。
    func stepScreenLaneTransitions() {
        let now = screenLaneClock()
        screenLaneTransitions = screenLaneTransitions.filter { $0.advance(now: now) }
        let clip = scrollView.contentView.bounds
        transcriptDocument.reflow(anchor: .init(candidates: [], y: clip.minY, atBottom: false))
        if screenLaneEndAnchor != nil { applyScreenLaneEndAnchor() }
        scrolled()
        if screenLaneTransitions.isEmpty {
            screenLaneTimer?.invalidate()
            screenLaneTimer = nil
            screenLaneEndAnchor = nil
        }
    }

    /// 末尾の「畳む」で畳んだトレイの下端を、押した行の下端の画面上の位置へ合わせる。畳んだ頭の行を返す。
    /// - 伸び縮みの間: 押した末尾の行のいまの下端を合わせる。末尾の行は消えていく途中も並びに残り、縮んだ分だけ上がる
    /// - 消え終えた後(伸び縮みしないときは押した直後): 畳んだ頭の行のトレイの下端を合わせる
    /// - 理由: 手前の「+N枚」と合流すると、合流先の頭と消えていく旧いトレイは、縮み終えるまで別のトレイに見える。
    ///   合流先の28ptの行だけを見ると、縮み始める前に旧いトレイの高さの分だけスクロールが跳ねる
    @discardableResult
    private func applyScreenLaneEndAnchor() -> ScreenLaneFoldButton? {
        guard let anchor = screenLaneEndAnchor else { return nil }
        var head: ScreenLaneFoldButton?
        var bottom: CGFloat?
        for row in transcriptDocument.rows {
            guard let lane = (row as? TranscriptRow)?.lane ?? (row as? ScreenLaneRow)?.lane else { continue }
            if head == nil, let found = lane.foldButtons.first(where: { !$0.collapses && !anchor.paths.isDisjoint(with: $0.paths) }) {
                head = found
                if bottom == nil, let tray = lane.trayFrame(containing: found) { bottom = row.frame.minY + lane.frame.minY + tray.maxY }
            }
            if let pressed = lane.visibleBottom(of: anchor.pressed) {
                bottom = row.frame.minY + lane.frame.minY + pressed
            }
        }
        guard let bottom else { return head }
        let maximum = max(0, transcriptDocument.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, bottom - anchor.bottom), maximum)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrolled()
        return head
    }

    /// 伸び縮みを最後の状態で確定する入口。途中で終わらせる経路はすべてここを通す。
    /// - 「最新の発言へ」: 確定してから末尾へ動かす。動かしたままだと、伸びた分だけ末尾から離れ、次の発言で追従しない
    /// - 「視差効果を減らす」が途中で有効になったとき
    /// - 会議の切替: 前の会議の行は捨てるので、並べ直さない(`reflow: false`)
    /// - 解放のときは `deinit` がタイマーだけを止める。並べ直す相手がもう無いため
    func finishScreenLaneTransitions(reflow: Bool = true) {
        screenLaneTimer?.invalidate()
        screenLaneTimer = nil
        screenLaneEndAnchor = nil
        let lanes = screenLaneTransitions
        screenLaneTransitions = []
        // 一覧に入る前の組み直し(押した直後)も、確定から漏らさない。
        for lane in lanes + rows.values.map(\.lane) + [tentativeRow.lane, screenLaneTrailing.lane] where lane.isTransitioning {
            lane.finishTransition()
        }
        guard reflow, !lanes.isEmpty else { return }
        let clip = scrollView.contentView.bounds
        transcriptDocument.reflow(anchor: .init(candidates: [], y: clip.minY, atBottom: false))
        scrolled()
    }

    /// 表示中の行のレーンから、対象のパスを含む「+N枚」か「畳む」を探し、文書の中の上端と一緒に返す。
    private func screenLaneButton(collapses: Bool, overlapping paths: Set<String>) -> (ScreenLaneFoldButton, CGFloat)? {
        for row in transcriptDocument.rows {
            guard let lane = (row as? TranscriptRow)?.lane ?? (row as? ScreenLaneRow)?.lane else { continue }
            // 載せる範囲の外の行もあるので、ビューの変換ではなく枠を足して位置を出す。
            row.layoutSubtreeIfNeeded()
            lane.layoutSubtreeIfNeeded()
            if let button = lane.foldButtons.first(where: { $0.collapses == collapses && !paths.isDisjoint(with: $0.paths) }) {
                // ボタンは枠の入れ物に載っている。レーンの中の位置はレーンまでの変換で出す。
                return (button, row.frame.minY + lane.frame.minY + button.convert(button.bounds, to: lane).minY)
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
