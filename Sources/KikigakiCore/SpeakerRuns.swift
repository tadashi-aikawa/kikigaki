import Foundation

/// 話者判別が10msごとに返す話者別の確率を、届いた分から話者区間へ畳む。確率の履歴は持たない。
/// Nemotron 3 の確率は一度返ったら変わらないので、閉じた区間は後から動かない。
/// 判定は FluidAudio の `Nemotron3Diarizer.segments` と同じで、しきい値を超えたフレームを発話とし、
/// 最短長では落とさない(試作の比較と同じ条件)
public struct SpeakerRuns: Sendable {
    public static let frameSeconds = 0.01
    public let speakerCount: Int
    public let threshold: Float
    /// 受け取ったフレーム数。時刻はこの数から出す
    public private(set) var frameCount = 0
    private var closed: [SpeakerSegment] = []
    /// 話者ごとに、閉じていない区間の開始フレーム
    private var openStart: [Int?]

    public init(speakerCount: Int, threshold: Float = 0.5) {
        precondition(speakerCount > 0, "話者数は1以上")
        self.speakerCount = speakerCount
        self.threshold = threshold
        openStart = Array(repeating: nil, count: speakerCount)
    }

    /// 判定済みの末尾(秒)
    public var judgedSeconds: Double { Double(frameCount) * Self.frameSeconds }

    public struct Mismatch: Error, CustomStringConvertible {
        public let description: String
    }

    /// エンジンが1回に返した chunk 群を取り込む。形か、取り込み後の合計フレーム数 `totalFrames` が
    /// 食い違ったら何も取り込まずに投げる。食い違った出力を判定済みの区間へ混ぜないため
    public mutating func append(chunks: [(probabilities: [Float], frames: Int, speakers: Int)], totalFrames: Int) throws {
        let frames = chunks.reduce(0) { $0 + $1.frames }
        guard chunks.allSatisfy({ $0.speakers == speakerCount && $0.probabilities.count == $0.frames * speakerCount }),
              frameCount + frames == totalFrames else {
            throw Mismatch(description: "話者判別の出力が食い違った: 受信済み\(frameCount)+\(frames) エンジン\(totalFrames)")
        }
        for chunk in chunks { append(chunk.probabilities) }
    }

    /// フレーム × 話者の順に並んだ確率を後ろへ足す
    public mutating func append(_ probabilities: [Float]) {
        precondition(probabilities.count % speakerCount == 0, "確率の数が話者数の倍数でない")
        let frames = probabilities.count / speakerCount
        for offset in 0..<frames {
            let frame = frameCount + offset
            for speaker in 0..<speakerCount {
                let active = probabilities[offset * speakerCount + speaker] > threshold
                if active, openStart[speaker] == nil {
                    openStart[speaker] = frame
                } else if !active, let start = openStart[speaker] {
                    closed.append(SpeakerSegment(speaker: speaker, start: Double(start) * Self.frameSeconds,
                                                 end: Double(frame) * Self.frameSeconds))
                    openStart[speaker] = nil
                }
            }
        }
        frameCount += frames
    }

    /// 閉じた区間と、閉じていない区間を判定済みの末尾で切ったもの。`duration` より後は切り落とす。
    /// 末尾のフレームは10ms単位で切り上がるため、実音声の長さを渡して余りを落とす
    public func segments(until duration: Double) -> [SpeakerSegment] {
        let end = min(judgedSeconds, duration)
        var result = judgedSeconds <= duration ? closed : closed.compactMap { segment in
            segment.start < end ? SpeakerSegment(speaker: segment.speaker, start: segment.start, end: min(segment.end, end)) : nil
        }
        for (speaker, start) in openStart.enumerated() {
            guard let start, Double(start) * Self.frameSeconds < end else { continue }
            result.append(SpeakerSegment(speaker: speaker, start: Double(start) * Self.frameSeconds, end: end))
        }
        return result
    }
}
