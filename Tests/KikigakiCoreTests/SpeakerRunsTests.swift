import Testing

@testable import KikigakiCore

@Suite struct SpeakerRunsTests {
    /// 2話者×6フレーム。話者0は0〜3、話者1は2〜5で重なる。0.5ちょうどは発話にしない
    let probabilities: [Float] = [
        0.9, 0.1,
        0.8, 0.5,
        0.7, 0.6,
        0.2, 0.9,
        0.1, 0.9,
        0.1, 0.8,
    ]

    func sorted(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        segments.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    /// フレーム番号の時刻。実装と同じ計算にして浮動小数の丸めを期待値へ持ち込まない
    func t(_ frame: Int) -> Double { Double(frame) * SpeakerRuns.frameSeconds }

    @Test func 重なりを話者ごとに区間化し発話中の区間は判定済みの末尾で切る() {
        var runs = SpeakerRuns(speakerCount: 2)
        runs.append(probabilities)
        #expect(runs.judgedSeconds == t(6))
        #expect(sorted(runs.segments(until: 10)) == [
            SpeakerSegment(speaker: 0, start: 0, end: t(3)),
            SpeakerSegment(speaker: 1, start: t(2), end: t(6)),
        ])
    }

    @Test(arguments: [1, 2, 4, 5])
    func 分けて届いても一括と同じ区間になる(step: Int) {
        var whole = SpeakerRuns(speakerCount: 2)
        whole.append(probabilities)
        var split = SpeakerRuns(speakerCount: 2)
        var frame = 0
        while frame < 6 {
            let end = min(frame + step, 6)
            split.append(Array(probabilities[(frame * 2)..<(end * 2)]))
            frame = end
        }
        #expect(sorted(split.segments(until: 10)) == sorted(whole.segments(until: 10)))
    }

    @Test func 末尾の切り上げは実音声の長さで落とし空の区間を返さない() {
        var runs = SpeakerRuns(speakerCount: 2)
        runs.append(probabilities)
        // 0.055秒の音声。末尾フレームは切り上げで0.06秒まで届く
        #expect(sorted(runs.segments(until: 0.055)) == [
            SpeakerSegment(speaker: 0, start: 0, end: t(3)),
            SpeakerSegment(speaker: 1, start: t(2), end: 0.055),
        ])
        // 話者1の開始ちょうどで切ると長さ0になるので返さない
        #expect(runs.segments(until: t(2)) == [SpeakerSegment(speaker: 0, start: 0, end: t(2))])
        #expect(SpeakerRuns(speakerCount: 2).segments(until: 0).isEmpty)
    }

    @Test func 食い違った出力は何も取り込まずに投げる() throws {
        var runs = SpeakerRuns(speakerCount: 2)
        try runs.append(chunks: [(Array(probabilities.prefix(4)), 2, 2)], totalFrames: 2)
        let before = runs.segments(until: 10)
        // 話者数・配列長・エンジン側の合計フレーム数のどれが違っても、判定済みの区間は変えない
        let broken: [([(probabilities: [Float], frames: Int, speakers: Int)], Int)] = [
            ([(Array(probabilities.dropFirst(4)), 4, 4)], 6),
            ([(Array(probabilities.dropFirst(4)), 3, 2)], 5),
            ([(Array(probabilities.dropFirst(4)), 4, 2)], 7),
            ([(Array(probabilities[4..<8]), 2, 2), (Array(probabilities.dropFirst(8)), 2, 2)], 5),
        ]
        for (chunks, total) in broken {
            #expect(throws: SpeakerRuns.Mismatch.self) { try runs.append(chunks: chunks, totalFrames: total) }
            #expect(runs.frameCount == 2)
            #expect(runs.segments(until: 10) == before)
        }
        try runs.append(chunks: [(Array(probabilities[4..<8]), 2, 2), (Array(probabilities.dropFirst(8)), 2, 2)], totalFrames: 6)
        #expect(runs.frameCount == 6)
    }
}
