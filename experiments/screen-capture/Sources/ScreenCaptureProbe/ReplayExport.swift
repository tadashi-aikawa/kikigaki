import Foundation

/// 観測の記録を、本体の判定器のテストに要る最小の形で書き出す。画像そのものは書かない。
/// 本体の `ScreenChangeReplayTests` が読み、試作と本体の決定が一致することを固定する。
///
/// - 縮小画像は `sweep` と同じく幅128へ縮めた輝度だけを持つ。全フレームをつないでlzmaで縮め、base64にする
/// - 行は観測・idle・撮れない期間・終わりの種類と時刻だけ。`sweep` と同じ順に当て直せる
/// - 期待の決定は、推す組の値で試作の判定器に当てた結果。本体の定数と同じ値
///
/// ```bash
/// .build/release/ScreenCaptureProbe export-replay <記録のディレクトリ> --out <JSON> [--top <割合>]
/// ```
/// `--top` を省くと、記録の `events.jsonl` の開始の行の値を使う。
enum ReplayExportCommand {
    struct Fixture: Codable {
        struct Line: Codable {
            /// f: 観測 / i: idle / u: 撮れない期間 / e: 終わり
            var k: String
            var t: Double
            var i: Int?
        }
        struct Expected: Codable {
            var frame: Int
            var reason: String
            var decidedAt: Double
        }
        var source: String
        var top: Double
        var width: Int
        var height: Int
        var lines: [Line]
        /// 観測の縮小画像を行の順につないだ輝度を、lzmaで縮めてbase64にしたもの。
        var luma: String
        var decisions: [Expected]
        /// 決定の `failEvery` 回に1回を保存の失敗として返したときの決定。失敗した決定も含む。
        var failEvery: Int?
        var decisionsWithFailures: [Expected]?
    }

    /// 失敗を混ぜるときの間隔。決定の3回に1回を失敗として返す。続けて失敗する場面も作るため短くする。
    static let failEvery = 3

    /// 本体の判定器の定数と同じ組。値は検証記録の推す組。
    static func recommended(top: Double) -> DetectorParams {
        var params = DetectorParams()
        params.thumbWidth = 128; params.cellDelta = 8; params.motion = 0.0002; params.save = 0.001; params.settle = 1.5
        params.excludeTopFraction = top
        params.recentCount = 0; params.recentSeconds = 12; params.recentExtend = true; params.recentSame = 0.000001; params.recentMaskLimit = 0.5
        params.movingSeconds = 12; params.maskWindow = 10; params.maskCount = 1; params.maskRelease = 3
        params.maskBox = true; params.maskGrow = 1; params.maskRegional = true
        return params
    }

    static func main(_ args: inout Arguments) throws {
        guard let out = args.string("--out") else { throw ProbeError.message("--out <JSON> を渡す") }
        guard let path = args.rest.first else { throw ProbeError.message("記録のディレクトリを渡す") }
        let directory = URL(fileURLWithPath: path)
        let top = try args.doubles("--top")?.first ?? startTop(directory)
        let source = try Simulation.Source(directory: directory)
        let params = recommended(top: top)
        let thumbs = source.thumbs(width: params.thumbWidth)
        var lines: [Fixture.Line] = []
        var luma = Data()
        var size: (Int, Int)?
        for (offset, line) in source.lines.enumerated() {
            switch line.kind {
            case "frame":
                guard let thumb = thumbs[offset] else { continue }
                if let size, size != (thumb.width, thumb.height) { throw ProbeError.message("縮小画像の寸法が途中で変わった") }
                size = (thumb.width, thumb.height)
                lines.append(.init(k: "f", t: line.t, i: line.i ?? offset))
                luma.append(contentsOf: thumb.luma)
            case "idle": lines.append(.init(k: "i", t: line.t))
            case "unavailable": lines.append(.init(k: "u", t: line.t))
            case "end": lines.append(.init(k: "e", t: line.t))
            default: break
            }
        }
        guard let (width, height) = size else { throw ProbeError.message("観測がありません") }
        let run = Simulation.run(source, params: params)
        let failing = Simulation.run(source, params: params, failEvery: failEvery)
        let compressed = try (luma as NSData).compressed(using: .lzma) as Data
        func expected(_ decisions: [SaveDecision]) -> [Fixture.Expected] {
            decisions.map { .init(frame: $0.frameIndex, reason: $0.reason.rawValue, decidedAt: $0.decidedAt) }
        }
        let fixture = Fixture(source: directory.lastPathComponent, top: top, width: width, height: height, lines: lines,
                              luma: compressed.base64EncodedString(), decisions: expected(run.saves),
                              failEvery: failEvery, decisionsWithFailures: expected(failing.attempts))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: out))
        print("観測\(lines.filter { $0.k == "f" }.count)件 行\(lines.count)件 縮小画像\(luma.count)バイト → \(compressed.count)バイト 保存\(run.saves.count)件  \(params)")
    }

    /// 記録の開始の行の、メニューバーを外す割合。
    private static func startTop(_ directory: URL) throws -> Double {
        let events = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        for line in events.split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["kind"] as? String == "start",
                  let text = object["top"] as? String, let value = Double(text) else { continue }
            return value
        }
        throw ProbeError.message("events.jsonl に開始の行の top がありません。--top で渡す")
    }
}
