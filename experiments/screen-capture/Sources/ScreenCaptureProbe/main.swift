import AppKit
import Foundation
import ImageIO

struct Arguments {
    private(set) var rest: [String]

    init(_ items: [String]) { rest = items }

    mutating func string(_ name: String) -> String? {
        guard let index = rest.firstIndex(of: name), index + 1 < rest.count else { return nil }
        let value = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
        return value
    }
    mutating func required(_ name: String) throws -> String {
        guard let value = string(name) else { throw ProbeError.message("\(name) が要る") }
        return value
    }
    mutating func int(_ name: String) -> Int? { string(name).flatMap { Int($0) } }
    mutating func double(_ name: String) -> Double? { string(name).flatMap { Double($0) } }
    mutating func strings(_ name: String) -> [String]? { string(name).map { $0.split(separator: ",").map(String.init) } }
    mutating func doubles(_ name: String) -> [Double]? { strings(name)?.compactMap { Double($0) } }
    mutating func flag(_ name: String) -> Bool {
        guard let index = rest.firstIndex(of: name) else { return false }
        rest.remove(at: index)
        return true
    }
}

/// 画像ファイルを指定の倍率へ縮めてWebPにする。Retinaの2x画面を1xで残したときの文字の読みやすさを見る。
enum EncodeCommand {
    static func main(_ args: inout Arguments) throws {
        let scale = args.double("--scale") ?? 1
        let quality = args.double("--quality") ?? 80
        let out = URL(fileURLWithPath: try args.required("--out"))
        // --crop x,y,w,h: 縮めた後に切り出す。品質80で残した画像の一部を、品質100で目視用に書き出すときに使う。
        let crop = args.doubles("--crop")
        guard let input = args.rest.first, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ProbeError.message("入力の画像を読めない") }
        if let crop, crop.count == 4, let part = image.cropping(to: CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])) { image = part }
        let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ProbeError.message("縮小に失敗") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let started = Date()
        let data = try WebPEncoder.encode(context.makeImage()!, quality: quality)
        try data.write(to: out)
        print(String(format: "%dx%d 品質%.0f %d KB 符号化 %.0fms", width, height, quality, data.count / 1024, Date().timeIntervalSince(started) * 1000))
    }
}

/// 判定の約束を、合成した縮小画像で確かめる。
enum SelfCheck {
    static func main() throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        func thumb(_ fill: UInt8, patch: (Int, UInt8)? = nil) -> Thumb {
            var luma = [UInt8](repeating: fill, count: 100)
            if let (count, value) = patch { for cell in 0..<count { luma[cell * 7 % 100] = value } }
            return Thumb(width: 10, height: 10, luma: luma)
        }
        var params = DetectorParams()
        params.motion = 0.02; params.save = 0.05; params.settle = 1.5; params.cellDelta = 10; params.volatileSeconds = 0

        // 最初のフレームは待たずに保存する。
        var detector = ChangeDetector(params: params)
        check(detector.frame(index: 0, time: 0, thumb: thumb(200)).1?.reason == .first, "最初のフレームを保存しない")

        // ページ送り: 動いた後、1.5秒落ち着いたら観測時刻の画像を1枚保存する。
        detector = ChangeDetector(params: params)
        _ = detector.frame(index: 0, time: 0, thumb: thumb(200))
        check(detector.frame(index: 1, time: 10, thumb: thumb(50)).1 == nil, "動いた直後に保存した")
        check(detector.tick(now: 11.25) == nil, "落ち着く前に保存した")
        let settled = detector.tick(now: 11.5)
        check(settled?.frameTime == 10 && settled?.reason == .settled, "落ち着いた後に観測時刻で保存しない")
        check(detector.tick(now: 20) == nil, "同じ画面を2度保存した")

        // 時計: 直前との差が動きのしきい値以下なら、待ちを崩さず保存もしない。
        detector = ChangeDetector(params: params)
        _ = detector.frame(index: 0, time: 0, thumb: thumb(200))
        for second in 1...10 { check(detector.frame(index: second, time: Double(second), thumb: thumb(200, patch: (1, UInt8(second * 20)))).1 == nil, "時計で保存した") }

        // 小さな変化の積み重ね: 1回ずつは動きでなくても、保存した画像との差が積もれば保存する。
        detector = ChangeDetector(params: params)
        _ = detector.frame(index: 0, time: 0, thumb: thumb(200))
        var saves = 0
        for step in 1...8 { if detector.frame(index: step, time: Double(step) * 2, thumb: thumb(200, patch: (step, 0))).1 != nil { saves += 1 } }
        check(saves == 1, "積み重なった小さな変化の保存が1枚でない: \(saves)")

        // 回り続ける小さな印: 外すマスの指定があれば、直前との差から外れて落ち着き、変化の無い画面として扱う。
        params.volatileSeconds = 5
        detector = ChangeDetector(params: params)
        _ = detector.frame(index: 0, time: 0, thumb: thumb(200))
        saves = 0
        for step in 1...20 { if detector.frame(index: step, time: Double(step), thumb: thumb(200, patch: (3, step % 2 == 0 ? 0 : 255))).1 != nil { saves += 1 } }
        check(saves == 0, "回り続ける印で保存した: \(saves)")

        // 続けてページを送っても画面全体は外さない。送り終えて見ているページを保存する。
        detector = ChangeDetector(params: params)
        _ = detector.frame(index: 0, time: 0, thumb: thumb(200))
        for (step, fill) in [(1, UInt8(20)), (2, 120), (3, 20), (4, 120)] { _ = detector.frame(index: step, time: Double(step), thumb: thumb(fill)) }
        check(detector.tick(now: 5.5)?.frameTime == 4, "続けて送った後のページを保存しない")

        // 撮れない期間の後は、古いフレームを保存せず、次のフレームを待たずに保存する。
        detector = ChangeDetector(params: params)
        _ = detector.frame(index: 0, time: 0, thumb: thumb(200))
        _ = detector.frame(index: 1, time: 1, thumb: thumb(50))
        detector.reset()
        check(detector.tick(now: 10) == nil, "撮れない期間の後に古いフレームを保存した")
        check(detector.frame(index: 2, time: 11, thumb: thumb(50)).1?.reason == .first, "復帰した最初のフレームを保存しない")

        // 案P: 2枚が交互に入れ替わる間は、2枚目より後を保存しない。範囲の秒数より後に戻れば保存する。
        params.volatileSeconds = 0
        var recent = params
        recent.recentCount = 0; recent.recentSeconds = 15
        detector = ChangeDetector(params: recent)
        saves = 0
        var time = 0.0
        for step in 0..<10 {
            if detector.frame(index: step, time: time, thumb: thumb(step % 2 == 0 ? 200 : 50)).1 != nil { saves += 1 }
            for tick in 1...12 { if detector.tick(now: time + Double(tick) * 0.25) != nil { saves += 1 } }
            time += 3
        }
        check(saves == 2, "交互の画面の保存が2枚でない: \(saves)")
        _ = detector.frame(index: 10, time: time, thumb: thumb(120))
        _ = detector.tick(now: time + 2)
        check(detector.frame(index: 11, time: time + 30, thumb: thumb(200)).1 == nil && detector.tick(now: time + 32)?.frameTime == time + 30,
              "範囲の秒数より後に戻った画面を保存しない")

        // 案Q: 動き続けたら N 秒で1枚保存し、動いているマスを外した後は同じ動きで保存しない。
        var moving = params
        moving.movingSeconds = 5; moving.maskWindow = 5; moving.maskCount = 1; moving.maskRelease = 3; moving.maskBox = true
        detector = ChangeDetector(params: moving)
        _ = detector.frame(index: 0, time: 0, thumb: thumb(200))
        var movingSaves: [Double] = []
        for step in 1...30 {
            if let decision = detector.frame(index: step, time: Double(step), thumb: thumb(200, patch: (20, step % 2 == 0 ? 0 : 255))).1 { movingSaves.append(decision.frameTime) }
        }
        check(movingSaves.count == 1 && movingSaves[0] >= 5, "動き続ける画面の保存が N 秒後の1枚でない: \(movingSaves)")

        // 案Q: 外すマスは保存の成功で確定する。失敗したらマスを外さず、再試行の間隔の後にもう一度決める。
        detector = ChangeDetector(params: moving)
        detector.autoConfirm = false
        if let first = detector.frame(index: 0, time: 0, thumb: thumb(200)).1 { detector.saveSucceeded(frameIndex: first.frameIndex, at: 0) }
        var tries: [Double] = []
        for step in 1...20 {
            let time = Double(step)
            let decision = detector.frame(index: step, time: time, thumb: thumb(200, patch: (20, step % 2 == 0 ? 0 : 255))).1
            if let decision {
                tries.append(time)
                if tries.count == 1 { detector.saveFailed(frameIndex: decision.frameIndex, at: time) } else { detector.saveSucceeded(frameIndex: decision.frameIndex, at: time) }
            }
        }
        check(tries.count == 2 && tries[1] - tries[0] >= moving.retryInterval && tries[1] - tries[0] < moving.retryInterval + 1.5,
              "失敗の後に再試行の間隔で決め直さない: \(tries)")

        // 縮小の平均: 4x4の左半分が黒なら、2x2の左列が黒。
        let box = Thumbnail.boxAverage([0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255], width: 4, height: 4, to: 2)
        check(box.luma == [0, 255, 0, 255], "縮小の平均が違う: \(box.luma)")

        if failures.isEmpty { print("self-check: OK") } else { failures.forEach { print("NG: " + $0) }; exit(1) }
    }
}

let usage = """
使い方:
  ScreenCaptureProbe self-check
  ScreenCaptureProbe displays
  ScreenCaptureProbe windows --display <番号|名前> [--seconds 30]
  ScreenCaptureProbe watch --display <番号|名前> --out <新しいディレクトリ> [--seconds 60] [--motion 0.0002] [--save 0.001] [--settle 1.5]
                           [--width 128] [--cell 8] [--volatile 0] [--include-menubar] [--quality 80] [--no-write] [--keep-all] [--exclude-bundle a,b]
  ScreenCaptureProbe permission --out <新しいディレクトリ> [--wait 120] [--display <番号|名前>]
  ScreenCaptureProbe synth --out <ディレクトリ> [--size 1920x1080] [--phases 0,0.37,0.71] [--snapshots 10,45]
  ScreenCaptureProbe sweep <記録のディレクトリ>... [--motion a,b] [--save a,b] [--settle a,b] [--cell a,b] [--width a,b] [--top a,b] [--volatile a,b] [--show 15] [--detail]
  ScreenCaptureProbe encode <画像> --out <x.webp> [--scale 0.5] [--quality 80] [--crop x,y,w,h]
  ScreenCaptureProbe synth ... --scenario meeting|noise|anim|pages|switch|video|alternate|return [--interval min1]
  ScreenCaptureProbe sweep ... [--recent-count a,b] [--recent-seconds a,b] [--recent-extend 0,1] [--recent-same a,b]
                               [--moving a,b] [--mask-window a,b] [--mask-count a,b] [--mask-release a,b] [--mask-grow a,b]
                               [--mask-box 0,1] [--mask-regional 0,1] [--mask-broad a,b] [--mask-novel 0,1] [--fail-every k]
                               [--groups] [--summary] [--label 文字]
  ScreenCaptureProbe import-captures <会議名>.captures --out <ディレクトリ>
  ScreenCaptureProbe pair-diff <会議名>.captures [--width 128] [--cell 8] [--top 0.032]
  ScreenCaptureProbe export-replay <記録のディレクトリ> --out <JSON> [--top <割合>]
"""

var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let command = arguments.rest.first ?? ""
if !arguments.rest.isEmpty { arguments = Arguments(Array(arguments.rest.dropFirst())) }
do {
    switch command {
    case "self-check": try SelfCheck.main()
    case "displays": _ = NSApplication.shared; try await DisplaysCommand.main()
    case "windows": _ = NSApplication.shared; try await WindowsCommand.main(&arguments)
    case "watch": _ = NSApplication.shared; try await WatchCommand.main(&arguments)
    case "permission": _ = NSApplication.shared; try await PermissionCommand.main(&arguments)
    case "synth": try Synth.main(&arguments)
    case "sweep": try Sweep.main(&arguments)
    case "encode": try EncodeCommand.main(&arguments)
    case "import-captures": try ImportCapturesCommand.main(&arguments)
    case "pair-diff": try PairDiffCommand.main(&arguments)
    case "export-replay": try ReplayExportCommand.main(&arguments)
    default: print(usage); exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("エラー: \(error.localizedDescription)\n".utf8))
    exit(1)
}
