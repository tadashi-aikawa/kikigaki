import Foundation
import Testing
@testable import KikigakiCore

@Suite struct TranscriptFilterTests {
    private typealias Subject = TranscriptFilter.Subject

    private func layout(_ subjects: [Subject?], selected: Set<Subject>, expanded: Set<Int> = []) -> [TranscriptFilter.Entry] {
        TranscriptFilter.layout(subjects: subjects, keys: Array(subjects.indices), selected: selected, expanded: expanded)
    }

    @Test func 何も選んでいなければ全行を出す() {
        #expect(layout([.speaker(0), nil, .typed], selected: []) == [.row(0), .row(1), .row(2)])
    }

    @Test func 選んでいない行を連なりごとに件数つきの線へ畳む() {
        let subjects: [Subject?] = [.speaker(1), .speaker(0), .speaker(1), .typed, .speaker(0), .ai("迅雷")]
        #expect(layout(subjects, selected: [.speaker(0)])
                == [.gap(rows: [0], count: 1), .row(1), .gap(rows: [2, 3], count: 2), .row(4), .gap(rows: [5], count: 1)])
    }

    @Test func 複数の相手を選べる() {
        let subjects: [Subject?] = [.speaker(0), .ai("迅雷"), .speaker(1), .ai("迅雷")]
        #expect(layout(subjects, selected: [.speaker(0), .ai("迅雷")]) == [.row(0), .row(1), .gap(rows: [2], count: 1), .row(3)])
    }

    @Test func 相手のいない行は数えず_それだけの区間は線を出さずに畳む() {
        let subjects: [Subject?] = [.speaker(0), nil, .speaker(0), nil, .speaker(1), .speaker(0)]
        #expect(layout(subjects, selected: [.speaker(0)])
                == [.row(0), .row(2), .gap(rows: [3, 4], count: 1), .row(5)])
    }

    @Test func 開いた行は選んでいなくても出し_開いた後に増えた行は別の線にする() {
        let subjects: [Subject?] = [.speaker(0), .speaker(1), .speaker(1), .speaker(1)]
        #expect(layout(subjects, selected: [.speaker(0)], expanded: [1, 2]) == [.row(0), .row(1), .row(2), .gap(rows: [3], count: 1)])
    }

    @Test func 誰も当たらなければ全体を1本の線にする() {
        #expect(layout([.speaker(1), .typed], selected: [.ai("迅雷")]) == [.gap(rows: [0, 1], count: 2)])
    }

    @Test func 選べる相手は枡の順_話者なし_手入力_AIの初出順に並ぶ() throws {
        let utterances = [Utterance(speaker: 2, start: 0, end: 1, text: "a"),
                          Utterance(speaker: nil, start: 1, end: 2, text: "b"),
                          try Utterance(typedText: "c", at: 2, postedAt: Date()),
                          Utterance(speaker: 0, start: 3, end: 4, text: "d")]
        #expect(TranscriptFilter.subjects(utterances: utterances, aiNames: ["迅雷", "ネオ", "迅雷"])
                == [.speaker(0), .speaker(2), .speaker(nil), .typed, .ai("迅雷"), .ai("ネオ")])
    }

    @Test func 会話から消えた選択中の相手も外せるよう末尾に残す() {
        let utterances = [Utterance(speaker: 0, start: 0, end: 1, text: "a")]
        #expect(TranscriptFilter.subjects(utterances: utterances, aiNames: [], selected: [.ai("ネオ"), .speaker(3), .speaker(0)])
                == [.speaker(0), .speaker(3), .ai("ネオ")])
    }

    @Test func 相手の名前は話者名_手入力_宛先名() {
        let names = SpeakerNames([0: "田中"])
        #expect(TranscriptFilter.name(for: .speaker(0), names: names) == "田中")
        #expect(TranscriptFilter.name(for: .speaker(1), names: names) == "話者B")
        #expect(TranscriptFilter.name(for: .speaker(nil), names: names) == "?")
        #expect(TranscriptFilter.name(for: .typed, names: names) == "手入力")
        #expect(TranscriptFilter.name(for: .ai("迅雷"), names: names) == "迅雷")
    }
}
