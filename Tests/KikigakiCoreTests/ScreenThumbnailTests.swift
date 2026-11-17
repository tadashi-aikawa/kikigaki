import Testing
@testable import KikigakiCore

/// 画面のスリープから戻る途中の真っ黒の見分け。仕様は docs/screen-capture.md の「画面のスリープ」
@Suite struct ScreenThumbnailTests {
    @Test func 全てのマスが輝度8以下なら真っ黒() {
        #expect(ScreenThumbnail(width: 2, height: 2, luma: [0, 0, 0, 0]).isBlack)
        #expect(ScreenThumbnail(width: 2, height: 2, luma: [8, 3, 0, 8]).isBlack)
    }

    @Test func 暗い文字が1マスでもあれば真っ黒ではない() {
        #expect(!ScreenThumbnail(width: 2, height: 2, luma: [0, 0, 0, 9]).isBlack)
    }
}
