import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized) @MainActor struct StartSheetSpeakerChipTests {
    @Test func 一覧の札は強調中に白へ切り替わり解除すると紫へ戻る() throws {
        _ = NSApplication.shared
        let item = HighlightableMenuItem(title: "議事録", action: nil, keyEquivalent: "")
        let title = SpeakerEstimationChip.attachment(for: item)
        let attachment = try #require(title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let image = try #require(attachment.image)
        // 同じ添付を往復させ、前の色がキャッシュに残る退行も検出する。
        for highlighted in [false, true, false, true, false] {
            item.highlightedForTesting = highlighted
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = image.size
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            var white = 0, purple = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.5 else { continue }
                    if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 { white += 1 }
                    if color.blueComponent > color.redComponent + 0.05,
                       color.redComponent > color.greenComponent + 0.05 { purple += 1 }
                }
            }
            #expect(highlighted ? white > 100 && purple == 0 : purple > 100 && white == 0)
        }
    }

    @Test func 推定ありだけに札を出し選び直しで追従して高さを保つ() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = [true, false].enumerated().map { index, enabled in
            ResolvedAIConfig(config: AIConfig(name: enabled ? "議事録" : "相談", command: "/bin/echo",
                cwd: root.path, initialPrompt: "決定事項をまとめてください", autoStart: index == 0,
                identifySpeakers: enabled), home: root, slot: index + 1)
        }
        let suite = "StartSheetSpeakerChipTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sheet = StartSheet(profiles: list, diarizationEnabled: true, exclusion: AudioExclusion(),
                               defaults: defaults, microphoneName: { "テスト用マイク" })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.orderFront(nil)
        sheet.present(on: parent)
        defer { sheet.close(); parent.orderOut(nil) }
        let frame = sheet.window.frame
        let buttonHeight = sheet.destination.frame.height
        #expect(try titleHasInkNearAvatar(sheet.destination))
        for popup in [sheet.destination, sheet.manualDestination] {
            let items = try #require(popup.menu?.items)
            #expect(items[0].attributedTitle == nil)
            #expect(items[0].accessibilityLabel()?.contains("話者名を推定") != true)
            #expect(items[1].accessibilityLabel()?.contains("話者名を推定") == true)
            var attachments = 0
            items[1].attributedTitle?.enumerateAttribute(.attachment,
                in: NSRange(location: 0, length: items[1].attributedTitle?.length ?? 0)) { value, _, _ in
                if value is NSTextAttachment { attachments += 1 }
            }
            #expect(attachments == 1)
            var disabledAttachments = 0
            items[2].attributedTitle?.enumerateAttribute(.attachment,
                in: NSRange(location: 0, length: items[2].attributedTitle?.length ?? 0)) { value, _, _ in
                if value is NSTextAttachment { disabledAttachments += 1 }
            }
            #expect(disabledAttachments == 0)
            #expect(items[2].accessibilityLabel()?.contains("話者名を推定") != true)
        }
        try await capture("with-estimation", sheet)
        try captureMenu(sheet.destination)
        for slot in [2, 0, 1] {
            for popup in [sheet.destination, sheet.manualDestination] {
                popup.selectItem(withTag: slot)
                #expect(popup.sendAction(popup.action, to: popup.target))
                sheet.window.contentView?.layoutSubtreeIfNeeded()
                #expect(popup.showsSpeakerEstimation == (slot == 1))
                #expect((popup.accessibilityValue() as? String)?.contains("話者名を推定") == (slot == 1))
                #expect(sheet.window.frame == frame)
                #expect(sheet.destination.frame.height == buttonHeight)
            }
            if slot == 2 {
                try await capture("without-estimation", sheet)
                try captureMenu(sheet.destination, name: "destination-menu-unhighlighted")
            }
        }
        // 札のある宛先でも送信の指定・文面はそのまま。
        #expect(sheet.options?.scheduleSlot == 1 && sheet.options?.manualSlot == 1)
        #expect(sheet.options?.schedule?.prompt == list[0].initialPrompt)
    }

    @Test func 札の有無で初期シート高が変わらず長い宛先名でも札を残す() throws {
        _ = NSApplication.shared
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "StartSheetSpeakerChipTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let longName = String(repeating: "会議の議事録", count: 20)
        func sheet(_ enabled: Bool) -> StartSheet {
            let profile = ResolvedAIConfig(config: AIConfig(name: longName, command: "/bin/echo",
                cwd: root.path, initialPrompt: "決定事項", autoStart: true, identifySpeakers: enabled), home: root, slot: 1)
            return StartSheet(profiles: [profile], diarizationEnabled: true, exclusion: AudioExclusion(), defaults: defaults)
        }
        let enabled = sheet(true), disabled = sheet(false)
        defer { enabled.close(); disabled.close() }
        #expect(enabled.window.frame.height == disabled.window.frame.height)
        let menu = try #require(enabled.destination.menu)
        let title = try #require(menu.items[1].attributedTitle)
        let firstLine = try #require(title.string.split(separator: "\n").first)
        #expect(firstLine.contains("…") && firstLine.contains("\u{fffc}"))
        #expect(enabled.destination.showsSpeakerEstimation && enabled.manualDestination.showsSpeakerEstimation)
        #expect(SpeakerEstimationChip.font.pointSize == 10)
        // 実セルの描画を比べる。長い名前でも札が画面から欠けないことを確かめる。
        #expect(try purplePixels(enabled.destination) > purplePixels(disabled.destination) + 20)
    }

    private func purplePixels(_ popup: NSPopUpButton) throws -> Int {
        popup.superview?.layoutSubtreeIfNeeded()
        let bitmap = try #require(popup.bitmapImageRepForCachingDisplay(in: popup.bounds))
        popup.cacheDisplay(in: popup.bounds, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            // 左のアバターを除き、チェブロンの手前へ描かれた札だけを数える。
            for x in (bitmap.pixelsWide / 2)..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent > color.redComponent + 0.05,
                   color.redComponent > color.greenComponent + 0.05 { count += 1 }
            }
        }
        return count
    }

    private func titleHasInkNearAvatar(_ popup: NSPopUpButton) throws -> Bool {
        let bitmap = try #require(popup.bitmapImageRepForCachingDisplay(in: popup.bounds))
        popup.cacheDisplay(in: popup.bounds, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            // アバターより右、ボタンの左3分の1。短い宛先名が中央へ飛ぶ退行を検出する。
            for x in (bitmap.pixelsWide / 10)..<(bitmap.pixelsWide / 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3 { count += 1 }
            }
        }
        return count > 10
    }

    /// 撮影時だけ一覧を開く。AppKitがメニュー窓を公開しない環境では、シート2枚だけを残す。
    private func captureMenu(_ popup: NSPopUpButton, name: String = "destination-menu") throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_START_SHEET_CAPTURE"] else { return }
        let existing = Set(NSApplication.shared.windows.map(\.windowNumber))
        var failure: Error?
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated {
                defer { popup.menu?.cancelTrackingWithoutAnimation() }
                guard let window = NSApplication.shared.windows.first(where: {
                    $0.isVisible && !existing.contains($0.windowNumber)
                }), let content = window.contentView else {
                    print("開始シートの一覧撮影: メニュー窓が公開されないため省略")
                    return
                }
                do {
                    let view = content.superview ?? content
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
                } catch { failure = error }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        popup.performClick(nil)
        timer.invalidate()
        if let failure { throw failure }
    }

    private func capture(_ name: String, _ sheet: StartSheet) async throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_START_SHEET_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        try #require(directory.path.hasPrefix("/tmp/") || directory.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scroll = try #require(sheet.window.contentView as? NSScrollView)
        let view = try #require(scroll.documentView)
        view.wantsLayer = true
        view.layer?.backgroundColor = Washi.paper.cgColor
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: scroll.documentVisibleRect))
        view.cacheDisplay(in: scroll.documentVisibleRect, to: bitmap)
        // 既存ハーネスと同じPNGを中間形式にし、成果画像はWebPへ変換する。
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
}

private final class HighlightableMenuItem: NSMenuItem {
    var highlightedForTesting = false
    override var isHighlighted: Bool { highlightedForTesting }
}
