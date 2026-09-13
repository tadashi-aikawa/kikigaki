import Foundation
import Testing
import KikigakiCore

@Suite struct MinutesHighlightTests {
    @Test func 送信と編集の観測で基準を置き直し同じ依頼では増やさない() {
        var baseline = MinutesHighlightBaseline()
        let first = UUID(), second = UUID()
        #expect(baseline.revision == 0)
        baseline.didSend(first)
        #expect(baseline.revision == 1)
        // 送信だけの繰り返しでは置き直さない
        baseline.didSend(first)
        baseline.observe([:])
        baseline.observe([first: .replying])
        #expect(baseline.revision == 1)
        // 編集の開始で1回だけ置き直す。返答の申告が増えても変わらない
        baseline.observe([first: .editing(total: 3)])
        #expect(baseline.revision == 2)
        baseline.observe([first: AIProgressReport(isEditing: true, editingTotal: 3, isReplying: true)])
        #expect(baseline.revision == 2)
        // 次の依頼は送信と編集でそれぞれ置き直す
        baseline.didSend(second)
        baseline.observe([first: .editing(), second: .editing()])
        #expect(baseline.revision == 4)
    }

    @Test func 自分が送っていない依頼の編集では置き直さない() {
        var baseline = MinutesHighlightBaseline()
        let restored = UUID()
        // 再起動後の回収で読んだ古い申告。基準を置く前の本文は比べる相手がない
        baseline.observe([restored: .editing()])
        #expect(baseline.revision == 0)
        baseline.didSend(restored)
        baseline.observe([restored: .editing()])
        #expect(baseline.revision == 2)
    }

    @Test func 会議を切り替えると基準の回数も初期化される() {
        var baseline = MinutesHighlightBaseline()
        let request = UUID()
        baseline.didSend(request)
        #expect(baseline != MinutesHighlightBaseline())
        baseline = MinutesHighlightBaseline()
        #expect(baseline.revision == 0)
        // 同じ依頼IDでも新しい基準では送信として数える
        baseline.didSend(request)
        #expect(baseline.revision == 1)
    }
}
