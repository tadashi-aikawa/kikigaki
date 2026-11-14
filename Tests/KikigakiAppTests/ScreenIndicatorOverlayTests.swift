import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
/// 撮っているディスプレイの上のバッジと知らせ。仕様は docs/screen-capture.md の「撮っている画面の印」
///
/// `KIKIGAKI_UI_CAPTURE=<出力先>` で、バッジと3通りの知らせを撮る。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ScreenIndicatorOverlayTests {
    private func mainDisplay() throws -> (ScreenDisplay, NSScreen) {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        return (ScreenDisplay(id: number.uint32Value, name: screen.localizedName, points: screen.frame.size, menuBarFraction: 0), screen)
    }

    private func wait(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func パネルはクリックを素通りさせ_キーを取らず_全画面の上にも出る() {
        let panel = IndicatorPanel()
        #expect(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.level == .statusBar && !panel.hidesOnDeactivate && panel.sharingType == .none)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func 撮り始めたら中央に知らせを出し_着いたら右下にバッジを残す() async throws {
        let (display, screen) = try mainDisplay()
        let overlay = ScreenIndicatorOverlay()
        defer { overlay.update(.hidden, fallback: nil); overlay.noticePanel.orderOut(nil) }
        overlay.update(.on(display), fallback: nil)
        #expect(overlay.notice == .started(display))
        #expect(overlay.noticePanel.isVisible && overlay.noticePanel.frame == screen.frame)
        #expect(!overlay.badgePanel.isVisible)
        let chip = try #require(overlay.noticePanel.chipLayer)
        #expect(abs(chip.position.x - screen.frame.width / 2) <= 0.5 && chip.bounds.height == ScreenIndicatorLayout.noticeHeight)

        try await wait(ScreenIndicatorOverlay.noticeHold + ScreenIndicatorOverlay.moveDuration + 0.6)
        #expect(overlay.notice == nil && !overlay.noticePanel.isVisible)
        #expect(overlay.badgePanel.isVisible)
        let badge = overlay.badgePanel.frame
        #expect(abs(badge.maxX - (screen.frame.maxX - ScreenIndicatorLayout.badgeInset)) <= 0.5)
        #expect(abs(badge.minY - (screen.frame.minY + ScreenIndicatorLayout.badgeInset)) <= 0.5)
        #expect(badge.height == ScreenIndicatorLayout.badgeHeight)

        // 止めたら、バッジをその場で消して止めた知らせを出す。
        overlay.update(.hidden, fallback: nil)
        #expect(!overlay.badgePanel.isVisible && overlay.notice == .stopped(display) && overlay.noticePanel.isVisible)
        try await wait(ScreenIndicatorOverlay.noticeHold + ScreenIndicatorOverlay.fadeDuration + 0.6)
        #expect(overlay.notice == nil && !overlay.noticePanel.isVisible && !overlay.badgePanel.isVisible)
    }

    @Test func 撮り始めた知らせの途中で止めたら_バッジを出さずに止めた知らせへ替える() async throws {
        let (display, _) = try mainDisplay()
        let overlay = ScreenIndicatorOverlay()
        defer { overlay.update(.hidden, fallback: nil); overlay.noticePanel.orderOut(nil) }
        overlay.update(.on(display), fallback: nil)
        overlay.update(.hidden, fallback: nil)
        #expect(overlay.notice == .stopped(display))
        try await wait(ScreenIndicatorOverlay.noticeHold + ScreenIndicatorOverlay.moveDuration + 0.6)
        #expect(!overlay.badgePanel.isVisible)
    }

    @Test func 撮り始めた知らせの途中で替え始めたら_知らせを片付けて撮らないでも何も残さない() async throws {
        let (display, _) = try mainDisplay()
        let overlay = ScreenIndicatorOverlay()
        defer { overlay.update(.hidden, fallback: nil); overlay.noticePanel.orderOut(nil) }
        overlay.update(.on(display), fallback: nil)
        overlay.update(.switching(display), fallback: nil)
        #expect(overlay.notice == nil && !overlay.noticePanel.isVisible && !overlay.badgePanel.isVisible)
        overlay.update(.hidden, fallback: nil)
        try await wait(ScreenIndicatorOverlay.noticeHold + ScreenIndicatorOverlay.moveDuration + 0.6)
        #expect(overlay.notice == nil && !overlay.noticePanel.isVisible && !overlay.badgePanel.isVisible)
    }

    @Test func 止めた知らせの途中で再開を待ち始めても_止めた知らせは残す() throws {
        let (display, _) = try mainDisplay()
        let overlay = ScreenIndicatorOverlay()
        defer { overlay.update(.hidden, fallback: nil); overlay.noticePanel.orderOut(nil) }
        overlay.update(.on(display), fallback: nil)
        overlay.update(.hidden, fallback: nil)
        overlay.update(.switching(display), fallback: nil)
        #expect(overlay.notice == .stopped(display) && overlay.noticePanel.isVisible)
    }

    @Test func 止めた知らせが消える途中で撮り始めたら_新しい知らせは薄れない() async throws {
        let (display, _) = try mainDisplay()
        let overlay = ScreenIndicatorOverlay()
        defer { overlay.update(.hidden, fallback: nil); overlay.noticePanel.orderOut(nil) }
        overlay.update(.on(display), fallback: nil)
        overlay.update(.hidden, fallback: nil)
        // 止めた知らせが薄れ始めた所で、撮り始める。
        try await wait(ScreenIndicatorOverlay.noticeHold + ScreenIndicatorOverlay.fadeDuration / 3)
        overlay.update(.on(display), fallback: nil)
        try await wait(ScreenIndicatorOverlay.fadeDuration + 0.2)
        #expect(overlay.notice == .started(display) && overlay.noticePanel.isVisible && overlay.noticePanel.alphaValue == 1)
    }

    @Test func 外れたディスプレイが撮れなくなったら_書き起こしウィンドウの画面へ知らせを出す() throws {
        let (_, screen) = try mainDisplay()
        let gone = ScreenDisplay(id: 0x7fff_fff0, name: "外したディスプレイ", points: CGSize(width: 1, height: 1), menuBarFraction: 0)
        let overlay = ScreenIndicatorOverlay()
        defer { overlay.noticePanel.orderOut(nil) }
        overlay.update(.on(gone), fallback: screen)
        // 撮っている画面が無ければ、撮り始めた知らせもバッジも出さない。
        #expect(overlay.notice == nil && !overlay.noticePanel.isVisible && !overlay.badgePanel.isVisible)
        overlay.update(.failed(gone), fallback: screen)
        #expect(overlay.notice == .unavailable(gone) && overlay.noticePanel.frame == screen.frame)
    }

    @Test func 知らせとバッジの文言と幅() throws {
        #expect(IndicatorChip.text(.recording, .badge) == "記録中")
        #expect(IndicatorChip.text(.recording, .notice) == "画面を記録中")
        #expect(IndicatorChip.text(.stopped, .notice) == "画面の記録を停止")
        #expect(IndicatorChip.text(.unavailable, .notice) == "画面を記録できません")
        let badge = IndicatorChip(kind: .recording, size: .badge, scale: 2)
        let notice = IndicatorChip(kind: .recording, size: .notice, scale: 2)
        #expect(badge.width > 40 && badge.width < 80)
        #expect(notice.width > badge.width * 2)
        #expect(badge.layer.bounds.height == ScreenIndicatorLayout.badgeHeight)

        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        let chips: [(String, IndicatorChip)] = [
            ("badge", badge), ("notice-recording", notice),
            ("notice-stopped", IndicatorChip(kind: .stopped, size: .notice, scale: 2)),
            ("notice-unavailable", IndicatorChip(kind: .unavailable, size: .notice, scale: 2)),
        ]
        for (name, chip) in chips {
            // 生成りの背景に、余白を付けて2倍で描く。
            let margin: CGFloat = 12, scale: CGFloat = 2
            let size = CGSize(width: chip.width + margin * 2, height: chip.layer.bounds.height + margin * 2)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(Washi.paper.cgColor); context.fill(CGRect(origin: .zero, size: size))
            context.translateBy(x: margin, y: margin)
            chip.layer.position = CGPoint(x: chip.width / 2, y: chip.layer.bounds.height / 2)
            chip.layer.render(in: context)
            // 描画キャッシュの中間物。確認用はcwebpで非可逆WebPへ変換する。
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("screen-indicator-\(name).png"))
        }
    }
}
}
