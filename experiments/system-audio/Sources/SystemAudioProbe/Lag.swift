import Accelerate
import Foundation

struct LagPeak {
    let milliseconds: Int?
    let correlation: Double
    let margin: Double
    let reason: String
}

struct LagResult {
    let head: LagPeak
    let tail: LagPeak
    let commonSeconds: Double
    var independentWindows: Bool { commonSeconds >= 60 }
    var driftMilliseconds: Int? {
        guard let head = head.milliseconds, let tail = tail.milliseconds else { return nil }
        return tail - head
    }
}

enum Lag {
    // 1 ms RMS envelope correlates amplitude changes despite room coloration/polarity.
    // This measures an acoustic delay, not clock offset alone. Resolution is 1 ms.
    static func envelope(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - samples.count % 16, by: 16).map { start in
            var energy = 0.0
            for i in start..<(start + 16) { energy += Double(samples[i]) * Double(samples[i]) }
            return Float(sqrt(energy / 16))
        }
    }

    static func measure(system: [Float], mic: [Float]) -> LagResult {
        let a = envelope(system)
        let b = envelope(mic)
        let common = min(a.count, b.count)
        let size = min(30000, common)
        let head = peak(Array(a.prefix(size)), Array(b.prefix(size)))
        let tailStart = common - size
        let tail = peak(Array(a[tailStart..<common]), Array(b[tailStart..<common]))
        return LagResult(head: head, tail: tail, commonSeconds: Double(common) / 1000)
    }

    static func peak(_ a: [Float], _ b: [Float]) -> LagPeak {
        let count = min(a.count, b.count)
        guard count >= 3000 else { return LagPeak(milliseconds: nil, correlation: 0, margin: 0, reason: "共通の音声が3秒未満") }
        func prefixes(_ values: [Float]) -> (sum: [Double], square: [Double]) {
            var sum = [Double](repeating: 0, count: count + 1)
            var square = sum
            for i in 0..<count {
                sum[i + 1] = sum[i] + Double(values[i])
                square[i + 1] = square[i] + Double(values[i]) * Double(values[i])
            }
            return (sum, square)
        }
        let pa = prefixes(a), pb = prefixes(b)
        let limit = min(2000, count / 4)
        var scores: [(delay: Int, score: Double)] = []
        a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { y in
                for delay in -limit...limit {
                    // Positive delay means the microphone is later than system audio.
                    let startA = max(0, -delay), startB = max(0, delay)
                    let n = count - abs(delay)
                    let sumA = pa.sum[startA + n] - pa.sum[startA]
                    let sumB = pb.sum[startB + n] - pb.sum[startB]
                    let varianceA = pa.square[startA + n] - pa.square[startA] - sumA * sumA / Double(n)
                    let varianceB = pb.square[startB + n] - pb.square[startB] - sumB * sumB / Double(n)
                    guard varianceA / Double(n) > 1e-12, varianceB / Double(n) > 1e-12 else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(x.baseAddress! + startA, 1, y.baseAddress! + startB, 1, &dot, vDSP_Length(n))
                    let centered = Double(dot) - sumA * sumB / Double(n)
                    let score = max(-1, min(1, centered / sqrt(varianceA * varianceB)))
                    scores.append((delay, score))
                }
            }
        }
        guard let best = scores.max(by: { $0.score < $1.score }) else {
            return LagPeak(milliseconds: nil, correlation: 0, margin: 0, reason: "無音または音量変化が不足")
        }
        let other = scores.filter { abs($0.delay - best.delay) > 100 }.map(\.score).max() ?? -1
        let margin = best.score - other
        let reason: String
        if abs(best.delay) == limit { reason = "探索範囲の端に山がある" }
        else if best.score < 0.35 { reason = "相関の山が弱い" }
        else if margin < 0.05 { reason = "離れた位置にも同程度の山がある" }
        else { reason = "" }
        return LagPeak(milliseconds: reason.isEmpty ? best.delay : nil, correlation: best.score, margin: margin, reason: reason)
    }

    static func run(system: URL, mic: URL) throws {
        let result = measure(system: try Wave.readMono16k(system), mic: try Wave.readMono16k(mic))
        func display(_ title: String, _ peak: LagPeak) {
            if let delay = peak.milliseconds {
                print("\(title): \(delay) ms 相関=\(peak.correlation) 山の差=\(peak.margin)")
            } else { print("\(title): 測れない。\(peak.reason)。相関=\(peak.correlation) 山の差=\(peak.margin)") }
        }
        print("正の値はマイクが遅れる向き。探索範囲は最大±2000 ms、1 ms単位のRMS包絡の正規化相互相関。")
        display("先頭30秒", result.head)
        display("末尾30秒", result.tail)
        if let drift = result.driftMilliseconds {
            print("末尾−先頭: \(drift) ms 共通音声長=\(result.commonSeconds)秒")
        } else { print("時計のずれ: 測れない。先頭または末尾の相関が不足。") }
        if !result.independentWindows { print("注意: 音声が60秒未満で窓が重なります。長時間ドリフトの判断には使えません。") }
    }
}
