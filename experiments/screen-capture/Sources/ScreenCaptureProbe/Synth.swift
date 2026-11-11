import CoreGraphics
import CoreText
import Foundation

/// 正解の分かる会議画面の合成。実画面の前に、しきい値の当たりを付けるために使う。
/// 1秒ごとの観測を、位相をずらして複数本作る。前と同じ画面なら `idle` として書く(SCStreamと同じ)。
///
/// 筋書き(秒):
/// - 0〜15 静止スライド / 15 0.6秒のフェードで送る / 30 即時に細かい文書へ送る
/// - 40 文書の1文字を直す / 50〜54 文書へ1行を打つ / 62〜72 文書を連続スクロール
/// - 82〜97 画面の約22%(1920×1080に900×500)を占める動画、97で止まる / 105〜120 秒まで出す時計のあるスライド
/// - 120〜150 小さく回り続ける印のあるスライド / 150〜175 静止、158〜163 に通知バナー
/// - 175〜179.5 1.5秒ごとに3回ページを送る / 179.5〜186・186〜195・195〜215 それぞれ見てから送る
/// - 全区間: 上端24pxのメニューバーに分までの時計。30・90・150秒で分が変わる
/// - 30〜82: 文書の12行目の末尾でカーソルが0.53秒ごとに点滅する
///
/// `--scenario noise` は、意味のある変化が無いのに画面が小さく動き続ける場面だけを長く流す。1時間あたりの余分を見積もる。
/// - 0〜200 点滅するカーソルのある文書 / 200〜400 秒まで出す時計のあるスライド / 400〜600 小さく回り続ける印のあるスライド
///
/// 2026-11-11に足した「動き続ける画面」と「交互に変わる画面」の筋書きは `SynthMotion.swift`。
enum Synth {
    static let scenarios: [String: Scenario] = [
        "meeting": meeting, "noise": noise,
        "anim": anim, "video": fullVideo, "alternate": alternate, "return": returning, "pages": pages, "switch": switching,
        "mixed": mixed, "send": sendOnce,
    ]

    struct Scenario {
        let duration: Double
        let truth: [TruthWindow]
        let render: (Canvas, Double) -> Void
    }

    nonisolated(unsafe) static var fixedUnit: CGFloat?

    static let meeting = Scenario(duration: 215, truth: truth, render: renderMeeting)

    static let noise = Scenario(duration: 600, truth: [
        .init(from: 0, to: 200, min: 1, max: 1, label: "N1 点滅するカーソル"),
        .init(from: 200, to: 400, min: 1, max: 1, label: "N2 秒の時計"),
        .init(from: 400, to: 600, min: 1, max: 1, label: "N3 回る印"),
    ]) { canvas, t in
        switch t {
        case ..<200: canvas.document(t: 60, scroll: 0, blink: t)
        case 200..<400: canvas.slide(3); canvas.secondsClock(t: t)
        default: canvas.slide(4); canvas.spinner(t: t)
        }
        canvas.menuBar(t: t)
    }

    static let truth: [TruthWindow] = [
        .init(from: 0, to: 15, min: 1, max: 1, label: "S1 静止スライド"),
        // 遷移の途中のフレームを保存したら余分に数える。区間を分けないと、途中の1枚でも合格になる。
        .init(from: 15, to: 15.6, min: 0, max: 0, label: "S2 フェードの途中"),
        .init(from: 15.6, to: 30, min: 1, max: 1, label: "S2 フェード送り"),
        .init(from: 30, to: 40, min: 1, max: 1, label: "S3 即時送り(文書)"),
        .init(from: 40, to: 50, min: 1, max: 1, label: "S4 1文字の修正"),
        .init(from: 50, to: 62, min: 1, max: 1, label: "S5 1行の入力"),
        .init(from: 62, to: 72, min: 0, max: 0, label: "S6 スクロール中"),
        .init(from: 72, to: 82, min: 1, max: 1, label: "S6 スクロール後"),
        .init(from: 82, to: 97, min: 0, max: 1, label: "S7 動画の再生中"),
        .init(from: 97, to: 105, min: 1, max: 1, label: "S7 動画の停止後"),
        .init(from: 105, to: 120, min: 1, max: 1, label: "S8 秒の時計"),
        .init(from: 120, to: 150, min: 1, max: 1, label: "S9 回る印"),
        .init(from: 150, to: 175, min: 1, max: 3, label: "S10 通知バナー"),
        .init(from: 175, to: 179.5, min: 0, max: 3, label: "S11 続けて送る"),
        .init(from: 179.5, to: 186, min: 1, max: 1, label: "S11 6.5秒見る"),
        .init(from: 186, to: 195, min: 1, max: 1, label: "S11 9秒見る"),
        .init(from: 195, to: 215, min: 1, max: 1, label: "S11 最後のページ"),
    ]

    static func main(_ args: inout Arguments) throws {
        let out = URL(fileURLWithPath: try args.required("--out"))
        let size = (args.string("--size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { throw ProbeError.message("--size は 1920x1080 の形") }
        let phases = args.doubles("--phases") ?? [0, 0.37, 0.71]
        let snapshots = args.doubles("--snapshots") ?? []
        let minimumOneSecond = args.string("--interval") == "min1"
        // --unit 1: 大きな画面でも文字を等倍で描く。横長の外部ディスプレイに小さな文字のウィンドウを出した場面
        fixedUnit = args.double("--unit").map { CGFloat($0) }
        let name = args.string("--scenario") ?? "meeting"
        guard let scenario = scenarios[name] else {
            throw ProbeError.message("--scenario は \(scenarios.keys.sorted().joined(separator: " / ")) のどれか")
        }
        let duration = scenario.duration
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (number, phase) in phases.enumerated() {
            let dir = out.appendingPathComponent(String(format: "phase%d", number))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let writer = try RecordWriter(url: dir.appendingPathComponent("frames.jsonl"))
            var previous: Thumb?
            var index = 0
            var step = 0
            var jitter = SplitMix(seed: UInt64(number + 1))
            var time = phase
            while time < duration {
                let image = render(scenario, at: time, width: size[0], height: size[1])
                guard let thumb = Thumbnail.make(image, width: Thumbnail.recordWidth) else { throw ProbeError.message("縮小に失敗") }
                if thumb == previous {
                    writer.write(RecordLine(kind: "idle", t: time))
                } else {
                    writer.frame(index: index, time: time, thumb: thumb)
                    index += 1
                    previous = thumb
                }
                if number == 0, snapshots.contains(where: { abs($0 - time) < 0.5 }) {
                    let data = try WebPEncoder.encode(image, quality: 80)
                    try data.write(to: dir.appendingPathComponent(String(format: "snap-%05.1f.webp", time)))
                }
                // SCStreamの配送は位相が固定されない。±0.2秒揺らし、点滅と観測が同期したままにならないようにする。
                // この揺らし方では隣の観測の間隔が0.6〜1.4秒になる。--interval min1 は、本体の minimumFrameInterval と同じく
                // 間隔を1秒より短くしない。1.0〜1.4秒の間隔を積み重ねる(2026-11-11のレビュー 中6)。
                step += 1
                if minimumOneSecond {
                    time += 1 + Double(jitter.next() % 400) / 1000
                } else {
                    time = phase + Double(step) + Double(jitter.next() % 400) / 1000 - 0.2
                }
            }
            writer.write(RecordLine(kind: "end", t: duration))
            writer.close()
            try JSONEncoder().encode(scenario.truth).write(to: dir.appendingPathComponent("truth.json"))
            print("\(dir.path): 観測 \(index) 枚")
        }
    }

    // MARK: - 描画

    static func render(_ scenario: Scenario, at t: Double, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let canvas = Canvas(ctx: ctx, width: CGFloat(width), height: CGFloat(height))
        canvas.fill(.white)
        scenario.render(canvas, t)
        return ctx.makeImage()!
    }

    static func renderMeeting(_ canvas: Canvas, _ t: Double) {
        switch t {
        case ..<15: canvas.slide(0)
        case 15..<30:
            canvas.slide(0)
            canvas.ctx.setAlpha(min(1, (t - 15) / 0.6)); canvas.slide(1); canvas.ctx.setAlpha(1)
        case 30..<62: canvas.document(t: t, scroll: 0)
        case 62..<82: canvas.document(t: t, scroll: (min(t, 72) - 62) * 120)
        case 82..<105: canvas.slide(2); canvas.video(t: min(t, 97))
        case 105..<120: canvas.slide(3); canvas.secondsClock(t: t)
        case 120..<150: canvas.slide(4); canvas.spinner(t: t)
        case 150..<175:
            canvas.slide(5)
            if t >= 158 && t < 163 { canvas.banner() }
        case 175..<176.5: canvas.slide(0)
        case 176.5..<178: canvas.slide(1)
        case 178..<179.5: canvas.slide(5)
        case 179.5..<186: canvas.slide(3)
        case 186..<195: canvas.slide(0)
        default: canvas.slide(1)
        }
        canvas.menuBar(t: t)
    }

    final class Canvas {
        let ctx: CGContext
        let width: CGFloat
        let height: CGFloat
        /// 文字の大きさは横1920pxの画面に合わせた値を、幅に比例させる。
        var unit: CGFloat { Synth.fixedUnit ?? width / 1920 }
        /// 下端の位置。横1920pxの単位。
        var bottom: CGFloat { height / unit }

        init(ctx: CGContext, width: CGFloat, height: CGFloat) { self.ctx = ctx; self.width = width; self.height = height }

        func fill(_ color: CGColor) { ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)) }

        func rect(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
            ctx.setFillColor(color); ctx.fill(CGRect(x: x, y: height - top - h, width: w, height: h))
        }

        /// 描いた文字列の幅を、横1920pxの単位で返す。
        @discardableResult
        func text(_ string: String, x: CGFloat, top: CGFloat, size: CGFloat, bold: Bool = false, color: CGColor = .black) -> CGFloat {
            let font = CTFontCreateWithName((bold ? "HiraginoSans-W6" : "HiraginoSans-W3") as CFString, size * unit, nil)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: x * unit, y: height - top * unit - size * unit)
            CTLineDraw(line, ctx)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / unit
        }

        func menuBar(t: Double) {
            rect(x: 0, top: 0, w: width, h: 24 * unit, color: CGColor(gray: 0.92, alpha: 1))
            text("Keynote   ファイル   編集   挿入   スライド   表示", x: 16, top: 4, size: 13)
            let minutes = Int((t + 30) / 60)
            text(String(format: "11月9日(日) 10:%02d", minutes), x: 1760, top: 4, size: 13)
        }

        static let slides: [(String, [String])] = [
            ("画面の記録 第0フェーズ", ["撮る対象はディスプレイを1枚選ぶ", "画面が意味のある変化をして落ち着いたときに撮る", "開始・再開の直後にも1枚撮る", "保存は1x寸法の非可逆WebP"]),
            ("決めること", ["落ち着きの判定のしきい値", "保存する価値の判定のしきい値", "落ち着く秒数の初期値", "題の取り方と許可の扱い"]),
            ("デモ動画", ["録音しながら資料を映す様子"]),
            ("負荷の見込み", ["SCStreamは1秒に1枚", "縮小した輝度画像で比べる", "保存は落ち着いたときだけ"]),
            ("読み込み中の表示", ["回る印が残り続ける画面", "変化が小さく続く"]),
            ("まとめ", ["しきい値は試作で決める", "取りこぼしより余分な1枚を許す", "許可の挙動は実機で見る"]),
        ]

        /// 白い背景から描く。フェードで重ねたとき、終わった後に前のページが残らないようにする。
        func slide(_ number: Int) {
            fill(.white)
            let (title, bullets) = Self.slides[number]
            text(title, x: 120, top: 120, size: 56, bold: true)
            for (offset, bullet) in bullets.enumerated() { text("・" + bullet, x: 140, top: 260 + CGFloat(offset) * 64, size: 32) }
            text("\(number + 1) / \(Self.slides.count)", x: 1760, top: bottom - 60, size: 18, color: CGColor(gray: 0.5, alpha: 1))
        }

        static let documentLines: [String] = (0..<140).map { line in
            let pool = ["会議中の画面を記録して、書き起こしの時間軸とAIへ渡す会話に結びつける。",
                        "The SCStream delivers complete frames with dirty rects and idle notices when nothing changes.",
                        "保存する価値の判定は最後に保存した画像と比べ、落ち着きの判定は直前のフレームと比べる。",
                        "minimumFrameInterval = 1s, showsCursor = false, captureResolution = .nominal",
                        "取りこぼした画面は後から取り戻せないので、余分な1枚を許す側に倒す。"]
            return String(format: "%03d  ", line + 1) + pool[line % pool.count]
        }

        func document(t: Double, scroll: Double, blink: Double? = nil) {
            let blink = blink ?? t
            text("画面の記録 設計メモ.md — 編集済み", x: 40, top: 32, size: 14, color: CGColor(gray: 0.4, alpha: 1))
            for (offset, base) in Self.documentLines.enumerated() {
                let top = 64 + CGFloat(offset) * 22 - CGFloat(scroll)
                guard top > 40, top < height / unit - 10 else { continue }
                var line = base
                if offset == 4 { line = t >= 40 ? "005  リリース予定: 2026年12月" : "005  リリース予定: 2025年12月" }
                if offset == 11 {
                    let typed = "決定事項: 画面の記録は第0フェーズで測る"
                    let count = t < 50 ? 0 : min(typed.count, Int((t - 50) / 0.2))
                    line = "012  " + String(typed.prefix(count))
                }
                let drawn = text(line, x: 40, top: top, size: 16)
                // 入力欄のカーソルは0.53秒ごとに点滅する(macOSの既定に近い周期)。
                if offset == 11, Int(blink / 0.53) % 2 == 0 { rect(x: (42 + drawn) * unit, top: (top + 1) * unit, w: 2 * unit, h: 18 * unit, color: .black) }
            }
        }

        func video(t: Double) {
            let x = 510 * unit, top = 300 * unit, w = 900 * unit, h = 500 * unit
            let frame = Int(t * 30)
            var generator = SplitMix(seed: UInt64(frame))
            for row in 0..<10 { for column in 0..<18 {
                let shade = 0.2 + 0.6 * Double(generator.next() % 1000) / 1000
                rect(x: x + CGFloat(column) * w / 18, top: top + CGFloat(row) * h / 10, w: w / 18 + 1, h: h / 10 + 1,
                     color: CGColor(red: shade, green: shade * 0.8, blue: 1 - shade, alpha: 1))
            } }
        }

        func secondsClock(t: Double) {
            let seconds = 105 + Int(t)
            text(String(format: "10:%02d:%02d", seconds / 60, seconds % 60), x: 1720, top: bottom - 120, size: 20, color: CGColor(gray: 0.3, alpha: 1))
        }

        func spinner(t: Double) {
            let center = CGPoint(x: 960 * unit, y: 180 * unit)
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); ctx.setLineWidth(5 * unit)
            let start = CGFloat(t * 2 * .pi)
            ctx.addArc(center: center, radius: 20 * unit, startAngle: start, endAngle: start + 1.5 * .pi, clockwise: false)
            ctx.strokePath()
        }

        func banner() {
            rect(x: 1520 * unit, top: 40 * unit, w: 380 * unit, h: 84 * unit, color: CGColor(gray: 0.85, alpha: 1))
            text("Slack  田中: 例の資料、共有しました", x: 1540, top: 56, size: 15, bold: true)
            text("このあと確認お願いします", x: 1540, top: 88, size: 14)
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
