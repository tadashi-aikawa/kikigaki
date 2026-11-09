import Foundation

/// 記録した観測へ判定を当て直す。フレームの間は0.25秒ごとに時間だけ進める。実画面の監視と同じ刻み。
enum Simulation {
    static let tickInterval = 0.25

    struct Run {
        let saves: [SaveDecision]
        let misses: Int
        let extras: Int
        let detail: [String]
    }

    final class Source {
        let lines: [RecordLine]
        let truth: [TruthWindow]?
        let name: String
        private var cache: [Int: [Thumb?]] = [:]

        init(directory: URL) throws {
            lines = try Recording.load(directory.appendingPathComponent("frames.jsonl"))
            truth = try Recording.loadTruth(directory.appendingPathComponent("truth.json"))
            name = directory.lastPathComponent
        }

        func thumbs(width: Int) -> [Thumb?] {
            if let hit = cache[width] { return hit }
            let made = lines.map { line in line.thumb.map { Thumbnail.resized($0, width: width) } }
            cache[width] = made
            return made
        }
    }

    static func run(_ source: Source, params: DetectorParams) -> Run {
        let detector = ChangeDetector(params: params)
        let thumbs = source.thumbs(width: params.thumbWidth)
        var saves: [SaveDecision] = []
        // 実画面のタイマーと同じく、記録の開始から固定の周期で刻む。フレームの到着で位相を合わせ直さない。
        var nextTick = tickInterval
        func advance(to time: Double) {
            while nextTick < time {
                if let decision = detector.tick(now: nextTick) { saves.append(decision) }
                nextTick += tickInterval
            }
        }
        for (offset, line) in source.lines.enumerated() {
            advance(to: line.t)
            switch line.kind {
            case "frame":
                guard let thumb = thumbs[offset] else { continue }
                if let decision = detector.frame(index: line.i ?? offset, time: line.t, thumb: thumb).1 { saves.append(decision) }
            case "idle":
                if let decision = detector.tick(now: line.t) { saves.append(decision) }
            case "unavailable":
                // 実画面の markUnavailable と同じ。初期化後は次のフレームまで保存しない。
                detector.reset()
            case "end":
                advance(to: line.t)
            default:
                break
            }
        }
        let (misses, extras, detail) = score(saves, truth: source.truth)
        return Run(saves: saves, misses: misses, extras: extras, detail: detail)
    }

    static func score(_ saves: [SaveDecision], truth: [TruthWindow]?) -> (Int, Int, [String]) {
        guard let truth else { return (0, 0, []) }
        var misses = 0, extras = 0, detail: [String] = []
        for window in truth {
            let count = saves.filter { $0.frameTime >= window.from && $0.frameTime < window.to }.count
            let miss = max(0, window.min - count), extra = max(0, count - window.max)
            misses += miss; extras += extra
            detail.append(String(format: "%@ %5.1f-%5.1f 保存%d 期待%d〜%d%@", window.label, window.from, window.to, count, window.min, window.max,
                                 miss > 0 ? " 取りこぼし\(miss)" : extra > 0 ? " 余分\(extra)" : ""))
        }
        let outside = saves.filter { save in !truth.contains { save.frameTime >= $0.from && save.frameTime < $0.to } }.count
        if outside > 0 { extras += outside; detail.append("区間外の保存 \(outside)") }
        return (misses, extras, detail)
    }
}

/// しきい値の組を総当たりし、合成の正解に対する取りこぼしと余分を数える。
enum Sweep {
    struct Grid {
        var widths = [64, 128, 256]
        var cells = [6, 10, 16, 24]
        var motions = [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02]
        var saves = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05]
        var settles = [1.0, 1.5, 2.0]
        var tops = [0.0]
        var volatiles = [0.0]
        var releases = [10.0]
        var counts = [3]
        var frameLimits = [0.05]

        var all: [DetectorParams] {
            var result: [DetectorParams] = []
            for width in widths { for cell in cells { for motion in motions { for save in saves where save >= motion {
                for settle in settles { for top in tops { for volatile in volatiles {
                for release in (volatile > 0 ? releases : [10]) { for count in (volatile > 0 ? counts : [3]) {
                for frameLimit in (volatile > 0 ? frameLimits : [1]) {
                    var params = DetectorParams()
                    params.thumbWidth = width; params.cellDelta = cell; params.motion = motion; params.save = save
                    params.settle = settle; params.excludeTopFraction = top; params.volatileSeconds = volatile
                    params.volatileRelease = release; params.volatileCount = count; params.volatileFrameLimit = frameLimit
                    result.append(params)
                } } } } } }
            } } } }
            return result
        }
    }

    static func main(_ args: inout Arguments) throws {
        var grid = Grid()
        if let list = args.doubles("--motion") { grid.motions = list }
        if let list = args.doubles("--save") { grid.saves = list }
        if let list = args.doubles("--settle") { grid.settles = list }
        if let list = args.doubles("--top") { grid.tops = list }
        if let list = args.doubles("--volatile") { grid.volatiles = list }
        if let list = args.doubles("--release") { grid.releases = list }
        if let list = args.doubles("--vcount") { grid.counts = list.map { Int($0) } }
        if let list = args.doubles("--vlimit") { grid.frameLimits = list }
        if let list = args.doubles("--cell") { grid.cells = list.map { Int($0) } }
        if let list = args.doubles("--width") { grid.widths = list.map { Int($0) } }
        let top = args.int("--show") ?? 15
        let verbose = args.flag("--detail")
        let directories = args.rest.map { URL(fileURLWithPath: $0) }
        guard !directories.isEmpty else { throw ProbeError.message("記録のディレクトリを1つ以上渡す") }
        let sources = try directories.map(Simulation.Source.init(directory:))
        let candidates = grid.all
        var rows: [(DetectorParams, Int, Int, Int, [Simulation.Run])] = []
        for params in candidates {
            let runs = sources.map { Simulation.run($0, params: params) }
            rows.append((params, runs.reduce(0) { $0 + $1.misses }, runs.reduce(0) { $0 + $1.extras }, runs.reduce(0) { $0 + $1.saves.count }, runs))
        }
        // 取りこぼしは取り戻せないので先に少なくし、同じなら余分を少なくする。
        rows.sort { ($0.1, $0.2, $0.0.settle, $0.0.thumbWidth) < ($1.1, $1.2, $1.0.settle, $1.0.thumbWidth) }
        print("組 \(candidates.count) 件、記録 \(sources.map(\.name).joined(separator: ", "))")
        for row in rows.prefix(top) {
            print(String(format: "取りこぼし%3d 余分%3d 保存%4d  ", row.1, row.2, row.3) + row.0.description)
            if verbose {
                for (source, run) in zip(sources, row.4) {
                    print("  [\(source.name)] 保存: " + run.saves.map { String(format: "%.1f", $0.frameTime) }.joined(separator: " "))
                    run.detail.filter { $0.contains("取りこぼし") || $0.contains("余分") || $0.contains("区間外") }.forEach { print("    " + $0) }
                }
            }
        }
        let perfect = rows.filter { $0.1 == 0 && $0.2 == 0 }
        print("取りこぼし0・余分0の組: \(perfect.count) / \(rows.count)")
    }
}
