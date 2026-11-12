import AppKit
import Quartz
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

extension AppKitTests {
/// 画像レーン。画面の行を発言の列から外し、発言の横に並べる。仕様は docs/screen-capture.md の「表示」
///
/// `KIKIGAKI_UI_CAPTURE=<出力先>` で撮る。`KIKIGAKI_SCREEN_LANE_IMAGES=<画像のフォルダ>` を添えると、
/// 生成した仮の画像の代わりにそのフォルダの画像を名前順に使う。フォルダは読むだけで書き換えない。
@Suite(.serialized) @MainActor struct ScreenLaneAppTests {
    static let screen = NSRect(x: 0, y: 0, width: 2400, height: 1400)
    private let started = Date(timeIntervalSince1970: 1_788_759_600)
    /// 既定のレーンの幅。
    private let lane = CGFloat(ScreenLaneLayout.defaultWidth)

    /// 伸び縮みの時計。押した時点を1000秒にし、テストが進める。
    private final class Clock { var now: CFTimeInterval = 1000 }
    /// 視差効果を減らす設定。途中で切り替えるテストのため、値を後から変えられるようにする。
    private final class Motion { var reduce: Bool; init(_ reduce: Bool) { self.reduce = reduce } }
    private struct Fixture {
        let controller: TranscriptWindowController
        let defaults: UserDefaults
        let suite: String
        let clock: Clock
        let motion: Motion
        @MainActor func close() {
            defaults.removePersistentDomain(forName: suite); controller.minutesSplit.preview.stop()
            controller.finishScreenLaneTransitions(reflow: false)
        }
        /// 伸び縮みを終わりまで進める。動かしていなければ何もしない。
        @MainActor func settle() {
            clock.now += 1
            controller.stepScreenLaneTransitions()
        }
    }

    /// - reduceMotion: 視差効果を減らす設定。既定は真で、伸び縮みせずに切り替える
    private func fixture(width: CGFloat = 640, height: CGFloat = 900, reduceMotion: Bool = true) throws -> Fixture {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "screen-lane-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let motion = Motion(reduceMotion), clock = Clock()
        let controller = TranscriptWindowController(shouldReduceMotion: { motion.reduce }, minutesDefaults: defaults, textDefaults: defaults)
        controller.screenLaneClock = { clock.now }
        controller.minutesSplit.visibleScreen = { _ in Self.screen }
        controller.presentScreenPreview = {}
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: 0, y: 100))
        window.setFrame(NSRect(x: 0, y: 100, width: width, height: height), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        return Fixture(controller: controller, defaults: defaults, suite: suite, clock: clock, motion: motion)
    }

    /// 画像のパス。撮影の指定があれば実画像、無ければ使い捨ての仮の画像を作る。
    /// - size: 仮の画像の画素の寸法。指定すれば撮影の指定があっても仮の画像を作る。縦横比を確かめるテストのため
    private func images(_ count: Int, size custom: NSSize? = nil) throws -> [String] {
        if custom == nil, let folder = ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_LANE_IMAGES"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".webp") || $0.hasSuffix(".png") }.sorted()
            try #require(names.count >= count)
            return names.prefix(count).map { URL(fileURLWithPath: folder).appendingPathComponent($0).path }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screen-lane-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let size = custom ?? NSSize(width: 640, height: 360)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(calibratedHue: CGFloat(index) / CGFloat(max(count, 1)), saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
                rect.fill()
                ("スライド \(index + 1)" as NSString).draw(at: NSPoint(x: 40, y: 260),
                    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.black])
                return true
            }
            let url = folder.appendingPathComponent(String(format: "%02d.png", index))
            // 画素の寸法を指定どおりにする。画面の倍率で2倍の画素にしない。
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url)
            return url.path
        }
    }

    private func screen(_ path: String, at time: Double, label: String = "EV3895 · Keynote「提案資料」") throws -> Utterance {
        try Utterance(screenLabel: label, imagePath: path, at: time, postedAt: started.addingTimeInterval(time))
    }
    private func event(_ value: Utterance.ScreenEvent, at time: Double) throws -> Utterance {
        try Utterance(screenEvent: value, at: time, postedAt: started.addingTimeInterval(time))
    }

    /// 1枚・2枚・4枚(畳む)・イベントの行・末尾の画面を1つの会議に並べる。
    private func meeting() throws -> SessionSnapshot {
        let paths = try images(9)
        let rows: [Utterance] = [
            Utterance(speaker: 0, start: 0, end: 8, text: "では今日の議題から始めます。最初は来期の予算の配分です。"),
            try screen(paths[0], at: 3),
            Utterance(speaker: 1, start: 10, end: 20, text: "資料の2ページ目を見てください。去年との差がここに出ています。"),
            try screen(paths[1], at: 12),
            try screen(paths[2], at: 18, label: "EV3895 · Safari「予算の比較 - 社内Wiki」"),
            try screen(paths[3], at: 22),
            Utterance(speaker: 0, start: 25, end: 40, text: "なるほど。それなら広告の枠を減らして、検証の環境へ回すのが良さそうですね。順に見ていきましょう。"),
            try screen(paths[4], at: 27),
            try screen(paths[5], at: 30),
            try screen(paths[6], at: 35),
            try event(.stopped, at: 42),
            try event(.resumed, at: 50),
            Utterance(speaker: 1, start: 52, end: 60, text: "再開しました。"),
            try screen(paths[7], at: 51),
            try event(.unavailable("ディスプレイが見つかりません"), at: 58),
            try screen(paths[8], at: 65)
        ]
        var state = SessionSnapshot(state: .idle, utterances: rows.sorted { $0.start < $1.start },
                                    timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "田中", 1: "佐藤"]))
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-screen-lane.md")
        state.elapsed = 70
        return state
    }

    private func voiceRows(_ controller: TranscriptWindowController) -> [TranscriptRow] {
        controller.transcriptDocument.rows.compactMap { $0 as? TranscriptRow }.filter { $0.utterance != nil && !$0.tentative }
    }
    private func row(_ controller: TranscriptWindowController, _ prefix: String) throws -> TranscriptRow {
        try #require(voiceRows(controller).first { $0.utterance?.text.hasPrefix(prefix) == true })
    }

    private func capture(_ name: String, _ controller: TranscriptWindowController, scrollTo row: NSView? = nil) async throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"],
              let content = controller.window?.contentView else { return }
        // 縮小画像は裏で読むので、撮る前に今のレーンの幅に合う大きさで読み終えておく。
        let thumbnail = ScreenLaneLayout.thumbnailWidth(laneWidth: Double(controller.minutesSplit.laneWidth))
        await ScreenThumbnailLoader.shared.preload(controller.screenPreview.paths,
                                                   pixels: ScreenLaneLayout.decodePixels(thumbnailWidth: thumbnail))
        content.layoutSubtreeIfNeeded()
        if let row {
            controller.transcriptDocument.scroll(NSPoint(x: 0, y: max(0, row.frame.minY - 8)))
            controller.scrolled()
        }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("screen-lane-\(name).png"))
    }

    @Test func 画面の行は発言の列に出さず_観測した時点の発言の横に置く() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(voiceRows(controller).map { $0.utterance!.kind } == [.voice, .voice, .voice, .voice])
        #expect(controller.transcriptDocument.laneWidth == lane)
        #expect(try row(controller, "では").lane.thumbnailViews.count == 1)
        #expect(try row(controller, "資料").lane.thumbnailViews.count == 2)
        // 沈黙の間の22秒の画面は次の発言へ。4枚なので最初と最後を出し、間の2枚を畳む。
        let folded = try row(controller, "なるほど")
        #expect(folded.lane.thumbnailViews.map(\.path).count == 2)
        #expect(folded.lane.foldButtons.map(\.title) == ["+2枚"])
        // イベントの行もレーンへ。共通のディスプレイ名は題から省く。
        let resumed = try row(controller, "再開")
        #expect(resumed.lane.captionTexts.contains { $0.hasSuffix("記録を停止") })
        #expect(resumed.lane.captionTexts.contains { $0.hasSuffix("記録を再開") })
        #expect(resumed.lane.captionTexts.contains { $0.hasSuffix("Keynote「提案資料」") && !$0.contains("EV3895") })
        // 後ろに発言が無い画面は末尾の行へ。
        #expect(controller.transcriptDocument.rows.last === controller.screenLaneTrailing)
        #expect(controller.screenLaneTrailing.lane.thumbnailViews.count == 1)
        // 発言の文字はレーンの手前で折り返す。
        let body = try row(controller, "なるほど")
        #expect(body.frame.width == controller.transcriptDocument.frame.width)
        try await capture("one-two", controller, scrollTo: try row(controller, "では"))
        // 末尾まで下ろすと、畳んだ行・イベントの行・末尾のレーンの行が1枚に収まる。
        try await capture("folded-events", controller, scrollTo: resumed)
        folded.lane.layoutSubtreeIfNeeded()
        let foldY = folded.lane.foldButtons[0].frame.minY
        folded.lane.foldButtons[0].performClick(nil)
        let expanded = try row(controller, "なるほど")
        expanded.lane.layoutSubtreeIfNeeded()
        #expect(expanded.lane.thumbnailViews.count == 4)
        // 「+2枚」があった位置に「畳む」が替わって出る。開いた分の末尾にも「畳む」を置く。
        #expect(expanded.lane.foldButtons.map(\.title) == ["畳む", "畳む"])
        #expect(expanded.lane.foldButtons.map(\.isEnd) == [false, true])
        #expect(expanded.lane.foldButtons[0].frame.minY == foldY)
        #expect(expanded.lane.foldButtons[0].toolTip == "間の2枚を畳む")
        try await capture("expanded", controller, scrollTo: expanded)
    }

    /// 押して、伸び縮みを終わりまで進める。視差効果を減らす設定では押すだけ。
    /// 開閉のスクロールの約束を、伸び縮みの有無の両方で確かめるために使う。
    private func press(_ button: NSButton, _ fixture: Fixture) {
        button.performClick(nil)
        fixture.settle()
    }

    @Test(arguments: [true, false])
    func 畳むは開いた覚えを消して同じ位置に枚数の行を戻し_Quick_Lookには触れない(reduceMotion: Bool) throws {
        // 文書の末尾が表示域に入ると、縮んだ分はスクロールの上限で詰まる。下に内容が残る高さで確かめる。
        let fixture = try fixture(height: 460, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let document = controller.transcriptDocument
        func lane() throws -> ScreenLaneView { try row(controller, "なるほど").lane }
        func screenY(_ view: NSView) -> CGFloat {
            view.convert(view.bounds, to: document).minY - controller.scrollView.contentView.bounds.minY
        }
        press(try lane().foldButtons[0], fixture)
        #expect(controller.screenLaneExpanded.count == 2)
        let previewPaths = controller.screenPreview.paths
        _ = controller.screenPreview.select(previewPaths[3])
        // 「畳む」が表示域に見えている: 押した位置に「+2枚」が戻り、スクロールは飛ばない。
        document.scroll(NSPoint(x: 0, y: max(0, try row(controller, "なるほど").frame.minY - 40)))
        controller.scrolled()
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let collapse = try lane().foldButtons[0]
        let before = screenY(collapse)
        #expect(before >= 0)
        press(collapse, fixture)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let restored = try lane().foldButtons[0]
        #expect(restored.title == "+2枚")
        #expect(abs(screenY(restored) - before) < 0.5)
        #expect(controller.screenLaneExpanded.isEmpty)
        #expect(controller.screenPreview.paths == previewPaths && controller.screenPreview.index == 3)
        #expect(try lane().thumbnailViews.count == 2)
        // 「畳む」が表示域の上へ出ている: 畳んだ後の「+2枚」を表示域の上端へ寄せる。
        press(try lane().foldButtons[0], fixture)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let hidden = try lane().foldButtons[0]
        document.scroll(NSPoint(x: 0, y: hidden.convert(hidden.bounds, to: document).minY + 120))
        controller.scrolled()
        #expect(screenY(hidden) < 0)
        press(hidden, fixture)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(abs(screenY(try lane().foldButtons[0]) - 8) < 0.5)
        #expect(controller.screenLaneExpanded.isEmpty)
    }

    @Test func 文字の倍率はレーンの文字だけに掛け_サムネイルは固定する() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        let first = try row(controller, "資料").lane
        first.layoutSubtreeIfNeeded()
        let before = first.thumbnailViews.map(\.frame.size)
        if ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_LANE_IMAGES"] == nil {
            // 仮の画像は16:9。
            #expect(before == [NSSize(width: 152, height: 86), NSSize(width: 152, height: 86)])
        }
        controller.setTextScale(TranscriptTextScale(savedValue: 200))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let lane = try row(controller, "資料").lane
        lane.layoutSubtreeIfNeeded()
        #expect(lane.thumbnailViews.map(\.frame.size) == before)
        #expect(lane.textScale == 2)
        try await capture("scale-200", controller, scrollTo: try row(controller, "資料"))
    }

    @Test func 画面の行が無い会議ではレーンを出さず_出るときはウィンドウをレーンの分だけ広げる() async throws {
        let fixture = try fixture(width: 700)
        defer { fixture.close() }
        let controller = fixture.controller
        var plain = try meeting()
        plain.utterances.removeAll { $0.kind == .screen }
        controller.apply(plain)
        #expect(controller.window!.frame.width == 700)
        #expect(controller.transcriptDocument.laneWidth == 0)
        #expect(voiceRows(controller).allSatisfy { $0.lane.isHidden || $0.lane.isEmpty })
        try await capture("none", controller)
        // 前の会議を開き直すなどで画面の行のある会議へ移ると、発言の列の幅を保って広げる。
        var withLane = try meeting()
        withLane.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(withLane)
        #expect(controller.window!.frame.width == 700 + lane)
        #expect(controller.window!.minSize.width == 420 + lane)
        // 戻ると元の幅へ。保存する希望幅にはレーンの分を入れない。
        plain.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(7200))
        controller.apply(plain)
        #expect(controller.window!.frame.width == 700)
        #expect(MinutesLayout.load(fixture.defaults).leftWidth == 700)
    }

    @Test func 議事録を開いている間も発言の列の幅を保ち_閉じるとレーンを含む幅へ戻る() throws {
        let fixture = try fixture(width: 700)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.toggleMinutes()
        let split = controller.minutesSplit!
        let rightBefore = split.preview.frame.width
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(split.left.frame.width == 700 + lane)
        #expect(split.preview.frame.width == rightBefore)
        controller.toggleMinutes()
        #expect(controller.window!.frame.width == 700 + lane)
        #expect(MinutesLayout.load(fixture.defaults).leftWidth == 700)
    }

    @Test func 絞り込み中は割り当て先の発言と一緒に画像を出し隠す() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.setFilter([.speaker(1)])
        let shown = voiceRows(controller).map { $0.utterance!.text.prefix(2) }
        #expect(shown == ["資料", "再開"])
        #expect(try row(controller, "資料").lane.thumbnailViews.count == 2)
        // 田中の行は畳まれ、横の画像も出ない。末尾の画面は割り当て先が無いので出す。
        let thumbnails = controller.transcriptDocument.rows.flatMap { row -> [ScreenThumbnailView] in
            (row as? TranscriptRow)?.lane.thumbnailViews ?? (row as? ScreenLaneRow)?.lane.thumbnailViews ?? []
        }
        // 佐藤の2行の2枚と1枚、末尾の1枚。
        let expected = 4
        #expect(thumbnails.count == expected)
        // 絞り込みの選択肢に画面は足さない。
        controller.filterPressed()
        #expect(controller.filterPopover?.checkboxes.count == 2)
        controller.filterPopover?.close()
        try await capture("filter", controller)
    }

    @Test func 聞き取り中の行があれば末尾の画面はその横に置く() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        var state = try meeting()
        state.state = .recording
        state.tentativeText = "では次に"
        controller.apply(state)
        #expect(!controller.transcriptDocument.rows.contains { $0 === controller.screenLaneTrailing })
        let tentative = try #require(controller.transcriptDocument.rows.last as? TranscriptRow)
        #expect(tentative.tentative && tentative.lane.thumbnailViews.count == 1)
    }

    @Test func サムネイルを押すと会議の全画面をQuick_Lookへ渡し押したものから開く() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        var presented = 0
        controller.presentScreenPreview = { presented += 1 }
        let state = try meeting()
        controller.apply(state)
        let paths = state.utterances.filter { $0.kind == .screen }.compactMap(\.imagePaths.first)
        #expect(controller.screenPreview.paths == paths)
        let target = try row(controller, "資料").lane.thumbnailViews[1]
        target.onClick?()
        #expect(presented == 1)
        #expect(controller.screenPreview.index == paths.firstIndex(of: target.path))
        #expect(controller.screenPreview.numberOfPreviewItems(in: nil) == paths.count)
        // パネルは応答チェーンをたどって制御役を探す。ウィンドウの次にこのコントローラーが居ること。
        #expect(controller.window?.nextResponder === controller)
        #expect(controller.acceptsPreviewPanelControl(nil))
        #expect((controller.screenPreview.previewPanel(nil, previewItemAt: 2) as? URL)?.path == paths[2])
    }

    @Test func Quick_Lookのデリゲートは書き起こしウィンドウのコントローラーにしない() throws {
        // `QLPreviewPanelDelegate` は `NSWindowDelegate` を継承する。コントローラーを渡すと、
        // パネルを閉じた通知で議事録の監視を止め、パネルの画面変更でウィンドウの幅を直してしまう。
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        let panel = try #require(QLPreviewPanel.shared())
        controller.beginPreviewPanelControl(panel)
        defer { controller.endPreviewPanelControl(panel) }
        #expect((panel.delegate as AnyObject?) === controller.screenPreview)
        #expect((panel.dataSource as AnyObject?) === controller.screenPreview)
        #expect(!((controller as AnyObject) is QLPreviewPanelDelegate))
        #expect(panel.currentPreviewItemIndex == controller.screenPreview.index)
    }

    @Test func Quick_Lookで移った画像を_画像が増えても戻さない() {
        let source = ScreenPreviewSource()
        source.update(["/a.webp", "/b.webp", "/c.webp"])
        #expect(source.select("/a.webp"))
        // サムネイルで開いたのはaだが、パネルの←→でcへ移った。
        source.shownIndex = { 2 }
        source.update(["/a.webp", "/b.webp", "/c.webp", "/d.webp"])
        #expect(source.index == 2)
        // 前へ画像が割り込んでも、見ている画像を指し続ける。
        source.shownIndex = { nil }
        source.update(["/z.webp", "/a.webp", "/b.webp", "/c.webp", "/d.webp"])
        #expect(source.index == 3)
    }

    @Test func 縮小画像は裏で読み_同じパスの読み込みは1回にまとめる() async throws {
        final class Counter: @unchecked Sendable { let lock = NSLock(); var count = 0 }
        let counter = Counter()
        let path = try images(1)[0]
        let loader = ScreenThumbnailLoader { path, pixels in
            counter.lock.withLock { counter.count += 1 }
            Thread.sleep(forTimeInterval: 0.2)
            return ScreenThumbnailLoader.decodeFile(path, pixels: pixels)
        }
        var called = 0
        let started = Date()
        #expect(loader.image(at: path) { called += 1 } == nil)
        #expect(loader.image(at: path) { called += 1 } == nil)
        // 読み終えるのを待たずに返る。
        #expect(Date().timeIntervalSince(started) < 0.1)
        await loader.preload([path])
        #expect(called == 2)
        #expect(counter.count == 1)
        guard case .loaded = loader.image(at: path, whenLoaded: {}) else { Issue.record("読み終えた画像がキャッシュに無い"); return }
        #expect(counter.count == 1)
        // 読めない画像も覚え、読み直さない。
        #expect(loader.image(at: "/no/such.webp", whenLoaded: {}) == nil)
        await loader.preload(["/no/such.webp"])
        #expect(loader.image(at: "/no/such.webp", whenLoaded: {}) == .missing)
        #expect(counter.count == 2)
    }

    @Test func 縮小画像を読む前後で行の高さを変えない() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let heights = controller.transcriptDocument.rows.map(\.frame.height)
        await ScreenThumbnailLoader.shared.preload(controller.screenPreview.paths)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(controller.transcriptDocument.rows.map(\.frame.height) == heights)
    }

    @Test func レーンを足して伸ばせなかった幅から_外したときに希望幅を削らない() throws {
        // 画面の右端に置いた700ptのウィンドウ。レーンを足しても右へ伸ばせない。
        let fixture = try fixture(width: 700)
        defer { fixture.close() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        // 利用者がライブリサイズで700ptにした扱い。プログラムで変えた幅は希望幅に入らない。
        controller.minutesSplit.rememberWidths()
        #expect(MinutesLayout.load(fixture.defaults).leftWidth == 700)
        window.setFrame(NSRect(x: Self.screen.maxX - 700, y: 100, width: 700, height: 900), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        // 右端へ動かして実機の画面から外れるかは、実行機の画面の配置で決まる。外れると画面の変更が届き、
        // ウィンドウを希望幅へ合わせ直す。どちらの実行機でも同じ経路を通るよう、ここで送る。
        controller.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: window))
        #expect(window.frame == NSRect(x: Self.screen.maxX - 700, y: 100, width: 700, height: 900))
        controller.apply(try meeting())
        #expect(window.frame.width == 700)
        var plain = try meeting()
        plain.utterances.removeAll { $0.kind == .screen }
        plain.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(plain)
        #expect(window.frame.width == 700)
        #expect(MinutesLayout.load(fixture.defaults).leftWidth == 700)
    }

    @Test func 狭い画面でもレーンの往復で希望幅を削らない() throws {
        let fixture = try fixture(width: 600)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.minutesSplit.visibleScreen = { _ in NSRect(x: 0, y: 0, width: 650, height: 1000) }
        let window = try #require(controller.window)
        controller.apply(try meeting())
        #expect(window.frame.width == 650)
        var plain = try meeting()
        plain.utterances.removeAll { $0.kind == .screen }
        plain.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(plain)
        #expect(window.frame.width == 600)
        #expect(MinutesLayout.load(fixture.defaults).leftWidth == 600)
    }

    @Test func レーン表示中の区切り線のドラッグは発言の列の最小幅を守る() throws {
        // 全幅921pt・区切り1pt・レーン180pt。比率を全体に掛けると左の下限が525ptになり、発言の列が345ptまで縮んだ。
        #expect(MinutesLayout.leftLowerBound(total: 921, divider: 1, lane: 180) == 600)
        #expect(MinutesLayout.leftLowerBound(total: 1600, divider: 1, lane: 180) == 600)
        // レーンが無ければ従来どおり。
        #expect(MinutesLayout.leftLowerBound(total: 921, divider: 1) == 420)
        #expect(MinutesLayout.leftLowerBound(total: 600, divider: 1) == MinutesLayout.leftLowerBound(total: 600, divider: 1, lane: 0))
        let fixture = try fixture(width: 700)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.toggleMinutes()
        controller.apply(try meeting())
        let split = try #require(controller.minutesSplit)
        let minimum = split.splitView(split, constrainMinCoordinate: 0, ofSubviewAt: 0)
        #expect(minimum - lane >= MinutesLayout.minimumLeft)
    }

    @Test func 画面の行を飛ばしてもマイク切替をAIの行より前に置く() throws {
        // マイク切替1秒 → 画面2秒 → AIへの送信と返事2.5〜3秒 → 発言10秒。
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID(); var history = try AIStreamHistory(meetingID: meetingID)
        let snapshot = try history.prepare(lines: ["[14:40:00] 田中: 確認です。"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/"
                + AIEnvelope.sessionPath(slot: 1, generation: 1)).path, requestToken: UUID().uuidString,
            question: "この画面で合っていますか", capturedAt: started.addingTimeInterval(2.5), audioCutoffSeconds: 2.5,
            profile: "宛先", profileSlot: 1)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1,
            voiceQuestion: "ありがとう。", snapshot: snapshot)
        var conversation = AIConversation(meetingID: meetingID)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(2.5)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: started.addingTimeInterval(3),
            body: "合っています。"), at: started.addingTimeInterval(3))
        let path = try images(1)[0]
        var state = SessionSnapshot(state: .idle, utterances: [
            try screen(path, at: 2),
            Utterance(speaker: 0, start: 10, end: 12, text: "では次へ。")
        ], timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "田中"]))
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-screen-lane-order.md")
        state.microphoneSwitches = [MicrophoneSwitch(audioTime: 1, date: started.addingTimeInterval(1), name: "外付け")]
        state.ai = AIViewState(conversation: conversation)
        state.elapsed = 20
        let fixture = try fixture()
        defer { fixture.close() }
        fixture.controller.apply(state)
        let kinds = fixture.controller.transcriptDocument.rows.map { row -> String in
            switch row {
            case is MicrophoneSwitchRow: return "マイク"
            case is AISendLineRow, is AITypedSendRow: return "AI送信"
            case is AIReplyRow: return "AI返事"
            case is TranscriptRow: return "発言"
            default: return "\(type(of: row))"
            }
        }
        #expect(kinds == ["マイク", "AI送信", "AI返事", "発言"])
    }

    @Test func 検索は画面の行の見出しを一致に数えない() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.showSearch(nil)
        controller.searchField.stringValue = "Keynote"
        controller.refreshSearch(reset: true, reveal: false)
        #expect(controller.searchHits.isEmpty)
        controller.closeSearch(nil)
    }

    // MARK: - 枠の縦横比と題の間隔

    @Test func 枠を画像の縦横比に合わせ_題は画像のすぐ下で次の画像より近くに置く() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        // 横長の画面(2.4:1)と縦長の画面。固定の16:9の枠では、横長の画像の下に23ptの余りが出て、題が次の画像のものに見えた。
        let wide = try images(1, size: NSSize(width: 960, height: 400))[0]
        let tall = try images(1, size: NSSize(width: 360, height: 640))[0]
        var state = SessionSnapshot(state: .idle, utterances: [
            Utterance(speaker: 0, start: 0, end: 30, text: "横長と縦長の画面です。"),
            try screen(wide, at: 3), try screen(tall, at: 10)
        ], timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "田中"]))
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-screen-lane-aspect.md")
        state.elapsed = 40
        controller.apply(state)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let lane = try row(controller, "横長").lane
        lane.layoutSubtreeIfNeeded()
        #expect(lane.thumbnailViews.map(\.frame.size) == [NSSize(width: 152, height: 63), NSSize(width: 152, height: 152)])
        // 枠ごとの入れ物に載っているので、レーンの中の位置へ直して比べる。
        let thumbnails = lane.thumbnailViews.map { $0.convert($0.bounds, to: lane) }
        let captions = lane.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
            .map { $0.convert($0.bounds, to: lane) }.sorted { $0.minY < $1.minY }
        try #require(captions.count == 2)
        let gapBelowImage = captions[0].minY - thumbnails[0].maxY
        let gapToNext = thumbnails[1].minY - captions[0].maxY
        #expect(gapBelowImage == 3)
        #expect(gapToNext == 12)
        #expect(gapToNext > gapBelowImage * 2)
        #expect(captions[1].minY == thumbnails[1].maxY + 3)
    }

    // MARK: - レーンの幅

    @Test func 境目をドラッグするとウィンドウの幅を保ってレーンが広がり_発言の列に最小幅を残す() throws {
        let fixture = try fixture(width: 640)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        #expect(window.frame.width == 640 + lane)
        let document = controller.transcriptDocument
        controller.dragScreenLane(.began)
        #expect(ScreenThumbnailLoader.shared.defersLoads)
        controller.dragScreenLane(.changed(-120))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(document.laneWidth == 300)
        #expect(window.frame.width == 640 + lane)
        let wide = try row(controller, "資料").lane
        wide.layoutSubtreeIfNeeded()
        #expect(wide.thumbnailViews.allSatisfy { $0.frame.width == 272 })
        // 会話側820pt。発言の列に420ptを残す400ptで止まる。
        controller.dragScreenLane(.changed(-1000))
        #expect(document.laneWidth == 400)
        #expect(controller.minutesSplit.left.frame.width - document.laneWidth == MinutesLayout.minimumLeft)
        // 右へ動かすと最小幅で止まる。
        controller.dragScreenLane(.changed(1000))
        #expect(document.laneWidth == 180)
        controller.dragScreenLane(.ended(-80))
        #expect(document.laneWidth == 260)
        #expect(!ScreenThumbnailLoader.shared.defersLoads)
        #expect(window.frame.width == 640 + lane)
        // 幅と、そのときの発言の列の幅を保存する。
        let saved = MinutesLayout.load(fixture.defaults)
        #expect(saved.screenLaneWidth == 260)
        // 会話側820pt - レーン260pt。
        #expect(saved.leftWidth == CGFloat(560))
    }

    @Test func 変えた幅は次の会議と次の起動でも使い_ウィンドウの幅は変えない() throws {
        let fixture = try fixture(width: 900)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        let window = try #require(controller.window)
        let width = window.frame.width
        controller.dragScreenLane(.began)
        controller.dragScreenLane(.ended(-300))
        #expect(controller.transcriptDocument.laneWidth == 480)
        // レーンの無い会議では、広げたレーンの分だけ縮む。
        var plain = try meeting()
        plain.utterances.removeAll { $0.kind == .screen }
        plain.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(plain)
        #expect(window.frame.width == width - 480)
        #expect(controller.transcriptDocument.laneWidth == 0)
        // 次の画像のある会議では同じ幅で出し、ウィンドウも元の幅へ戻る。
        var next = try meeting()
        next.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(7200))
        controller.apply(next)
        #expect(controller.transcriptDocument.laneWidth == 480)
        #expect(window.frame.width == width)
        // 次の起動: 同じ保存先で作り直したウィンドウも同じ幅で出す。
        let reopened = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: fixture.defaults, textDefaults: fixture.defaults)
        reopened.minutesSplit.visibleScreen = { _ in Self.screen }
        defer { reopened.minutesSplit.preview.stop() }
        reopened.window!.setFrameAutosaveName("")
        reopened.window!.setFrame(NSRect(x: 0, y: 100, width: 600, height: 900), display: false)
        reopened.apply(try meeting())
        #expect(reopened.transcriptDocument.laneWidth == 480)
        #expect(reopened.window!.frame.width == width)
        // 後ろに発言が無い画面の末尾の行も同じ幅で出す。
        #expect(reopened.transcriptDocument.rows.last === reopened.screenLaneTrailing)
        #expect(reopened.screenLaneTrailing.lane.laneWidth == 480)
        #expect(try row(reopened, "資料").lane.laneWidth == 480)
    }

    @Test func 会話側が狭まると発言の列より先にレーンが譲り_広げると希望の幅へ戻る() throws {
        let fixture = try fixture(width: 900)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.dragScreenLane(.began)
        controller.dragScreenLane(.ended(-300))
        let window = try #require(controller.window)
        // 最小幅には最小のレーンの分だけを足す。
        #expect(window.minSize.width == 420 + lane)
        window.setFrame(NSRect(x: 0, y: 100, width: 700, height: 900), display: false)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(controller.transcriptDocument.laneWidth == 280)
        window.setFrame(NSRect(x: 0, y: 100, width: 1400, height: 900), display: false)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(controller.transcriptDocument.laneWidth == 480)
        #expect(MinutesLayout.load(fixture.defaults).screenLaneWidth == 480)
    }

    @Test(arguments: [false, true])
    func ウィンドウを狭めたリサイズの終わりに_希望のレーンの幅で広げ直さない(minutes: Bool) throws {
        let fixture = try fixture(width: 900)
        defer { fixture.close() }
        let controller = fixture.controller
        if minutes { controller.toggleMinutes() }
        controller.apply(try meeting())
        controller.dragScreenLane(.began)
        controller.dragScreenLane(.ended(-300))
        #expect(controller.transcriptDocument.laneWidth == 480)
        let window = try #require(controller.window)
        let split = try #require(controller.minutesSplit)
        // ライブリサイズ: 枠が変わるたびに幅を覚え、終わりに画面へ合わせ直す。
        func liveResize(to width: CGFloat) {
            window.setFrame(NSRect(x: 0, y: 100, width: width, height: 900), display: false)
            window.contentView!.layoutSubtreeIfNeeded()
            split.rememberWidths()
            controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
            window.contentView!.layoutSubtreeIfNeeded()
        }
        // 会話側を700ptまで狭める。議事録を開いていれば、右ペインが最小幅の320ptになるまで狭める。
        let narrow: CGFloat = minutes ? 700 + 1 + MinutesLayout.minimumRight : 700
        liveResize(to: narrow)
        #expect(window.frame.width == narrow)
        #expect(split.left.frame.width == 700)
        #expect(controller.transcriptDocument.laneWidth == 280)
        let saved = MinutesLayout.load(fixture.defaults)
        #expect(saved.leftWidth == CGFloat(420))
        // レーンの希望の幅は保つ。会話側を広げれば戻る。
        #expect(saved.screenLaneWidth == 480)
        // 広げる。議事録を開いている間の手動の伸縮は右ペインが受けるので、レーンは変わらない。
        let wide: CGFloat = minutes ? 1500 : 1200
        liveResize(to: wide)
        #expect(window.frame.width == wide)
        #expect(controller.transcriptDocument.laneWidth == (minutes ? 280 : 480))
    }

    @Test func 議事録を開いている間は議事録ペインの幅を保ち_会話側の中で分け合う() throws {
        let fixture = try fixture(width: 700)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.toggleMinutes()
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let split = try #require(controller.minutesSplit)
        let left = split.left.frame.width, right = split.preview.frame.width, window = controller.window!.frame.width
        controller.dragScreenLane(.began)
        controller.dragScreenLane(.ended(-100))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(controller.transcriptDocument.laneWidth == 280)
        #expect(split.left.frame.width == left)
        #expect(split.preview.frame.width == right)
        #expect(controller.window!.frame.width == window)
    }

    @Test func 境目の上ではポインタのドラッグでレーンの幅が変わり_画像の無い会議ではつかめない() throws {
        let fixture = try fixture(width: 640)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        let window = try #require(controller.window)
        window.contentView!.layoutSubtreeIfNeeded()
        let document = controller.transcriptDocument
        // 境目は発言の列の右端。最初の発言の行の高さで押す。
        let local = NSPoint(x: document.bounds.width - document.laneWidth + 1, y: voiceRows(controller)[0].frame.midY)
        #expect(document.hitTest(document.convert(local, to: document.superview)) === document)
        // サムネイルの上は行のまま。押すとQuick Lookで開く。
        let onThumbnail = NSPoint(x: document.bounds.width - document.laneWidth + 20, y: local.y)
        #expect(document.hitTest(document.convert(onThumbnail, to: document.superview)) !== document)
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            let point = document.convert(NSPoint(x: x, y: local.y), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        document.mouseDown(with: event(.leftMouseDown, x: local.x))
        document.mouseDragged(with: event(.leftMouseDragged, x: local.x - 100))
        #expect(document.laneWidth == 280)
        document.mouseUp(with: event(.leftMouseUp, x: local.x - 60))
        #expect(document.laneWidth == 240)
        #expect(MinutesLayout.load(fixture.defaults).screenLaneWidth == 240)
        // イベントの行だけの会議ではレーンを出すが、境目はつかめない。
        var events = try meeting()
        events.utterances.removeAll { $0.kind == .screen && !$0.imagePaths.isEmpty }
        events.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(events)
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(document.laneWidth > 0 && !document.laneHasImages)
        let grip = NSPoint(x: document.bounds.width - document.laneWidth + 1, y: voiceRows(controller)[0].frame.midY)
        #expect(document.hitTest(document.convert(grip, to: document.superview)) !== document)
    }

    @Test func ドラッグの間は縮小画像を新しく読まず_離してから読む() async throws {
        final class Counter: @unchecked Sendable { let lock = NSLock(); var count = 0 }
        let counter = Counter()
        let path = try images(1, size: NSSize(width: 640, height: 360))[0]
        let loader = ScreenThumbnailLoader { path, pixels in
            counter.lock.withLock { counter.count += 1 }
            return ScreenThumbnailLoader.decodeFile(path, pixels: pixels)
        }
        await loader.preload([path])
        #expect(counter.count == 1)
        loader.defersLoads = true
        var redraws = 0
        #expect(loader.image(at: path, pixels: 608) { redraws += 1 } == nil)
        // 読めている小さい画像で代わりに描く。
        #expect(loader.anyLoaded(at: path) != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 1)
        loader.defersLoads = false
        #expect(redraws == 1)
        await loader.preload([path], pixels: 608)
        #expect(counter.count == 2)
        // 縦横比はファイルの頭から読む。
        #expect(loader.pixelSize(at: path) == NSSize(width: 640, height: 360))
    }

    @Test func レーンの幅を変えて撮る() async throws {
        let fixture = try fixture(width: 760)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        let target = try row(controller, "資料")
        try await capture("width-180", controller, scrollTo: target)
        for width in [300, 480] {
            controller.dragScreenLane(.began)
            controller.dragScreenLane(.ended(controller.transcriptDocument.laneWidth - CGFloat(width)))
            #expect(controller.transcriptDocument.laneWidth == CGFloat(width))
            try await capture("width-\(width)", controller, scrollTo: try row(controller, "資料"))
        }
    }

    // MARK: - 「+N枚」「畳む」のボタンと伸び縮み

    /// 時計を差し替え、押した時点を0秒にする。
    private func animated(_ height: CGFloat = 900) throws -> (Fixture, Clock) {
        let fixture = try fixture(height: height, reduceMotion: false)
        return (fixture, fixture.clock)
    }

    @Test func トレイの行は左右へ6ptはみ出し_文字の倍率を掛けず_読み上げで開閉の状態を伝える() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let lane = try row(controller, "なるほど").lane
        try row(controller, "なるほど").layoutSubtreeIfNeeded()
        let fold = try #require(lane.foldButtons.first)
        #expect(fold.title == "+2枚")
        #expect(fold.frame == NSRect(x: -6, y: 0, width: lane.bounds.width + 12, height: ScreenLaneFoldButton.height))
        #expect(fold.isAccessibilityExpanded() == false)
        #expect(fold.accessibilityValue() as? String == "畳んでいます")
        // 畳んだ画像の小さな見本。
        #expect(fold.miniCount == 2)
        // 文字の倍率を上げても行の高さは変わらない。レーンを広げると行はレーンの幅に合わせる。
        controller.setTextScale(TranscriptTextScale(savedValue: 200))
        controller.dragScreenLane(.began)
        controller.dragScreenLane(.ended(-120))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let wide = try row(controller, "なるほど").lane
        try row(controller, "なるほど").layoutSubtreeIfNeeded()
        let scaled = try #require(wide.foldButtons.first)
        #expect(scaled.frame.height == ScreenLaneFoldButton.height)
        #expect(scaled.frame.width == wide.bounds.width + 12 && wide.bounds.width == 272)
        scaled.performClick(nil)
        let opened = try row(controller, "なるほど").lane.foldButtons
        #expect(opened.map(\.title) == ["畳む", "畳む"])
        #expect(opened.allSatisfy { $0.isAccessibilityExpanded() == true })
        #expect(opened.allSatisfy { $0.accessibilityValue() as? String == "開いています" })
        #expect(opened.allSatisfy { $0.toolTip == "間の2枚を畳む" })
    }

    @Test func トレイは畳むと頭の行だけで_開くと末尾の畳むまでを縁で囲み_中の画像は今までどおり開ける() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        var opened: [String] = []
        controller.presentScreenPreview = { opened.append(controller.screenPreview.paths[controller.screenPreview.index]) }
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        func lane() throws -> ScreenLaneView {
            let row = try row(controller, "なるほど")
            row.layoutSubtreeIfNeeded()
            return row.lane
        }
        let head = try #require(try lane().foldButtons.first)
        let closed = try #require(try lane().trayFrame(containing: head))
        #expect(closed.height == ScreenLaneFoldButton.height)
        // 畳んだ状態では、見本の上もトレイの一部として押せる。
        let onMini = head.convert(NSPoint(x: 20, y: 14), to: head.superview)
        #expect(head.hitTest(onMini) === head)
        head.performClick(nil)
        let open = try lane()
        let buttons = open.foldButtons
        let tray = try #require(open.trayFrame(containing: buttons[0]))
        let inside = open.thumbnailViews.filter { thumbnail in
            let frame = thumbnail.convert(thumbnail.bounds, to: open)
            return frame.minY > tray.minY && frame.maxY < tray.maxY
        }
        // 頭の行・中の2枚・末尾の行。頭と末尾の行は縁にそろえる。
        #expect(inside.count == 2)
        #expect(buttons[0].convert(buttons[0].bounds, to: open).minY == tray.minY)
        #expect(buttons[1].convert(buttons[1].bounds, to: open).maxY == tray.maxY)
        // 頭の行と最初の画像、最後の画像と末尾の行の間は2pt。
        #expect(inside[0].convert(inside[0].bounds, to: open).minY - (tray.minY + ScreenLaneFoldButton.height) == 2)
        // 中の画像は今までどおりQuick Lookで開く。
        inside[0].onClick?()
        #expect(opened == [inside[0].path])
    }

    @Test(arguments: [true, false])
    func 末尾の畳むで畳むと畳んだトレイを押した行の位置に置き_頭へフォーカスを移す(reduceMotion: Bool) throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        controller.apply(try laneMeeting([(0, [2, 4, 6, 8])], paths: &paths))
        press(try button(controller, collapses: false, containing: paths["0-4"]!), fixture)
        let end = try #require(buttons(controller).first { $0.isEnd && $0.paths.contains(paths["0-4"]!) })
        // 開いた分を下まで読んで、末尾の「畳む」が表示域の下の方に見えている。
        scroll(controller, toScreenY: 360, end)
        let pressedBottom = screenY(controller, end) + end.bounds.height
        try #require(window.makeFirstResponder(end))
        end.performClick(nil)
        // 伸び縮みの間も、トレイの下端は押した行の下端に保つ。
        for step in 1...6 {
            fixture.clock.now += 0.04
            controller.stepScreenLaneTransitions()
            let head = try button(controller, collapses: false, containing: paths["0-4"]!)
            let lane = try #require(head.superview?.superview as? ScreenLaneView)
            let tray = try #require(lane.trayFrame(containing: head))
            let bottom = lane.convert(tray, to: controller.transcriptDocument).maxY - controller.scrollView.contentView.bounds.minY
            #expect(abs(bottom - pressedBottom) < 0.5, "\(step)")
        }
        fixture.settle()
        let head = try button(controller, collapses: false, containing: paths["0-4"]!)
        #expect(abs(screenY(controller, head) + head.bounds.height - pressedBottom) < 0.5)
        #expect(window.firstResponder === head)
        #expect(controller.screenLaneEndAnchor == nil)
    }

    @Test func 手前のトレイと合流する末尾の畳むでも_押した直後から押した行の位置を保ち_終わりで合流先へ引き継ぐ() throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: false)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 4, 6]), (1, [2, 4, 6])], paths: &paths))
        press(try button(controller, collapses: false, containing: paths["1-4"]!), fixture)
        // 話者の付け替えで2発言が1つに併合された。画像 → +3枚 → [畳む → 画像 → 畳む] → 画像。
        controller.apply(try laneMeeting([(0, [2, 4, 6]), (1, [2, 4, 6])], merged: true, paths: &paths))
        #expect(try button(controller, collapses: false, containing: paths["0-4"]!).paths.count == 3)
        let end = try #require(buttons(controller).first { $0.isEnd && $0.paths.contains(paths["1-4"]!) })
        scroll(controller, toScreenY: 300, end)
        let pressedBottom = screenY(controller, end) + end.bounds.height
        let lane = try #require(end.superview?.superview as? ScreenLaneView)
        /// 押した末尾の行の、いま見えている下端の画面上の位置。縮む途中の行は入れ物で切り取られている。
        func visibleBottom() throws -> CGFloat {
            let bottom = try #require(lane.visibleBottom(of: end))
            return lane.convert(NSPoint(x: 0, y: bottom), to: controller.transcriptDocument).y - controller.scrollView.contentView.bounds.minY
        }
        end.performClick(nil)
        // 押した直後は、まだ縮んでいないので動かない。
        #expect(abs(try visibleBottom() - pressedBottom) < 0.5)
        for _ in 1...4 {
            fixture.clock.now += 0.04
            controller.stepScreenLaneTransitions()
            if controller.screenLaneTransitions.isEmpty { break }
            controller.window!.contentView!.layoutSubtreeIfNeeded()
            #expect(abs(try visibleBottom() - pressedBottom) < 0.5)
        }
        fixture.settle()
        // 終わりで合流先の「+4枚」へ引き継ぐ。
        let merged = try button(controller, collapses: false, containing: paths["1-4"]!)
        #expect(merged.paths.count == 4)
        #expect(abs(screenY(controller, merged) + merged.bounds.height - pressedBottom) < 0.5)
    }

    @Test(arguments: [true, false])
    func 画面より長いトレイで頭が画面の外にあっても_末尾の畳むで畳んだトレイが押した所に収まる(reduceMotion: Bool) throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        // 間に8枚。
        controller.apply(try laneMeeting([(0, (0..<10).map { Double($0) * 2 + 1 })], paths: &paths))
        press(try button(controller, collapses: false, containing: paths["0-3"]!), fixture)
        let head = try button(controller, collapses: true, containing: paths["0-3"]!)
        let end = try #require(buttons(controller).first { $0.isEnd && $0.paths.contains(paths["0-3"]!) })
        scroll(controller, toScreenY: 380, end)
        // 頭の「畳む」は画面の上の外。
        #expect(screenY(controller, head) < 0)
        let pressedBottom = screenY(controller, end) + end.bounds.height
        end.performClick(nil)
        #expect(abs(screenY(controller, end) + end.bounds.height - pressedBottom) < 0.5 || reduceMotion)
        fixture.settle()
        let closed = try button(controller, collapses: false, containing: paths["0-3"]!)
        #expect(closed.paths.count == 8)
        #expect(abs(screenY(controller, closed) + closed.bounds.height - pressedBottom) < 0.5)
    }

    @Test func 見本の濃さは押した直後も反転の前後も途切れない() throws {
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let head = try #require(try row(controller, "なるほど").lane.foldButtons.first)
        // 開き始めは濃さ1から。
        head.performClick(nil)
        #expect(head.minisAlpha == 1)
        clock.now = 1000.01
        controller.stepScreenLaneTransitions()
        let fading = head.minisAlpha
        #expect(fading > 0 && fading < 1)
        // 途中で畳む。いまの濃さから濃くしていく。
        head.performClick(nil)
        #expect(head.minisAlpha == fading)
        clock.now = 1000.02
        controller.stepScreenLaneTransitions()
        #expect(head.minisAlpha >= fading && head.minisAlpha < fading + 0.2)
        fixture.settle()
        #expect(head.minisAlpha == 1)
        // 開いて終えた後の、通常の閉じ始めは0から。
        head.performClick(nil)
        fixture.settle()
        head.performClick(nil)
        #expect(head.minisAlpha == 0)
        clock.now += 0.01
        controller.stepScreenLaneTransitions()
        #expect(head.minisAlpha == 0)
    }

    @Test func 開き始めの見本と枚数の文言は重ならない() throws {
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let head = try #require(try row(controller, "なるほど").lane.foldButtons.first)
        head.performClick(nil)
        for step in 0...3 {
            clock.now = 1000 + Double(step) * 0.02
            controller.stepScreenLaneTransitions()
            head.layoutSubtreeIfNeeded()
            let minis = head.subviews.compactMap { $0 as? ScreenThumbnailView }.filter { !$0.isHidden && $0.alphaValue > 0 }
            if let last = minis.last { #expect(head.countX >= last.frame.maxX, "\(step)") }
        }
    }

    @Test(arguments: [10, 100])
    func 桁の多い枚数でも枚数の表示は右端の山形と畳むに重ならない(count: Int) throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: false)
        defer { fixture.close() }
        let controller = fixture.controller
        // 180ptのレーン。間に count 枚。
        controller.apply(try laneMeeting([(0, (0..<(count + 2)).map { Double($0) * 0.25 + 0.5 })], paths: &paths))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let head = try #require(buttons(controller).first)
        head.layoutSubtreeIfNeeded()
        #expect(head.title == "+\(count)枚")
        // 畳んだ状態: 「+N枚」と山形。
        #expect(head.countMaxX <= head.rightControlsX - 4)
        // 開き始め: 見本が残っている間の「N枚」と「畳む」。
        head.performClick(nil)
        for step in 0...3 {
            fixture.clock.now = 1000 + Double(step) * 0.02
            controller.stepScreenLaneTransitions()
            head.layoutSubtreeIfNeeded()
            #expect(head.countMaxX <= head.rightControlsX - 4, "\(step)")
            let minis = head.subviews.compactMap { $0 as? ScreenThumbnailView }.filter { !$0.isHidden && $0.alphaValue > 0 }
            if let last = minis.last { #expect(head.countX >= last.frame.maxX, "\(step)") }
        }
    }

    @Test func 開く途中で見本を薄くして消し_畳む途中で濃くして出す() throws {
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let head = try #require(try row(controller, "なるほど").lane.foldButtons.first)
        head.performClick(nil)
        // 頭の行は作り直さず、文言と山形を押した時点で替える。
        #expect(head.title == "畳む" && head.collapses)
        #expect(head.miniCount == 2)
        clock.now = 1000.01
        controller.stepScreenLaneTransitions()
        #expect(head.minisAlpha > 0.5)
        clock.now = 1000.06
        controller.stepScreenLaneTransitions()
        #expect(head.minisAlpha == 0)
        fixture.settle()
        #expect(head.miniCount == 0)
        head.performClick(nil)
        #expect(head.title == "+2枚" && head.miniCount == 2)
        clock.now += 0.01
        controller.stepScreenLaneTransitions()
        #expect(head.minisAlpha == 0)
        fixture.settle()
        #expect(head.minisAlpha == 1)
    }

    @Test func 見本は3枚までで_狭いレーンでは文言と重ならない分だけ出す() throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500)
        defer { fixture.close() }
        let controller = fixture.controller
        // 間に10枚。
        controller.apply(try laneMeeting([(0, (0..<12).map { Double($0) * 2 + 1 })], paths: &paths))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let head = try #require(buttons(controller).first)
        head.superview?.superview?.superview?.layoutSubtreeIfNeeded()
        head.layoutSubtreeIfNeeded()
        #expect(head.title == "+10枚")
        #expect(head.miniCount == 3)
        let shown = head.subviews.compactMap { $0 as? ScreenThumbnailView }.filter { !$0.isHidden }
        // 180ptのレーン: 3枚と「+10枚」と山形が152ptに収まる。
        #expect(shown.count == 3)
        #expect(shown.allSatisfy { $0.frame.maxX < head.bounds.width - 6 - 40 })
    }

    @Test func 開くと約0秒2で伸び_押したボタンの位置は動かず_終わりは即時の切り替えと同じ高さ() throws {
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let row = try row(controller, "なるほど")
        let lane = row.lane
        let collapsedHeight = lane.contentHeight
        let open = try #require(lane.foldButtons.first)
        scroll(controller, toScreenY: 120, open)
        let before = screenY(controller, open)
        open.performClick(nil)
        // 押した直後は始まりの高さのまま。増える2枚と末尾の「畳む」は見えていない。
        #expect(lane.isTransitioning)
        #expect(lane.contentHeight == collapsedHeight)
        #expect(lane.blockVisibles.filter { $0 == 0 }.count == 3)
        let close = try button(controller, collapses: true, containing: open.paths[0])
        #expect(abs(screenY(controller, close) - before) < 0.5)
        var heights: [CGFloat] = [lane.contentHeight]
        for step in 1...4 {
            clock.now = 1000 + Double(step) * 0.05
            controller.stepScreenLaneTransitions()
            heights.append(lane.contentHeight)
            #expect(abs(screenY(controller, close) - before) < 0.5)
        }
        // 0.2秒で終わる。途中は単調に伸びる。
        #expect(!lane.isTransitioning)
        #expect(controller.screenLaneTimer == nil)
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 })
        let expandedHeight = lane.contentHeight
        #expect(lane.thumbnailViews.count == 4)
        // 即時の並べ直しでも同じ高さ。行の高さもレーンに合っている。
        controller.refreshRows()
        #expect(lane.contentHeight == expandedHeight)
        #expect(row.frame.height >= 8 + expandedHeight + 8)
        #expect(controller.transcriptDocument.rows.contains { $0 === row })
    }

    @Test func 伸びている途中で畳むと最後の操作の状態で終わり_連打しても崩れない() throws {
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let lane = try row(controller, "なるほど").lane
        let collapsedHeight = lane.contentHeight
        let path = try #require(lane.foldButtons.first?.paths.first)
        try button(controller, collapses: false, containing: path).performClick(nil)
        clock.now = 1000.08
        controller.stepScreenLaneTransitions()
        let midway = lane.contentHeight
        #expect(midway > collapsedHeight)
        // 途中で「畳む」を押す。その時点の高さから縮み始める。
        try button(controller, collapses: true, containing: path).performClick(nil)
        #expect(lane.contentHeight == midway)
        // さらに連打する。
        try button(controller, collapses: false, containing: path).performClick(nil)
        try button(controller, collapses: true, containing: path).performClick(nil)
        clock.now = 1000.5
        controller.stepScreenLaneTransitions()
        #expect(!lane.isTransitioning)
        #expect(lane.foldButtons.map(\.title) == ["+2枚"])
        #expect(lane.thumbnailViews.count == 2)
        #expect(lane.contentHeight == collapsedHeight)
        #expect(lane.blockVisibles.allSatisfy { $0 == 1 })
        #expect(controller.screenLaneExpanded.isEmpty)
    }

    @Test func 伸び縮みの途中で行の追加_幅のドラッグ_絞り込みが重なっても崩れない() throws {
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        var state = try meeting()
        state.state = .recording
        controller.apply(state)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let lane = try row(controller, "なるほど").lane
        let path = try #require(lane.foldButtons.first?.paths.first)
        try button(controller, collapses: false, containing: path).performClick(nil)
        clock.now = 1000.05
        controller.stepScreenLaneTransitions()
        // 録音中に発言が届く。このレーンの並びは同じなので、伸び縮みは続く。
        state.utterances.append(Utterance(speaker: 0, start: 80, end: 84, text: "追加の発言です。"))
        controller.apply(state)
        #expect(lane.isTransitioning)
        // 境目をドラッグする。高さは新しい幅で測り直し、伸び縮みは続く。
        controller.dragScreenLane(.began)
        controller.dragScreenLane(.changed(-60))
        #expect(lane.isTransitioning)
        clock.now = 1000.1
        controller.stepScreenLaneTransitions()
        controller.dragScreenLane(.ended(-60))
        // 絞り込みで佐藤だけにする。田中の行は畳まれるが、レーンは終わりまで進む。
        controller.setFilter([.speaker(1)])
        clock.now = 1000.3
        controller.stepScreenLaneTransitions()
        #expect(!lane.isTransitioning)
        #expect(controller.screenLaneTimer == nil)
        controller.setFilter([])
        let shown = try row(controller, "なるほど").lane
        shown.layoutSubtreeIfNeeded()
        #expect(shown.thumbnailViews.count == 4)
        #expect(shown.thumbnailViews.allSatisfy { $0.frame.width == 212 })
        #expect(shown.blockVisibles.allSatisfy { $0 == 1 })
    }

    @Test func 視差効果を減らす設定では伸び縮みせずに切り替える() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        let lane = try row(controller, "なるほど").lane
        try #require(lane.foldButtons.first).performClick(nil)
        #expect(!lane.isTransitioning)
        #expect(controller.screenLaneTimer == nil)
        #expect(lane.thumbnailViews.count == 4)
    }

    /// クロディーヌのモックと同じ会議。`KIKIGAKI_SCREEN_LANE_IMAGES` に、2026-11-11 21:45の会議の `.captures` を渡したときだけ撮る。
    private func mockMeeting(_ folder: String) throws -> SessionSnapshot {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 21, minute: 46, second: 0))!
        // ファイル名は時分秒。21:46:00からの秒にする。
        func at(_ name: String) -> Double { Double((Int(name.dropFirst(2).prefix(2))! - 46) * 60 + Int(name.suffix(2))!) }
        func shot(_ name: String) throws -> Utterance {
            try Utterance(screenLabel: "DELL U3818DW · Google Chrome「KIKIGAKI — 声をすべてドキュメントに」",
                          imagePath: folder + "/\(name).webp", at: at(name), postedAt: base.addingTimeInterval(at(name)))
        }
        let rows: [Utterance] = [
            Utterance(speaker: 1, start: 33, end: 37, text: "その次は Google Meetとの違いについてです。"),
            try shot("214633"),
            Utterance(speaker: 0, start: 38, end: 95, text: "議事録ができるタイミングがまず1つ目の話題ですね。Google Meetはミーティングが終わるまで議事録を確認できないと思うんですけど、KIKIGAKIは最中から確認できます。"),
            try shot("214638"), try shot("214644"), try shot("214653"), try shot("214720"), try shot("214729"),
            Utterance(speaker: 1, start: 106, end: 115, text: "で、もっかい戻ります。"),
            try shot("214753")
        ]
        var state = SessionSnapshot(state: .idle, utterances: rows.sorted { $0.start < $1.start },
                                    timeline: MeetingTimeline(startedAt: base), names: SpeakerNames([0: "田中", 1: "佐藤"]))
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-screen-lane-tray.md")
        state.elapsed = 120
        return state
    }

    @Test(arguments: [180, 300])
    func トレイをモックと同じ会議で撮る(width: Int) async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] != nil,
              let folder = ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_LANE_IMAGES"],
              FileManager.default.fileExists(atPath: folder + "/214644.webp") else { return }
        // 発言の列に420ptを残してレーンを広げられる幅にする。
        let fixture = try fixture(width: CGFloat(max(520, 420 + width - 180 + 20)), height: 1300, reduceMotion: false)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try mockMeeting(folder))
        if width != 180 {
            controller.dragScreenLane(.began)
            controller.dragScreenLane(.ended(CGFloat(180 - width)))
        }
        #expect(controller.transcriptDocument.laneWidth == CGFloat(width))
        let first = { try self.row(controller, "その次は") }
        let head = { try #require(try self.row(controller, "議事録が").lane.foldButtons.first) }
        try await capture("tray-\(width)-closed", controller, scrollTo: try first())
        try head().showsHoverForCapture = true
        try await capture("tray-\(width)-hover", controller, scrollTo: try first())
        try head().showsHoverForCapture = false
        try head().performClick(nil)
        // 開く途中。モックと同じく、中の画像が半分見えている時点(進み具合0.5)を撮る。
        fixture.clock.now = 1000 + ScreenLaneTransition.duration * (1 - pow(0.5, 1.0 / 3))
        controller.stepScreenLaneTransitions()
        try await capture("tray-\(width)-opening", controller)
        fixture.settle()
        // 開いた状態は末尾の「畳む」まで入るよう、トレイのある発言から撮る。
        try await capture("tray-\(width)-open", controller, scrollTo: try row(controller, "議事録が"))
    }

    @Test func 一方の行の伸び縮みの途中で別の行を開いても_先の行は跳ねずに進む() throws {
        var paths: [String: String] = [:]
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 4, 6]), (1, [2, 4, 6])], paths: &paths))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let first = try row(controller, "発言0").lane, second = try row(controller, "発言1").lane
        try button(controller, collapses: false, containing: paths["0-4"]!).performClick(nil)
        clock.now = 1000.1
        controller.stepScreenLaneTransitions()
        let midway = first.contentHeight, visibles = first.blockVisibles
        // 先の行の途中で、後の行を開く。後の行だけが0秒から始まる。
        try button(controller, collapses: false, containing: paths["1-4"]!).performClick(nil)
        #expect(first.contentHeight == midway)
        var previous = midway
        for step in 1...5 {
            clock.now = 1000.1 + Double(step) * 0.04
            controller.stepScreenLaneTransitions()
            #expect(first.contentHeight >= previous)
            previous = first.contentHeight
        }
        #expect(zip(first.blockVisibles, visibles).allSatisfy { $0 >= $1 })
        #expect(!first.isTransitioning && !second.isTransitioning)
        // 先の行は1000秒から、後の行は1000.1秒から0.2秒。1000.3秒で両方終わる。
        #expect(controller.screenLaneTimer == nil)
    }

    @Test func 伸び縮みの途中で最新の発言へを押すと確定して末尾へ移り_次の発言にも追従する() throws {
        var paths: [String: String] = [:]
        let (fixture, clock) = try animated(460)
        defer { fixture.close() }
        let controller = fixture.controller
        var state = try laneMeeting([(0, [2, 4, 6, 8, 10])], paths: &paths)
        state.state = .recording
        controller.apply(state)
        let document = controller.transcriptDocument
        let open = try button(controller, collapses: false, containing: paths["0-4"]!)
        scroll(controller, toScreenY: 80, open)
        open.performClick(nil)
        clock.now = 1000.05
        controller.stepScreenLaneTransitions()
        controller.latestPressed()
        #expect(document.anchor().atBottom)
        #expect(controller.screenLaneTimer == nil)
        // 残りの伸び縮みは確定済みなので、末尾から離れない。
        clock.now = 1000.3
        controller.stepScreenLaneTransitions()
        #expect(document.anchor().atBottom)
        // 新しい発言が届くと末尾へ追従する。
        state.utterances.append(Utterance(speaker: 1, start: 500, end: 505, text: "新しい発言です。"))
        state.elapsed = 510
        controller.apply(state)
        #expect(document.anchor().atBottom)
        #expect(abs(controller.scrollView.contentView.bounds.maxY - document.frame.height) < 0.5)
    }

    @Test func 伸び縮みの途中で視差効果を減らす設定にすると最後の状態でそろう() throws {
        let (fixture, clock) = try animated()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let row = try row(controller, "なるほど")
        try #require(row.lane.foldButtons.first).performClick(nil)
        clock.now = 1000.05
        controller.stepScreenLaneTransitions()
        #expect(row.lane.isTransitioning)
        fixture.motion.reduce = true
        controller.motionChanged()
        #expect(!row.lane.isTransitioning)
        #expect(controller.screenLaneTimer == nil)
        #expect(row.lane.blockVisibles.allSatisfy { $0 == 1 })
        #expect(row.lane.thumbnailViews.count == 4)
        // 行の高さも最後の状態に合っている。
        let height = row.frame.height
        controller.refreshRows()
        #expect(row.frame.height == height)
    }

    @Test func 伸び縮みの途中でウィンドウを解放するとタイマーを止める() throws {
        weak var timer: Timer?
        weak var released: TranscriptWindowController?
        try autoreleasepool {
            let fixture = try fixture(reduceMotion: false)
            fixture.controller.apply(try meeting())
            try #require(try row(fixture.controller, "なるほど").lane.foldButtons.first).performClick(nil)
            timer = fixture.controller.screenLaneTimer
            #expect(timer?.isValid == true)
            released = fixture.controller
            // 後片付けで伸び縮みを確定しない。解放だけでタイマーが止まることを確かめる。
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            fixture.controller.minutesSplit.preview.stop()
        }
        #expect(released == nil)
        #expect(timer?.isValid != true)
    }

    // MARK: - 開閉の入れ替わりとスクロール

    /// 発言の前後に画像の無い発言を並べ、開閉で縮んでもスクロールの上限で詰まらない会議。
    /// - lanes: 発言ごとの (話者, 画像の秒)。発言は10秒ずつ、画像はその発言の区間の中に置く
    /// - trailing: 後ろに置く画像の無い発言の数。末尾が見えている場面では減らす
    private func laneMeeting(_ lanes: [(speaker: Int, images: [Double])], merged: Bool = false, trailing: Int = 8,
                             paths: inout [String: String]) throws -> SessionSnapshot {
        var rows: [Utterance] = (0..<8).map { Utterance(speaker: 1, start: Double($0) * 10, end: Double($0) * 10 + 8, text: "前置き\($0)") }
        let base = 100.0
        // キーごとに別の画像を割り当てる。撮影用の実画像のフォルダでは先頭から並べて返すので、
        // 1枚ずつ取ると全キーが同じパスになる。要る枚数をまとめて取り、まだ使っていない分を割り当てる。
        let keys = lanes.enumerated().flatMap { index, lane in lane.images.map { "\(index)-\(Int($0))" } }
        let missing = keys.filter { paths[$0] == nil }
        if !missing.isEmpty {
            let pool = try images(paths.count + missing.count)
            let used = Set(paths.values)
            for (key, path) in zip(missing, pool.filter { !used.contains($0) }) { paths[key] = path }
        }
        for (index, lane) in lanes.enumerated() {
            let start = base + Double(index) * 40
            if !merged {
                rows.append(Utterance(speaker: lane.speaker, start: start, end: start + 30, text: "発言\(index)"))
            }
            for offset in lane.images {
                rows.append(try screen(try #require(paths["\(index)-\(Int(offset))"]), at: start + offset))
            }
        }
        if merged {
            rows.append(Utterance(speaker: 0, start: base, end: base + Double(lanes.count) * 40 - 10, text: "発言0"))
        }
        rows += (0..<trailing).map { Utterance(speaker: 1, start: 400 + Double($0) * 10, end: 408 + Double($0) * 10, text: "後置き\($0)") }
        var state = SessionSnapshot(state: .idle, utterances: rows.sorted { $0.start < $1.start },
                                    timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "田中", 1: "佐藤"]))
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-screen-lane-toggle.md")
        state.elapsed = 500
        return state
    }

    private func buttons(_ controller: TranscriptWindowController) -> [ScreenLaneFoldButton] {
        controller.transcriptDocument.rows.flatMap { row -> [ScreenLaneFoldButton] in
            ((row as? TranscriptRow)?.lane ?? (row as? ScreenLaneRow)?.lane)?.foldButtons ?? []
        }
    }
    private func button(_ controller: TranscriptWindowController, collapses: Bool, containing path: String) throws -> ScreenLaneFoldButton {
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        return try #require(buttons(controller).first { $0.collapses == collapses && $0.paths.contains(path) })
    }
    private func screenY(_ controller: TranscriptWindowController, _ view: NSView) -> CGFloat {
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        return view.convert(view.bounds, to: controller.transcriptDocument).minY - controller.scrollView.contentView.bounds.minY
    }
    private func scroll(_ controller: TranscriptWindowController, toScreenY y: CGFloat, _ view: NSView) {
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let documentY = view.convert(view.bounds, to: controller.transcriptDocument).minY
        controller.transcriptDocument.scroll(NSPoint(x: 0, y: max(0, documentY - y)))
        controller.scrolled()
    }

    @Test(arguments: [true, false])
    func 併合で手前の枚数の行と1つにまとまっても_入れ替わった枚数の行を押した位置に置く(reduceMotion: Bool) throws {
        // 画像3枚ずつの2発言で、それぞれ中央を開く。
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 4, 6]), (1, [2, 4, 6])], paths: &paths))
        press(try button(controller, collapses: false, containing: paths["0-4"]!), fixture)
        press(try button(controller, collapses: false, containing: paths["1-4"]!), fixture)
        // 話者の付け替えで2発言が1つに併合された。画像1 → 畳む → 画像2 → +2枚 → 畳む → 画像5 → 画像6。
        controller.apply(try laneMeeting([(0, [2, 4, 6]), (1, [2, 4, 6])], merged: true, paths: &paths))
        let later = try button(controller, collapses: true, containing: paths["1-4"]!)
        #expect(try button(controller, collapses: false, containing: paths["0-6"]!).paths.count == 2)
        // 表示域の中で押す。
        scroll(controller, toScreenY: 200, later)
        let before = screenY(controller, later)
        press(later, fixture)
        let restored = try button(controller, collapses: false, containing: paths["1-4"]!)
        #expect(restored.paths.count == 3)
        #expect(abs(screenY(controller, restored) - before) < 0.5)
        // 表示域の上へ出たボタンを押す(キーボード・読み上げ)。相手は表示域の上端へ寄せる。
        // 「+3枚」から開き直すと手前の開いた区間とつながるので、2つ目の中央だけを開いた状態を作り直す。
        controller.screenLaneExpanded = [paths["0-4"]!, paths["1-4"]!]
        controller.refreshRows()
        #expect(try button(controller, collapses: false, containing: paths["0-6"]!).paths.count == 2)
        let hidden = try button(controller, collapses: true, containing: paths["1-4"]!)
        #expect(hidden.paths == [paths["1-4"]!])
        scroll(controller, toScreenY: -150, hidden)
        #expect(screenY(controller, hidden) < 0)
        press(hidden, fixture)
        #expect(abs(screenY(controller, try button(controller, collapses: false, containing: paths["1-4"]!)) - 8) < 0.5)
    }

    @Test(arguments: [true, false])
    func キーボードで開閉すると入れ替わったボタンへフォーカスを移し_続けて開閉できる(reduceMotion: Bool) throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        controller.apply(try laneMeeting([(0, [2, 4, 6])], paths: &paths))
        let open = try button(controller, collapses: false, containing: paths["0-4"]!)
        scroll(controller, toScreenY: 200, open)
        try #require(window.makeFirstResponder(open))
        press(open, fixture)
        let close = try button(controller, collapses: true, containing: paths["0-4"]!)
        #expect(window.firstResponder === close)
        press(close, fixture)
        let reopened = try button(controller, collapses: false, containing: paths["0-4"]!)
        #expect(window.firstResponder === reopened)
        // マウスで押した場合(フォーカスが別にある)は動かさない。
        window.makeFirstResponder(controller.searchField)
        press(reopened, fixture)
        #expect(!(window.firstResponder is ScreenLaneFoldButton))
    }

    @Test(arguments: [true, false])
    func 開いた後の画像の追加と割り当て先の変更を挟んでも畳め_会議を切り替えると閉じる(reduceMotion: Bool) throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 5, 8])], paths: &paths))
        press(try button(controller, collapses: false, containing: paths["0-5"]!), fixture)
        // 画像が増え、最後だった8秒の画像が間に入る。開いた5秒の画像は開いたまま、新しく間に入った画像は別に畳む。
        controller.apply(try laneMeeting([(0, [2, 5, 8, 9])], paths: &paths))
        #expect(try button(controller, collapses: true, containing: paths["0-5"]!).paths == [paths["0-5"]!])
        #expect(try button(controller, collapses: false, containing: paths["0-8"]!).paths == [paths["0-8"]!])
        // 割り当て先が変わる: 4〜6秒の画像に重なる別の発言が入り、5秒の画像はそちらの間の画像になる。
        controller.apply(try laneMeeting([(0, [2, 4, 5, 6, 8, 9])], paths: &paths))
        var state = try laneMeeting([(0, [2, 4, 5, 6, 8, 9])], paths: &paths)
        state.utterances.append(Utterance(speaker: 1, start: 103.5, end: 106.5, text: "割り込み"))
        state.utterances.sort { $0.start < $1.start }
        controller.apply(state)
        let moved = try button(controller, collapses: true, containing: paths["0-5"]!)
        #expect(moved.paths == [paths["0-5"]!])
        scroll(controller, toScreenY: 160, moved)
        let before = screenY(controller, moved)
        press(moved, fixture)
        #expect(!controller.screenLaneExpanded.contains(paths["0-5"]!))
        #expect(abs(screenY(controller, try button(controller, collapses: false, containing: paths["0-5"]!)) - before) < 0.5)
        // 会議を切り替えると開いた覚えを捨てる。伸び縮みの途中で切り替えても、前の会議の伸び縮みは残らない。
        try button(controller, collapses: false, containing: paths["0-8"]!).performClick(nil)
        #expect(!controller.screenLaneExpanded.isEmpty)
        var next = try laneMeeting([(0, [2, 5, 8, 9])], paths: &paths)
        next.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(next)
        #expect(controller.screenLaneExpanded.isEmpty)
        #expect(buttons(controller).allSatisfy { !$0.collapses })
        #expect(controller.screenLaneTimer == nil && controller.screenLaneTransitions.isEmpty)
    }

    @Test(arguments: [true, false])
    func 末尾を読んでいても開閉で末尾へ飛ばず_末尾が見えていて縮むときは上限で詰まる(reduceMotion: Bool) throws {
        var paths: [String: String] = [:]
        // 末尾まで下ろしたままで「+1枚」が表示域に入る高さにする。
        let fixture = try fixture(height: 800, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 4, 6])], trailing: 1, paths: &paths))
        let document = controller.transcriptDocument
        // 末尾へ追従している状態のまま、表示域の中の「+1枚」を開く。末尾へは移らず、相手を同じ位置に置く。
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        controller.scrolled()
        let open = try button(controller, collapses: false, containing: paths["0-4"]!)
        let before = screenY(controller, open)
        let clipHeight = controller.scrollView.contentView.bounds.height
        try #require(before >= 0 && before < clipHeight)
        #expect(document.anchor().atBottom && document.followsBottom)
        press(open, fixture)
        let close = try button(controller, collapses: true, containing: paths["0-4"]!)
        #expect(abs(screenY(controller, close) - before) < 0.5)
        #expect(!document.anchor().atBottom)
        // 文書の末尾が見えている状態で畳むと、縮んだ分はスクロールの上限で詰まり、相手は下へずれる(受け入れた限界)。
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        controller.scrolled()
        let atEnd = screenY(controller, close)
        press(close, fixture)
        let restored = try button(controller, collapses: false, containing: paths["0-4"]!)
        let clip = controller.scrollView.contentView.bounds
        #expect(abs(clip.maxY - document.frame.height) < 0.5)
        #expect(screenY(controller, restored) > atEnd)
    }

    @Test(arguments: [true, false])
    func 検索中と絞り込み中も同じ位置で開閉する(reduceMotion: Bool) throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500, reduceMotion: reduceMotion)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 4, 6])], paths: &paths))
        controller.showSearch(nil)
        controller.searchField.stringValue = "前置き"
        controller.refreshSearch(reset: true, reveal: false)
        let open = try button(controller, collapses: false, containing: paths["0-4"]!)
        scroll(controller, toScreenY: 180, open)
        let before = screenY(controller, open)
        press(open, fixture)
        let close = try button(controller, collapses: true, containing: paths["0-4"]!)
        #expect(abs(screenY(controller, close) - before) < 0.5)
        #expect(controller.searchOpen && !controller.searchHits.isEmpty)
        controller.closeSearch(nil)
        // 田中だけに絞り込む。前後の佐藤の発言は線に畳まれる。
        controller.setFilter([.speaker(0)])
        let filtered = try button(controller, collapses: true, containing: paths["0-4"]!)
        scroll(controller, toScreenY: 120, filtered)
        let filteredBefore = screenY(controller, filtered)
        press(filtered, fixture)
        #expect(abs(screenY(controller, try button(controller, collapses: false, containing: paths["0-4"]!)) - filteredBefore) < 0.5)
        #expect(controller.filterSelection == [.speaker(0)])
    }
}
}
