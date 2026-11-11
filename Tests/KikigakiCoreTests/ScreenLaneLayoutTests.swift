import Foundation
import Testing
@testable import KikigakiCore

/// 画像レーンの幅とサムネイルの寸法。仕様は docs/screen-capture.md の「表示」
@Suite struct ScreenLaneLayoutTests {
    @Test func 保存した幅は180から480に収め_読めない値は既定の幅() {
        #expect(ScreenLaneLayout.clamp(100) == 180)
        #expect(ScreenLaneLayout.clamp(300.4) == 300)
        #expect(ScreenLaneLayout.clamp(900) == 480)
        #expect(ScreenLaneLayout.clamp(.nan) == 180)
        #expect(ScreenLaneLayout.clamp(.infinity) == 180)
    }

    @Test func 会話側が狭いと発言の列に420ptを残せる分までレーンが譲る() {
        // 会話側1000pt: 希望の480ptをそのまま出せる。
        #expect(ScreenLaneLayout.width(preferred: 480, pane: 1000) == 480)
        // 会話側820pt: 発言の列に420ptを残すと400ptまで。
        #expect(ScreenLaneLayout.width(preferred: 480, pane: 820) == 400)
        // 残せないほど狭ければ最小幅。発言の列が譲る。
        #expect(ScreenLaneLayout.width(preferred: 480, pane: 500) == 180)
        // 希望が狭ければ広げない。
        #expect(ScreenLaneLayout.width(preferred: 200, pane: 1400) == 200)
    }

    @Test func 境目を左へ動かすとレーンが広がり_範囲と発言の列の最小幅で止まる() {
        #expect(ScreenLaneLayout.dragged(from: 180, by: -120, pane: 1200) == 300)
        #expect(ScreenLaneLayout.dragged(from: 300, by: 50, pane: 1200) == 250)
        #expect(ScreenLaneLayout.dragged(from: 180, by: -1000, pane: 1200) == 480)
        #expect(ScreenLaneLayout.dragged(from: 180, by: -1000, pane: 820) == 400)
        #expect(ScreenLaneLayout.dragged(from: 300, by: 1000, pane: 1200) == 180)
    }

    @Test func 境目は画像のあるレーンを出しているときだけつかめ_サムネイルには掛からない() {
        let grip = ScreenLaneLayout.grip(documentWidth: 800, laneWidth: 300, hasImages: true)
        #expect(grip == 496...506)
        // サムネイルはレーンの左端から8pt。つかめる範囲はその手前で終わる。
        #expect(grip!.upperBound < 500 + ScreenLaneLayout.leadingInset)
        #expect(ScreenLaneLayout.grip(documentWidth: 800, laneWidth: 0, hasImages: true) == nil)
        #expect(ScreenLaneLayout.grip(documentWidth: 800, laneWidth: 180, hasImages: false) == nil)
    }

    @Test func サムネイルの枠は画像の縦横比に合わせ_縦長は幅までの高さに抑える() {
        // 既定の幅180ptのサムネイルは152pt幅。
        let wide = ScreenLaneLayout.thumbnailSize(laneWidth: 180, pixelWidth: 3840, pixelHeight: 1600)
        #expect(wide.width == 152 && wide.height == 63)
        let mac = ScreenLaneLayout.thumbnailSize(laneWidth: 180, pixelWidth: 1800, pixelHeight: 1169)
        #expect(mac.height == 99)
        let hd = ScreenLaneLayout.thumbnailSize(laneWidth: 480, pixelWidth: 1920, pixelHeight: 1080)
        #expect(hd.width == 452 && hd.height == 254)
        let portrait = ScreenLaneLayout.thumbnailSize(laneWidth: 300, pixelWidth: 1080, pixelHeight: 1920)
        #expect(portrait.width == 272 && portrait.height == 272)
        // 寸法が読めなければ16:9。
        let unknown = ScreenLaneLayout.thumbnailSize(laneWidth: 180, pixelWidth: nil, pixelHeight: nil)
        #expect(unknown.height == 86)
        #expect(ScreenLaneLayout.thumbnailSize(laneWidth: 180, pixelWidth: 0, pixelHeight: 100).height == 86)
    }

    @Test func 題と次の画像の間は画像と題の間より広い() {
        #expect(ScreenLaneLayout.blockSpacing > ScreenLaneLayout.captionGap * 2)
    }

    @Test func 縮小画像は幅を刻みで切り上げて読み_範囲の全体で3段に収まる() {
        #expect(ScreenLaneLayout.decodePixels(thumbnailWidth: 152) == 304)
        #expect(ScreenLaneLayout.decodePixels(thumbnailWidth: 153) == 608)
        #expect(ScreenLaneLayout.decodePixels(thumbnailWidth: 272) == 608)
        #expect(ScreenLaneLayout.decodePixels(thumbnailWidth: 452) == 912)
        let widths = stride(from: ScreenLaneLayout.minimumWidth, through: ScreenLaneLayout.maximumWidth, by: 1)
        let sizes = Set(widths.map { ScreenLaneLayout.decodePixels(thumbnailWidth: ScreenLaneLayout.thumbnailWidth(laneWidth: $0)) })
        #expect(sizes == [304, 608, 912])
        // 読む大きさは枠の2倍以上。広げてもぼやけない。
        for width in widths {
            let thumbnail = ScreenLaneLayout.thumbnailWidth(laneWidth: width)
            #expect(Double(ScreenLaneLayout.decodePixels(thumbnailWidth: thumbnail)) >= thumbnail * 2)
        }
    }
}
