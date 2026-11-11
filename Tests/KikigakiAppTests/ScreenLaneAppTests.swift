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

    private struct Fixture {
        let controller: TranscriptWindowController
        let defaults: UserDefaults
        let suite: String
        @MainActor func close() { defaults.removePersistentDomain(forName: suite); controller.minutesSplit.preview.stop() }
    }

    private func fixture(width: CGFloat = 640, height: CGFloat = 900) throws -> Fixture {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "screen-lane-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        controller.minutesSplit.visibleScreen = { _ in Self.screen }
        controller.presentScreenPreview = {}
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: 0, y: 100))
        window.setFrame(NSRect(x: 0, y: 100, width: width, height: height), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        return Fixture(controller: controller, defaults: defaults, suite: suite)
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
        // 「+2枚」があった位置に、同じ見た目の「畳む」が替わって出る。
        #expect(expanded.lane.foldButtons.map(\.title) == ["畳む"])
        #expect(expanded.lane.foldButtons[0].frame.minY == foldY)
        #expect(expanded.lane.foldButtons[0].toolTip == "間の2枚を畳む")
        try await capture("expanded", controller, scrollTo: expanded)
    }

    @Test func 畳むは開いた覚えを消して同じ位置に枚数の行を戻し_Quick_Lookには触れない() throws {
        // 文書の末尾が表示域に入ると、縮んだ分はスクロールの上限で詰まる。下に内容が残る高さで確かめる。
        let fixture = try fixture(height: 460)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try meeting())
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let document = controller.transcriptDocument
        func lane() throws -> ScreenLaneView { try row(controller, "なるほど").lane }
        func screenY(_ view: NSView) -> CGFloat {
            view.convert(view.bounds, to: document).minY - controller.scrollView.contentView.bounds.minY
        }
        try lane().foldButtons[0].performClick(nil)
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
        collapse.performClick(nil)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let restored = try lane().foldButtons[0]
        #expect(restored.title == "+2枚")
        #expect(abs(screenY(restored) - before) < 0.5)
        #expect(controller.screenLaneExpanded.isEmpty)
        #expect(controller.screenPreview.paths == previewPaths && controller.screenPreview.index == 3)
        #expect(try lane().thumbnailViews.count == 2)
        // 「畳む」が表示域の上へ出ている: 畳んだ後の「+2枚」を表示域の上端へ寄せる。
        try lane().foldButtons[0].performClick(nil)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let hidden = try lane().foldButtons[0]
        document.scroll(NSPoint(x: 0, y: hidden.convert(hidden.bounds, to: document).minY + 120))
        controller.scrolled()
        #expect(screenY(hidden) < 0)
        hidden.performClick(nil)
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
        window.setFrame(NSRect(x: Self.screen.maxX - 700, y: 100, width: 700, height: 900), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
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
        let thumbnails = lane.thumbnailViews
        #expect(thumbnails.map(\.frame.size) == [NSSize(width: 152, height: 63), NSSize(width: 152, height: 152)])
        let captions = lane.subviews.compactMap { $0 as? NSTextField }.sorted { $0.frame.minY < $1.frame.minY }
        try #require(captions.count == 2)
        let gapBelowImage = captions[0].frame.minY - thumbnails[0].frame.maxY
        let gapToNext = thumbnails[1].frame.minY - captions[0].frame.maxY
        #expect(gapBelowImage == 3)
        #expect(gapToNext == 12)
        #expect(gapToNext > gapBelowImage * 2)
        #expect(captions[1].frame.minY == thumbnails[1].frame.maxY + 3)
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

    @Test func 併合で手前の枚数の行と1つにまとまっても_入れ替わった枚数の行を押した位置に置く() throws {
        // 画像3枚ずつの2発言で、それぞれ中央を開く。
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 4, 6]), (1, [2, 4, 6])], paths: &paths))
        try button(controller, collapses: false, containing: paths["0-4"]!).performClick(nil)
        try button(controller, collapses: false, containing: paths["1-4"]!).performClick(nil)
        // 話者の付け替えで2発言が1つに併合された。画像1 → 畳む → 画像2 → +2枚 → 畳む → 画像5 → 画像6。
        controller.apply(try laneMeeting([(0, [2, 4, 6]), (1, [2, 4, 6])], merged: true, paths: &paths))
        let later = try button(controller, collapses: true, containing: paths["1-4"]!)
        #expect(try button(controller, collapses: false, containing: paths["0-6"]!).paths.count == 2)
        // 表示域の中で押す。
        scroll(controller, toScreenY: 200, later)
        let before = screenY(controller, later)
        later.performClick(nil)
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
        hidden.performClick(nil)
        #expect(abs(screenY(controller, try button(controller, collapses: false, containing: paths["1-4"]!)) - 8) < 0.5)
    }

    @Test func キーボードで開閉すると入れ替わったボタンへフォーカスを移し_続けて開閉できる() throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500)
        defer { fixture.close() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        controller.apply(try laneMeeting([(0, [2, 4, 6])], paths: &paths))
        let open = try button(controller, collapses: false, containing: paths["0-4"]!)
        scroll(controller, toScreenY: 200, open)
        try #require(window.makeFirstResponder(open))
        open.performClick(nil)
        let close = try button(controller, collapses: true, containing: paths["0-4"]!)
        #expect(window.firstResponder === close)
        close.performClick(nil)
        let reopened = try button(controller, collapses: false, containing: paths["0-4"]!)
        #expect(window.firstResponder === reopened)
        // マウスで押した場合(フォーカスが別にある)は動かさない。
        window.makeFirstResponder(controller.searchField)
        reopened.performClick(nil)
        #expect(!(window.firstResponder is ScreenLaneFoldButton))
    }

    @Test func 開いた後の画像の追加と割り当て先の変更を挟んでも畳め_会議を切り替えると閉じる() throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 5, 8])], paths: &paths))
        try button(controller, collapses: false, containing: paths["0-5"]!).performClick(nil)
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
        moved.performClick(nil)
        #expect(!controller.screenLaneExpanded.contains(paths["0-5"]!))
        #expect(abs(screenY(controller, try button(controller, collapses: false, containing: paths["0-5"]!)) - before) < 0.5)
        // 会議を切り替えると開いた覚えを捨てる。
        try button(controller, collapses: false, containing: paths["0-8"]!).performClick(nil)
        #expect(!controller.screenLaneExpanded.isEmpty)
        var next = try laneMeeting([(0, [2, 5, 8, 9])], paths: &paths)
        next.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(next)
        #expect(controller.screenLaneExpanded.isEmpty)
        #expect(buttons(controller).allSatisfy { !$0.collapses })
    }

    @Test func 末尾を読んでいても開閉で末尾へ飛ばず_末尾が見えていて縮むときは上限で詰まる() throws {
        var paths: [String: String] = [:]
        // 末尾まで下ろしたままで「+1枚」が表示域に入る高さにする。
        let fixture = try fixture(height: 800)
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
        open.performClick(nil)
        let close = try button(controller, collapses: true, containing: paths["0-4"]!)
        #expect(abs(screenY(controller, close) - before) < 0.5)
        #expect(!document.anchor().atBottom)
        // 文書の末尾が見えている状態で畳むと、縮んだ分はスクロールの上限で詰まり、相手は下へずれる(受け入れた限界)。
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        controller.scrolled()
        let atEnd = screenY(controller, close)
        close.performClick(nil)
        let restored = try button(controller, collapses: false, containing: paths["0-4"]!)
        let clip = controller.scrollView.contentView.bounds
        #expect(abs(clip.maxY - document.frame.height) < 0.5)
        #expect(screenY(controller, restored) > atEnd)
    }

    @Test func 検索中と絞り込み中も同じ位置で開閉する() throws {
        var paths: [String: String] = [:]
        let fixture = try fixture(height: 500)
        defer { fixture.close() }
        let controller = fixture.controller
        controller.apply(try laneMeeting([(0, [2, 4, 6])], paths: &paths))
        controller.showSearch(nil)
        controller.searchField.stringValue = "前置き"
        controller.refreshSearch(reset: true, reveal: false)
        let open = try button(controller, collapses: false, containing: paths["0-4"]!)
        scroll(controller, toScreenY: 180, open)
        let before = screenY(controller, open)
        open.performClick(nil)
        let close = try button(controller, collapses: true, containing: paths["0-4"]!)
        #expect(abs(screenY(controller, close) - before) < 0.5)
        #expect(controller.searchOpen && !controller.searchHits.isEmpty)
        controller.closeSearch(nil)
        // 田中だけに絞り込む。前後の佐藤の発言は線に畳まれる。
        controller.setFilter([.speaker(0)])
        let filtered = try button(controller, collapses: true, containing: paths["0-4"]!)
        scroll(controller, toScreenY: 120, filtered)
        let filteredBefore = screenY(controller, filtered)
        filtered.performClick(nil)
        #expect(abs(screenY(controller, try button(controller, collapses: false, containing: paths["0-4"]!)) - filteredBefore) < 0.5)
        #expect(controller.filterSelection == [.speaker(0)])
    }
}
}
