import Foundation

/// 記録した観測へ判定を当て直す。フレームの間は0.25秒ごとに時間だけ進める。実画面の監視と同じ刻み。
enum Simulation {
    static let tickInterval = 0.25

    struct Run {
        let saves: [SaveDecision]
        var misses = 0
        /// 余分。交互・巡回の再保存を含む。
        var extras = 0
        var detail: [String] = []
        /// 送り・切替・スクロールの途中の保存。
        var transit = 0
        /// 交互・巡回で、一度保存したページをもう一度保存した数。
        var resaves = 0
        var returned = 0
        var returnable = 0
        /// 遅れを数える区間ごとの、最初の保存を決めるまでの秒数。保存が無い区間は含めない。
        var latencies: [Double] = []
        /// 遅れを数える区間の数。保存が無かった区間も含む。
        var latencyWindows = 0
        var failures = 0
        /// 失敗として返した決定も含む、全部の決定。決めた順。
        var attempts: [SaveDecision] = []
    }

    final class Source {
        let lines: [RecordLine]
        let truth: [TruthWindow]?
        let name: String
        /// 親のディレクトリ名を付けた名前。phase0 のような名前が筋書きをまたいで重なるため。
        let label: String
        /// 筋書きの名前。親のディレクトリ名の最初の `-` より前。集計の単位にする。
        let group: String
        private var cache: [Int: [Thumb?]] = [:]

        init(directory: URL) throws {
            lines = try Recording.load(directory.appendingPathComponent("frames.jsonl"))
            truth = try Recording.loadTruth(directory.appendingPathComponent("truth.json"))
            name = directory.lastPathComponent
            let parent = directory.deletingLastPathComponent().lastPathComponent
            label = parent + "/" + directory.lastPathComponent
            group = String(parent.split(separator: "-").first ?? Substring(parent))
        }

        func thumbs(width: Int) -> [Thumb?] {
            if let hit = cache[width] { return hit }
            let made = lines.map { line in line.thumb.map { Thumbnail.resized($0, width: width) } }
            cache[width] = made
            return made
        }
    }

    /// - failEvery: 0より大きければ、決定のこの数ごとに1回、保存に失敗したとして返す。成功で確定する約束を確かめる。
    static func run(_ source: Source, params: DetectorParams, failEvery: Int = 0) -> Run {
        let detector = ChangeDetector(params: params)
        detector.autoConfirm = false
        let thumbs = source.thumbs(width: params.thumbWidth)
        var saves: [SaveDecision] = []
        var attempts: [SaveDecision] = []
        var decisions = 0, failures = 0
        // 保存の結果は決めた直後に返す。本体は符号化と書き込みの分だけ遅れて返す。
        func settle(_ decision: SaveDecision?) {
            guard let decision else { return }
            decisions += 1
            attempts.append(decision)
            if failEvery > 0, decisions % failEvery == 0 {
                failures += 1
                detector.saveFailed(frameIndex: decision.frameIndex, at: decision.decidedAt)
            } else {
                saves.append(decision)
                detector.saveSucceeded(frameIndex: decision.frameIndex, at: decision.decidedAt)
            }
        }
        // 実画面のタイマーと同じく、記録の開始から固定の周期で刻む。フレームの到着で位相を合わせ直さない。
        var nextTick = tickInterval
        func advance(to time: Double) {
            while nextTick < time {
                settle(detector.tick(now: nextTick))
                nextTick += tickInterval
            }
        }
        for (offset, line) in source.lines.enumerated() {
            advance(to: line.t)
            switch line.kind {
            case "frame":
                guard let thumb = thumbs[offset] else { continue }
                settle(detector.frame(index: line.i ?? offset, time: line.t, thumb: thumb).1)
            case "idle":
                settle(detector.tick(now: line.t))
            case "unavailable":
                // 実画面の markUnavailable と同じ。初期化後は次のフレームまで保存しない。
                detector.reset()
            case "end":
                advance(to: line.t)
            default:
                break
            }
        }
        var run = score(saves, truth: source.truth)
        run.failures = failures
        run.attempts = attempts
        return run
    }

    static func score(_ saves: [SaveDecision], truth: [TruthWindow]?) -> Run {
        var run = Run(saves: saves)
        guard let truth else { return run }
        func count(_ window: TruthWindow) -> Int { saves.filter { $0.frameTime >= window.from && $0.frameTime < window.to }.count }
        for window in truth {
            let saved = count(window)
            if window.latency == true { run.latencyWindows += 1 }
            if window.latency == true, let first = saves.filter({ $0.frameTime >= window.from && $0.frameTime < window.to }).map(\.decidedAt).min() {
                run.latencies.append(first - window.from)
            }
            switch window.kind {
            case "transit":
                run.transit += saved
                run.detail.append(String(format: "%@ %5.1f-%5.1f 途中の保存%d", window.label, window.from, window.to, saved))
            case "return":
                run.returnable += 1
                if saved > 0 { run.returned += 1 }
                run.detail.append(String(format: "%@ %5.1f-%5.1f 保存%d 戻り%@", window.label, window.from, window.to, saved, saved > 0 ? "拾った" : "拾わない"))
            case "page":
                break
            default:
                let miss = max(0, window.min - saved), extra = max(0, saved - window.max)
                run.misses += miss; run.extras += extra
                run.detail.append(String(format: "%@ %5.1f-%5.1f 保存%d 期待%d〜%d%@", window.label, window.from, window.to, saved, window.min, window.max,
                                         miss > 0 ? " 取りこぼし\(miss)" : extra > 0 ? " 余分\(extra)" : ""))
            }
        }
        // 交互・巡回: ページごとに、初めて映した回に保存が無ければ取りこぼし、2回目以降の保存は再保存。
        let pages = truth.filter { $0.kind == "page" }
        var keys: [String] = []
        for window in pages where !keys.contains("\(window.group ?? "")#\(window.page ?? 0)") { keys.append("\(window.group ?? "")#\(window.page ?? 0)") }
        for key in keys {
            let shown = pages.filter { "\($0.group ?? "")#\($0.page ?? 0)" == key }.sorted { $0.from < $1.from }
            let counts = shown.map(count)
            let firstMiss = counts.first == 0 ? 1 : 0
            // 初回に撮れずに後で撮った1枚は、遅れた保存として再保存に数えない。
            let resave = max(0, counts.reduce(0, +) - 1)
            run.misses += firstMiss; run.resaves += resave; run.extras += resave
            if firstMiss > 0 || resave > 0 {
                run.detail.append("\(shown[0].label) ページ\(shown[0].page ?? 0): 表示\(shown.count)回 保存\(counts.reduce(0, +))"
                                  + (firstMiss > 0 ? " 初回の取りこぼし" : "") + (resave > 0 ? " 再保存\(resave)" : ""))
            }
        }
        let outside = saves.filter { save in !truth.contains { save.frameTime >= $0.from && save.frameTime < $0.to } }.count
        if outside > 0 { run.extras += outside; run.detail.append("区間外の保存 \(outside)") }
        return run
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
        // 案P・案Q・案R。既定は使わない。
        var recentCounts = [1]
        var recentSeconds = [0.0]
        var recentExtends = [true]
        var recentSames = [0.0]
        var recentExacts = [false]
        var recentMaskLimits = [0.0]
        var movings = [0.0]
        var maskWindows = [0.0]
        var maskCounts = [2]
        var maskReleases = [4.0]
        var maskGrows = [0]
        var maskBoxes = [false]
        var maskBroads = [0.0]
        var maskAfterBroads = [0.0]
        var movingSames = [0]
        var movingSameRepeats = [0]
        var movingSameGrows = [0]
        var movingSameBoxes = [false]
        var maskRegionals = [false]
        var maskNovels = [false]

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
                    result.append(contentsOf: withRules(params))
                } } } } } }
            } } } }
            return result
        }

        /// 案P・案Q・案Rの組を足す。使わない値の組は重ねない。
        private func withRules(_ base: DetectorParams) -> [DetectorParams] {
            var result: [DetectorParams] = []
            for recentCount in recentCounts { for recentSecond in recentSeconds {
            let recentOn = recentCount != 1 || recentSecond > 0
            for extend in (recentOn ? recentExtends : [true]) { for same in (recentOn ? recentSames : [0]) { for exact in (recentOn ? recentExacts : [false]) { for maskLimit in (recentOn ? recentMaskLimits : [0]) {
            for moving in movings { for window in (moving > 0 ? maskWindows : [0]) {
            let masked = moving > 0 && window != 0
            for maskCount in (masked ? maskCounts : [2]) { for maskRelease in (masked ? maskReleases : [4]) {
            for grow in (masked ? maskGrows : [0]) { for box in (masked ? maskBoxes : [false]) {
            for broad in (masked ? maskBroads : [0]) { for afterBroad in (masked ? maskAfterBroads : [0]) { for movingSame in (masked ? movingSames : [0]) { for sameRepeat in (masked && movingSame > 0 ? movingSameRepeats : [0]) { for sameGrow in (masked && movingSame > 0 ? movingSameGrows : [0]) { for sameBox in (masked && movingSame > 0 ? movingSameBoxes : [false]) { for regional in (masked ? maskRegionals : [false]) {
            for novel in (masked ? maskNovels : [false]) {
                var params = base
                params.maskNovel = novel
                params.recentExact = exact
                params.recentMaskLimit = maskLimit
                params.recentCount = recentCount; params.recentSeconds = recentSecond; params.recentExtend = extend; params.recentSame = same
                params.movingSeconds = moving; params.maskCount = maskCount; params.maskRelease = maskRelease; params.maskGrow = grow
                params.maskBox = box; params.maskBroad = broad; params.maskAfterBroad = afterBroad; params.maskRegional = regional
                params.movingSame = movingSame > 0; params.movingSameFirstOnly = movingSame == 2
                params.movingSameRepeat = sameRepeat; params.movingSameGrow = sameGrow; params.movingSameBox = sameBox
                // 外すマスを数える秒数を負にすると、動き続けて撮るまでの秒数と同じにする。
                params.maskWindow = window < 0 ? moving : window
                if !result.contains(params) { result.append(params) }
            } } } } } } } } } } } } } } } } } } } }
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
        if let list = args.doubles("--recent-count") { grid.recentCounts = list.map { Int($0) } }
        if let list = args.doubles("--recent-seconds") { grid.recentSeconds = list }
        if let list = args.doubles("--recent-extend") { grid.recentExtends = list.map { $0 != 0 } }
        if let list = args.doubles("--recent-same") { grid.recentSames = list }
        if let list = args.doubles("--recent-exact") { grid.recentExacts = list.map { $0 != 0 } }
        if let list = args.doubles("--recent-mask") { grid.recentMaskLimits = list }
        if let list = args.doubles("--moving") { grid.movings = list }
        if let list = args.doubles("--mask-window") { grid.maskWindows = list }
        if let list = args.doubles("--mask-count") { grid.maskCounts = list.map { Int($0) } }
        if let list = args.doubles("--mask-release") { grid.maskReleases = list }
        if let list = args.doubles("--mask-grow") { grid.maskGrows = list.map { Int($0) } }
        if let list = args.doubles("--mask-box") { grid.maskBoxes = list.map { $0 != 0 } }
        if let list = args.doubles("--mask-broad") { grid.maskBroads = list }
        if let list = args.doubles("--mask-after-broad") { grid.maskAfterBroads = list }
        // 0: 撮る、1: 同じなら撮らない、2: 外していなければ同じなら撮らない
        if let list = args.doubles("--moving-same") { grid.movingSames = list.map { Int($0) } }
        if let list = args.doubles("--moving-same-repeat") { grid.movingSameRepeats = list.map { Int($0) } }
        if let list = args.doubles("--moving-same-grow") { grid.movingSameGrows = list.map { Int($0) } }
        if let list = args.doubles("--moving-same-box") { grid.movingSameBoxes = list.map { $0 != 0 } }
        if let list = args.doubles("--mask-regional") { grid.maskRegionals = list.map { $0 != 0 } }
        if let list = args.doubles("--mask-novel") { grid.maskNovels = list.map { $0 != 0 } }
        let failEvery = args.int("--fail-every") ?? 0
        let top = args.int("--show") ?? 15
        let verbose = args.flag("--detail")
        // --label 動画: その文字を含む区間の結果を、合否によらず出す
        let labels = args.strings("--label") ?? []
        // --summary: 記録ごとの結果を1行ずつ出す
        let summary = args.flag("--summary")
        // --groups: 筋書きごとに集計して1行に並べる
        let groups = args.flag("--groups")
        let directories = args.rest.map { URL(fileURLWithPath: $0) }
        guard !directories.isEmpty else { throw ProbeError.message("記録のディレクトリを1つ以上渡す") }
        let sources = try directories.map(Simulation.Source.init(directory:))
        let candidates = grid.all
        var rows: [(params: DetectorParams, runs: [Simulation.Run])] = []
        for params in candidates { rows.append((params, sources.map { Simulation.run($0, params: params, failEvery: failEvery) })) }
        func total(_ runs: [Simulation.Run], _ key: KeyPath<Simulation.Run, Int>) -> Int { runs.reduce(0) { $0 + $1[keyPath: key] } }
        // 取りこぼしは取り戻せないので先に少なくし、同じなら余分を少なくする。
        rows.sort { (total($0.runs, \.misses), total($0.runs, \.extras)) < (total($1.runs, \.misses), total($1.runs, \.extras)) }
        print("組 \(candidates.count) 件、記録 \(sources.count) 本")
        for row in rows.prefix(top) {
            print(line(row.runs) + "  " + row.params.description)
            if groups {
                var order: [String] = []
                for source in sources where !order.contains(source.group) { order.append(source.group) }
                for group in order {
                    let runs = zip(sources, row.runs).filter { $0.0.group == group }.map(\.1)
                    print("    " + group.padding(toLength: 7, withPad: " ", startingAt: 0) + "\(runs.count)本 " + line(runs))
                }
            }
            if summary {
                for (source, run) in zip(sources, row.runs) { print("  " + source.label + " " + line([run])) }
            }
            if !labels.isEmpty {
                for (source, run) in zip(sources, row.runs) {
                    let hits = run.detail.filter { line in labels.contains { line.contains($0) } }
                    if !hits.isEmpty { print("  [\(source.label)] " + hits.joined(separator: " / ")) }
                }
            }
            if verbose {
                for (source, run) in zip(sources, row.runs) {
                    // 観測の時刻、理由の印、#フレームの番号、@保存を決めた時刻。
                    // 理由の印: 無印は落ち着いて撮った1枚、m は動き続けて撮った1枚、f は最初の1枚
                    // フレームの番号は watch --keep-all の all/ の画像名の先頭の番号と同じ
                    print("  [\(source.label)] 保存: " + run.saves.map {
                        String(format: "%.1f", $0.frameTime) + ($0.reason == .moving ? "m" : $0.reason == .first ? "f" : "")
                            + String(format: "#%d@%.1f", $0.frameIndex, $0.decidedAt)
                    }.joined(separator: " "))
                    run.detail.filter { $0.contains("取りこぼし") || $0.contains("余分") || $0.contains("区間外") || $0.contains("再保存") }.forEach { print("    " + $0) }
                }
            }
        }
    }

    /// 取りこぼし・余分(うち再保存)・途中・戻り・遅れ・保存を1行にする。
    static func line(_ runs: [Simulation.Run]) -> String {
        func sum(_ key: KeyPath<Simulation.Run, Int>) -> Int { runs.reduce(0) { $0 + $1[keyPath: key] } }
        let latencies = runs.flatMap(\.latencies)
        var text = String(format: "取りこぼし%3d 余分%3d", sum(\.misses), sum(\.extras))
        if sum(\.resaves) > 0 { text += "(再保存\(sum(\.resaves)))" }
        text += String(format: " 途中%3d", sum(\.transit))
        if sum(\.returnable) > 0 { text += " 戻り\(sum(\.returned))/\(sum(\.returnable))" }
        if !latencies.isEmpty {
            // 平均と最大は保存できた区間だけで数える。測れた区間の数を添える。
            text += String(format: " 遅れ平均%.1f秒 最大%.1f秒(測れた区間%d/%d)", latencies.reduce(0, +) / Double(latencies.count), latencies.max() ?? 0,
                           latencies.count, sum(\.latencyWindows))
        }
        if sum(\.failures) > 0 { text += " 失敗\(sum(\.failures))" }
        return text + " 保存\(runs.reduce(0) { $0 + $1.saves.count })"
    }
}
