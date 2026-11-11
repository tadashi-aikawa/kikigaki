import CoreGraphics
import Foundation

/// 2026-11-11に足した筋書き。「動き続ける画面」と「交互に変わる画面」の規則の案を測る。
/// 正解の区間は「撮ってはいけない所」「1枚要る所」と、数え方の違う区間に分ける。数え方は `TruthWindow.kind`。
/// 動く画像の枠は画面の面積に対する割合で決める。横長に等倍の文字を描いた画面でも、割合は書いたとおりになる。
///
/// - anim(400秒): 動く画像の入ったスライド。各30秒で、正解は各1枚。最初の保存までの秒数を数える
///   - 0〜20 静止 / 20〜50 画面の10%が動く / 50〜80 25% / 80〜110 50%。20〜110は動くスライドを続けて送る
///   - 110〜130 静止 / 130〜160 25%が動く / 160〜190 同じ位置に別の動く画像の別のスライド / 190〜210 静止
///   - 210〜300 4秒動いて2秒・3秒・4秒止まるを繰り返すGIF。1周ごとに同じ絵へ戻る
///   - 300〜330 静止したスライドの上を、画面に描き込んだポインタが動き続ける。本体はマウスポインタを撮らないので、描き込んだもので測る
///   - 330〜360 動く画像のスライドに、345〜350 通知バナー。正解は1〜3枚
///   - 360〜375 動く画像のスライド / 375〜375.6 動いたまま0.6秒のフェード(途中) / 375.6〜390 別の動く画像のスライド / 390〜400 静止
/// - pages(169秒): 文書のページ送りとスクロール。送りの途中は「途中」として別に数える
///   - 固有の本文のページを1.5秒ごとに8回 → 6.5秒・9秒・9.5秒見る。1秒ごとに15回 → 同じ
///   - 本文が同じで、行番号とヘッダーのページ番号だけが違うページを1.5秒ごとに8回 → 同じ
///   - 30秒の連続スクロール → 15秒見る
/// - switch(175秒): 外したマスが次の画面を隠さないか
///   - 0〜10 静止 / 10〜40 動く画像のスライド / 40〜55 枠を動かす / 55〜70 枠を広げる / 70〜100 枠の中にだけ吹き出しが出る
///   - 100〜130 動画の小窓を残したまま、後ろのウィンドウを文書にする / 130〜160 後ろをスライドに切り替える / 160〜175 静止
/// - video(100秒): 0〜10 静止A / 10〜70 全画面の動画。場面の切り替わり5回。要る枚数は1 / 70〜85 Aへ戻る / 85〜100 静止B
/// - alternate(320秒): 2枚が3秒・5秒・10秒おき、3枚・4枚が3秒おきに巡る。ページごとに初回の取りこぼしと再保存を数える
/// - return(360秒): A 15秒 → B 20秒・60秒・180秒 → Aへ戻る。戻ったAを拾ったかを別に数える
extension Synth {
    static func need(_ from: Double, _ to: Double, _ label: String, latency: Bool = false, max: Int = 1) -> TruthWindow {
        TruthWindow(from: from, to: to, min: 1, max: max, label: label, latency: latency ? true : nil)
    }

    static func transit(_ from: Double, _ to: Double, _ label: String) -> TruthWindow {
        TruthWindow(from: from, to: to, min: 0, max: 99, label: label, kind: "transit")
    }

    static let anim = Scenario(duration: 400, truth: [
        need(0, 20, "A1 静止"),
        need(20, 50, "A2 動く画像10%", latency: true),
        need(50, 80, "A3 動く画像25%", latency: true),
        need(80, 110, "A4 動く画像50%", latency: true),
        need(110, 130, "A5 静止"),
        need(130, 160, "A6 動く画像25%", latency: true),
        need(160, 190, "A7 同じ位置の別の動く画像", latency: true),
        need(190, 210, "A8 静止"),
        need(210, 240, "A9 2秒止まる動く画像", latency: true),
        need(240, 270, "A10 3秒止まる動く画像", latency: true),
        need(270, 300, "A11 4秒止まる動く画像", latency: true),
        need(300, 330, "A12 描き込んだポインタ", latency: true),
        need(330, 360, "A13 動く画像と通知バナー", latency: true, max: 3),
        need(360, 375, "A14 動く画像のスライド", latency: true),
        transit(375, 375.6, "A15 動いたままのフェード"),
        need(375.6, 390, "A15 フェード後の動く画像のスライド", latency: true),
        need(390, 400, "A16 静止"),
    ]) { canvas, t in
        switch t {
        case ..<20: canvas.plainSlide(title: "動く画像の入った資料", bullets: ["画面の一部が動き続ける", "話している間も落ち着かない"], page: 1)
        case 20..<50:
            canvas.plainSlide(title: "操作の流れ", bullets: ["端末で返送する", "進行が表示される"], page: 2)
            canvas.demoAnimation(t: t, canvas.areaBox(0.10))
        case 50..<80:
            canvas.plainSlide(title: "話者の切り替わり", bullets: ["声の区間を色で示す", "重なりは両方に出る"], page: 3)
            canvas.cartoonAnimation(t: t, canvas.areaBox(0.25), seed: 1)
        case 80..<110:
            canvas.plainSlide(title: "録画の例", bullets: ["実際の画面"], page: 4)
            canvas.videoAnimation(t: t, canvas.areaBox(0.50), seed: 2)
        case 110..<130: canvas.plainSlide(title: "ここまでのまとめ", bullets: ["動く画像は1枚残せばよい", "送ったら次の1枚"], page: 5)
        case 130..<160:
            canvas.plainSlide(title: "議事録の更新", bullets: ["AIが書き足す", "差分だけ光る"], page: 6)
            canvas.cartoonAnimation(t: t, canvas.areaBox(0.25), seed: 3)
        case 160..<190:
            canvas.plainSlide(title: "ボードの更新", bullets: ["論点が木で並ぶ", "決まった所に印"], page: 7)
            canvas.cartoonAnimation(t: t, canvas.areaBox(0.25), seed: 4)
        case 190..<210: canvas.plainSlide(title: "次の話題", bullets: ["止まる動く画像"], page: 8)
        case 210..<300:
            let hold = 2 + Double(Int((t - 210) / 30))
            canvas.plainSlide(title: "止まりながら動く画像 \(Int(hold))秒", bullets: ["4秒動いて止まる"], page: 9 + Int(hold) - 2)
            canvas.cartoonAnimation(t: Self.holding(t, moving: 4, hold: hold), canvas.areaBox(0.25), seed: 5 + Int(hold))
        case 300..<330:
            canvas.plainSlide(title: "ポインタで指しながら説明", bullets: ["図の右側を見てください", "ここが話者の区間です", "ここが重なりです"], page: 12)
            canvas.pointer(t: t)
        case 330..<360:
            canvas.plainSlide(title: "通知が来る", bullets: ["動く画像の上に通知"], page: 13)
            canvas.cartoonAnimation(t: t, canvas.areaBox(0.25), seed: 9)
            if t >= 345 && t < 350 { canvas.banner() }
        case 360..<390:
            let first = { canvas.plainSlide(title: "フェードで送る前", bullets: ["動画が流れている"], page: 14); canvas.videoAnimation(t: t, canvas.areaBox(0.25), seed: 10) }
            let second = { canvas.plainSlide(title: "フェードで送った後", bullets: ["別の動く画像"], page: 15); canvas.cartoonAnimation(t: t, canvas.areaBox(0.25, left: true), seed: 11) }
            if t < 375 { first() } else {
                first()
                canvas.ctx.setAlpha(min(1, (t - 375) / 0.6)); second(); canvas.ctx.setAlpha(1)
            }
        default: canvas.plainSlide(title: "動く画像のまとめ", bullets: ["1枚ずつ残る"], page: 16)
        }
        canvas.menuBar(t: t)
    }

    /// 動いて止まるを繰り返すGIFの時刻。GIFと同じく1周ごとに同じ絵へ戻り、止まっている間は最後の絵のまま。
    static func holding(_ t: Double, moving: Double, hold: Double) -> Double {
        min(t.truncatingRemainder(dividingBy: moving + hold), moving)
    }

    static let pages = Scenario(duration: 169, truth: [
        need(0, 10, "P1 最初のページ"),
        transit(10, 22, "P2 固有の本文を1.5秒ごとに8回送る"),
        need(22, 28.5, "P2 6.5秒見る"), need(28.5, 37.5, "P2 9秒見る"), need(37.5, 47, "P2 9.5秒見る"),
        transit(47, 62, "P3 固有の本文を1秒ごとに15回送る"),
        need(62, 68.5, "P3 6.5秒見る"), need(68.5, 77.5, "P3 9秒見る"), need(77.5, 87, "P3 9.5秒見る"),
        transit(87, 99, "P4 本文が同じで行番号とページ番号だけ違うページを1.5秒ごとに8回送る"),
        need(99, 105.5, "P4 6.5秒見る"), need(105.5, 114.5, "P4 9秒見る"), need(114.5, 124, "P4 9.5秒見る"),
        transit(124, 154, "P5 30秒の連続スクロール"),
        need(154, 169, "P5 スクロール後"),
    ]) { canvas, t in
        switch t {
        case ..<10: canvas.documentPage(0)
        case 10..<22: canvas.documentPage(1 + Int((t - 10) / 1.5))
        case 22..<28.5: canvas.documentPage(9)
        case 28.5..<37.5: canvas.documentPage(10)
        case 37.5..<47: canvas.documentPage(11)
        case 47..<62: canvas.documentPage(12 + Int(t - 47))
        case 62..<68.5: canvas.documentPage(27)
        case 68.5..<77.5: canvas.documentPage(28)
        case 77.5..<87: canvas.documentPage(29)
        case 87..<99: canvas.documentPage(30 + Int((t - 87) / 1.5), numbersOnly: true)
        case 99..<105.5: canvas.documentPage(38, numbersOnly: true)
        case 105.5..<114.5: canvas.documentPage(39, numbersOnly: true)
        case 114.5..<124: canvas.documentPage(40, numbersOnly: true)
        // 1秒に90px。既存の会議の筋書きのスクロールより少し遅く、3倍の長さ
        default: canvas.document(t: 60, scroll: (min(t, 154) - 124) * 90, blink: 0)
        }
        canvas.menuBar(t: t)
    }

    static let switching = Scenario(duration: 175, truth: [
        need(0, 10, "W0 静止"),
        need(10, 40, "W1 動く画像のスライド", latency: true),
        need(40, 55, "W2 枠を動かす", latency: true),
        need(55, 70, "W3 枠を広げる", latency: true),
        need(70, 100, "W4 枠の中にだけ吹き出し", latency: true),
        need(100, 130, "W5 動画の小窓と文書", latency: true),
        need(130, 160, "W6 小窓を残して後ろを切り替え", latency: true),
        need(160, 175, "W7 静止"),
    ]) { canvas, t in
        switch t {
        case ..<10: canvas.plainSlide(title: "切り替えの前", bullets: ["静止"], page: 2)
        case 10..<100:
            canvas.plainSlide(title: "動く画像の枠", bullets: ["枠を動かす", "枠を広げる", "枠の中に注記"], page: 3)
            let box = t < 40 ? canvas.areaBox(0.25) : t < 55 ? canvas.areaBox(0.25, left: true) : canvas.areaBox(0.40, left: true)
            canvas.cartoonAnimation(t: t, box, seed: 21)
            if t >= 70 { canvas.callout(in: box) }
        case 100..<160:
            if t < 130 { canvas.documentPage(50) } else { canvas.plainSlide(title: "後ろのウィンドウ", bullets: ["小窓は残ったまま"], page: 4) }
            canvas.videoAnimation(t: t, canvas.areaBox(0.08), seed: 22)
        default: canvas.plainSlide(title: "切り替えのまとめ", bullets: ["隠れた中身も残る"], page: 5)
        }
        canvas.menuBar(t: t)
    }

    static let fullVideo = Scenario(duration: 100, truth: [
        need(0, 10, "V1 静止A"),
        need(10, 70, "V2 全画面の動画", latency: true),
        TruthWindow(from: 70, to: 85, min: 0, max: 1, label: "戻りA 動画60秒の後", kind: "return"),
        need(85, 100, "V3 静止B"),
    ]) { canvas, t in
        switch t {
        case ..<10, 70..<85: canvas.plainSlide(title: "動画を見ながら話す", bullets: ["全画面で再生する"], page: 1); canvas.menuBar(t: t)
        case 10..<70: canvas.fullScreenVideo(t: t - 10)
        default: canvas.plainSlide(title: "動画の感想", bullets: ["場面ごとに話す"], page: 2); canvas.menuBar(t: t)
        }
    }

    /// 入れ替わりの区切り。(開始, 終了, 間隔, 枚数, 最初の図の番号)
    static let alternations: [(from: Double, to: Double, interval: Double, count: Int, panel: Int)] = [
        (10, 70, 3, 2, 0), (70, 130, 5, 2, 2), (130, 190, 10, 2, 4), (190, 250, 3, 3, 6), (250, 310, 3, 4, 9),
    ]

    static let alternate = Scenario(duration: 320, truth: [need(0, 10, "B0 静止")] + alternations.enumerated().flatMap { offset, block -> [TruthWindow] in
        stride(from: block.from, to: block.to, by: block.interval).map { start in
            let index = Int(((start - block.from) / block.interval).rounded()) % block.count
            return TruthWindow(from: start, to: min(start + block.interval, block.to), min: 0, max: 99,
                               label: "B\(offset + 1) \(block.count)枚が\(Int(block.interval))秒おき", kind: "page", group: "B\(offset + 1)", page: block.panel + index)
        }
    } + [need(310, 320, "B9 静止")]) { canvas, t in
        if t < 10 {
            canvas.plainSlide(title: "自動で切り替わるスライド", bullets: ["説明の間も入れ替わる"], page: 1)
        } else if let (offset, block) = alternations.enumerated().first(where: { t >= $0.element.from && t < $0.element.to }) {
            let index = Int((t - block.from) / block.interval) % block.count
            canvas.panelSlide(title: "AIエージェントに任せること \(offset + 1)", panel: block.panel + index, page: 2 + offset)
        } else {
            canvas.plainSlide(title: "切り替わりのまとめ", bullets: ["同じ画面は1枚でよい"], page: 9)
        }
        canvas.menuBar(t: t)
    }

    /// 戻る操作。(Aの開始, Bの開始, Aへ戻る, 終わり)
    static let returns: [(a: Double, b: Double, back: Double, end: Double)] = [(0, 15, 35, 50), (50, 65, 125, 140), (140, 155, 335, 350)]

    static let returning = Scenario(duration: 360, truth: returns.enumerated().flatMap { offset, item -> [TruthWindow] in
        let names = [("A", "B"), ("C", "D"), ("E", "F")][offset]
        return [
            need(item.a, item.b, "R\(names.0)"),
            need(item.b, item.back, "R\(names.1) \(Int(item.back - item.b))秒"),
            TruthWindow(from: item.back, to: item.end, min: 0, max: 1, label: "戻り\(names.0) \(Int(item.back - item.b))秒後", kind: "return"),
        ]
    } + [need(350, 360, "R 静止")]) { canvas, t in
        if let (offset, item) = returns.enumerated().first(where: { t >= $0.element.a && t < $0.element.end }) {
            let second = t >= item.b && t < item.back
            canvas.panelSlide(title: second ? "比べる案 \(offset + 1)" : "前提 \(offset + 1)", panel: 13 + offset * 2 + (second ? 1 : 0), page: 1 + offset * 2 + (second ? 1 : 0))
        } else {
            canvas.plainSlide(title: "質疑", bullets: ["戻って見せた所を確かめる"], page: 9)
        }
        canvas.menuBar(t: t)
    }
}

/// 横1920pxの単位での長方形。
struct UnitBox { let x: CGFloat; let top: CGFloat; let w: CGFloat; let h: CGFloat }

extension Synth.Canvas {
    func box(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor) {
        rect(x: x * unit, top: top * unit, w: w * unit, h: h * unit, color: color)
    }

    func ellipse(cx: CGFloat, cy: CGFloat, r: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: (cx - r) * unit, y: height - (cy + r) * unit, width: 2 * r * unit, height: 2 * r * unit))
    }

    /// 画面の面積のこの割合を占める16:9の枠。右下(left なら左下)に寄せ、題の下に収める。
    func areaBox(_ fraction: Double, left: Bool = false) -> UnitBox {
        let screenW = width / unit, screenH = bottom
        var w = CGFloat((fraction * Double(screenW * screenH) * 16 / 9).squareRoot()), h = w * 9 / 16
        // 題と重ならない高さに収まらなければ、面積を保って横長にする
        let room = screenH - 200 - 40
        if h > room { h = room; w = CGFloat(fraction) * screenW * screenH / h }
        let x = left ? 60 : screenW - w - 60
        return UnitBox(x: x, top: screenH - h - 40, w: w, h: h)
    }

    /// 白い背景に題と箇条とページ番号。既存の `slide` と同じ体裁で、中身を引数で渡す。
    func plainSlide(title: String, bullets: [String], page: Int) {
        fill(.white)
        text(title, x: 120, top: 120, size: 56, bold: true)
        for (offset, bullet) in bullets.enumerated() { text("・" + bullet, x: 140, top: 260 + CGFloat(offset) * 64, size: 32) }
        text("\(page) / 31", x: width / unit - 160, top: bottom - 60, size: 18, color: CGColor(gray: 0.5, alpha: 1))
    }

    /// 題が同じで、図の枠の中身だけが違うスライド。実例の 2026-11-11_0756 は図と議事録の画面が入れ替わっていた。
    func panelSlide(title: String, panel: Int, page: Int) {
        fill(CGColor(red: 0.95, green: 0.91, blue: 0.85, alpha: 1))
        text("1層目 声を記録する    2層目 AIエージェントとつなぐ", x: 120, top: 100, size: 28, color: CGColor(gray: 0.35, alpha: 1))
        text(title, x: 120, top: 160, size: 56, bold: true)
        // 小見出しの強調も図に合わせて変わる。実例と同じ
        text(panel % 2 == 0 ? "議事録・[ボード]の更新" : "[議事録]・ボードの更新", x: 120, top: 260, size: 32, bold: true)
        box(120, 330, 940, 470, CGColor(gray: 0.99, alpha: 1))
        var generator = SplitMix(seed: UInt64(panel * 7919 + 13))
        func random(_ range: Int) -> CGFloat { CGFloat(generator.next() % UInt64(range)) }
        switch panel % 3 {
        case 0:
            for row in 0..<3 { for column in 0..<(row + 2) {
                let x = 160 + CGFloat(column) * (860 / CGFloat(row + 2)) + random(40), top = 370 + CGFloat(row) * 140
                box(x, top, 150, 70, CGColor(red: 0.85, green: 0.95 - random(30) / 100, blue: 0.85, alpha: 1))
                text("T\(row * 4 + column + panel)", x: x + 20, top: top + 20, size: 22, bold: true)
            } }
        case 1:
            text("勉強会の準備 \(panel)", x: 160, top: 370, size: 34, bold: true)
            for line in 0..<7 {
                text("・決まったこと \(line + 1): " + String(repeating: "資料の構成を見直す", count: 1 + Int(random(2))), x: 170, top: 430 + CGFloat(line) * 50, size: 24)
            }
        default:
            for bar in 0..<8 {
                let h = 80 + random(300)
                box(180 + CGFloat(bar) * 105, 760 - h, 70, h, CGColor(red: 0.3 + random(50) / 100, green: 0.4, blue: 0.7, alpha: 1))
            }
            text("月ごとの会議の数 \(panel)", x: 160, top: 360, size: 28, bold: true)
        }
        text("\(page) / 31", x: width / unit - 160, top: bottom - 60, size: 18, color: CGColor(gray: 0.5, alpha: 1))
    }

    static let words = ["会議", "画面", "記録", "保存", "判定", "話者", "議事録", "AIへ渡す", "しきい値", "落ち着く", "SCStream", "frame", "idle",
                        "WebP", "縮小画像", "比較の基準", "受付の番号", "公開", "保留", "無音", "音量", "参加者", "送信", "返答", "決定事項", "宿題"]

    /// 小さな文字の文書の1ページ。固有の本文なら行ごとに語の並びと長さが変わる。
    /// numbersOnly なら本文は全ページ同じで、行番号とヘッダーのページ番号だけが変わる。
    func documentPage(_ page: Int, numbersOnly: Bool = false) {
        text("画面の記録 設計メモ.pdf — \(page)ページ", x: 40, top: 32, size: 14, color: CGColor(gray: 0.4, alpha: 1))
        for line in 0..<80 {
            let top = 64 + CGFloat(line) * 22
            guard top < bottom - 10 else { break }
            var generator = SplitMix(seed: UInt64((numbersOnly ? 100 : page) * 1000 + line))
            let count = 3 + Int(generator.next() % 8)
            let body = (0..<count).map { _ in Self.words[Int(generator.next() % UInt64(Self.words.count))] }.joined(separator: " ")
            text(String(format: "%04d  ", page * 80 + line + 1) + body, x: 40, top: top, size: 16)
        }
    }

    /// 操作の録画を流すGIF。端末への入力と進行の棒、動く指先。6秒で1周し、最後の2秒は入力を出し切ったまま。
    func demoAnimation(t: Double, _ b: UnitBox) {
        box(b.x, b.top, b.w, b.h, CGColor(gray: 0.15, alpha: 1))
        box(b.x, b.top, b.w, 28, CGColor(gray: 0.3, alpha: 1))
        let phase = t.truncatingRemainder(dividingBy: 6)
        let command = "kikigaki-cli reply --request 42 < answer.md"
        let typed = phase < 4 ? Int(phase / 4 * Double(command.count)) : command.count
        text("$ " + String(command.prefix(typed)), x: b.x + 16, top: b.top + 50, size: 18, color: CGColor(gray: 0.9, alpha: 1))
        if phase >= 4 {
            text("受け付けました: request 42", x: b.x + 16, top: b.top + 90, size: 18, color: CGColor(red: 0.5, green: 0.9, blue: 0.5, alpha: 1))
        }
        box(b.x + 16, b.top + b.h - 40, (b.w - 32) * CGFloat(phase / 6), 14, CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 1))
        let angle = t * 1.3
        ellipse(cx: b.x + b.w / 2 + CGFloat(cos(angle)) * b.w * 0.3, cy: b.top + b.h / 2 + CGFloat(sin(angle)) * b.h * 0.2, r: 12,
                color: CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
    }

    /// 絵のGIF。淡い背景の上で、6つの玉が別々の速さで跳ね回る。玉の無い所はまれにしか変わらない。
    func cartoonAnimation(t: Double, _ b: UnitBox, seed: Int) {
        var generator = SplitMix(seed: UInt64(seed))
        func random() -> Double { Double(generator.next() % 1000) / 1000 }
        box(b.x, b.top, b.w, b.h, CGColor(red: 0.8 + random() * 0.15, green: 0.9, blue: 0.8 + random() * 0.15, alpha: 1))
        let radius = min(b.w, b.h) * 0.08
        for _ in 0..<6 {
            let vx = 0.05 + random() * 0.2, vy = 0.05 + random() * 0.2, px = random(), py = random()
            func bounce(_ value: Double) -> CGFloat { let p = value.truncatingRemainder(dividingBy: 2); return CGFloat(p < 1 ? p : 2 - p) }
            let cx = b.x + radius + bounce(px + vx * t) * (b.w - 2 * radius), cy = b.top + radius + bounce(py + vy * t) * (b.h - 2 * radius)
            ellipse(cx: cx, cy: cy, r: radius, color: CGColor(red: random(), green: random() * 0.6, blue: random(), alpha: 1))
        }
    }

    /// 動画のGIF。縞が流れ、色がゆっくり変わり、四角が横切る。枠の全体が毎秒変わる。
    func videoAnimation(t: Double, _ b: UnitBox, seed: Int) {
        let stripes = 16
        for stripe in 0..<stripes {
            let shade = 0.45 + 0.35 * sin(Double(stripe) * 0.8 + t * 2.1 + Double(seed))
            box(b.x + CGFloat(stripe) * b.w / CGFloat(stripes), b.top, b.w / CGFloat(stripes) + 1, b.h,
                CGColor(red: shade, green: 0.5 + 0.3 * sin(t * 0.3), blue: 1 - shade, alpha: 1))
        }
        let p = (t * 0.17).truncatingRemainder(dividingBy: 1)
        box(b.x + CGFloat(p) * b.w * 0.8, b.top + b.h * 0.4, b.w * 0.2, b.h * 0.25, CGColor(gray: 0.95, alpha: 1))
    }

    /// 発表者がスライドに描き込むポインタ。赤い点が図の上を動き続ける。
    func pointer(t: Double) {
        let cx = width / unit * 0.55 + CGFloat(sin(t * 0.9)) * 300, cy = bottom * 0.55 + CGFloat(sin(t * 1.3)) * 180
        ellipse(cx: cx, cy: cy, r: 14, color: CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1))
    }

    /// 枠の中にだけ出る吹き出し。枠の中央の約4割を覆う。
    func callout(in b: UnitBox) {
        let w = b.w * 0.6, h = b.h * 0.6
        box(b.x + (b.w - w) / 2, b.top + (b.h - h) / 2, w, h, CGColor(gray: 1, alpha: 1))
        text("注: ここが話者の重なり", x: b.x + (b.w - w) / 2 + 24, top: b.top + (b.h - h) / 2 + 24, size: 28, bold: true)
        text("重なった区間は両方の話者に付く", x: b.x + (b.w - w) / 2 + 24, top: b.top + (b.h - h) / 2 + 80, size: 22)
    }

    /// 全画面の動画。場面の切り替わりで絵の形が変わる。メニューバーは出ない。
    func fullScreenVideo(t: Double) {
        let cuts: [Double] = [0, 12, 21, 34, 42, 51]
        let scene = cuts.lastIndex { t >= $0 } ?? 0
        let local = t - cuts[scene]
        let W = width / unit, H = bottom
        switch scene {
        case 0:
            for band in 0..<12 { box(0, CGFloat(band) * H / 24, W, H / 24 + 1, CGColor(red: 0.4, green: 0.6 + CGFloat(band) * 0.02, blue: 0.95, alpha: 1)) }
            box(0, H / 2, W, H / 2, CGColor(red: 0.3, green: 0.55, blue: 0.3, alpha: 1))
            for hill in 0..<8 {
                let cx = (CGFloat(hill) * 300 - CGFloat(local) * 90).truncatingRemainder(dividingBy: W + 300)
                ellipse(cx: cx < -150 ? cx + W + 300 : cx, cy: H / 2, r: 160 + CGFloat(hill % 3) * 40, color: CGColor(red: 0.25, green: 0.45, blue: 0.3, alpha: 1))
            }
        case 1:
            var generator = SplitMix(seed: UInt64(Int(t * 30)))
            for row in 0..<12 { for column in 0..<20 {
                let shade = 0.2 + 0.6 * Double(generator.next() % 1000) / 1000
                box(CGFloat(column) * W / 20, CGFloat(row) * H / 12, W / 20 + 1, H / 12 + 1, CGColor(red: shade, green: shade * 0.7, blue: 0.5, alpha: 1))
            } }
        case 2:
            // 落ち着いた対談: 背景は止まり、人の頭と口元だけが小さく動く
            box(0, 0, W, H, CGColor(red: 0.55, green: 0.45, blue: 0.35, alpha: 1))
            for shelf in 0..<4 { box(100, 120 + CGFloat(shelf) * 200, 600, 30, CGColor(red: 0.35, green: 0.25, blue: 0.2, alpha: 1)) }
            let sway = CGFloat(sin(local * 1.7)) * 25
            ellipse(cx: W * 0.62 + sway, cy: 420, r: 150, color: CGColor(red: 0.9, green: 0.75, blue: 0.6, alpha: 1))
            box(W * 0.62 - 50 + sway, 480, 100, 20 + CGFloat(abs(sin(local * 5))) * 25, CGColor(red: 0.5, green: 0.2, blue: 0.2, alpha: 1))
            box(W * 0.62 - 200 + sway / 2, 600, 400, H - 600, CGColor(red: 0.2, green: 0.25, blue: 0.4, alpha: 1))
        case 3:
            box(0, 0, W, H, CGColor(gray: 0.1, alpha: 1))
            for ring in (0..<10).reversed() {
                let r = (CGFloat(ring) * 120 + CGFloat(local) * 150).truncatingRemainder(dividingBy: 1200)
                ellipse(cx: W / 2, cy: H / 2, r: r, color: CGColor(gray: ring % 2 == 0 ? 0.7 : 0.15, alpha: 1))
            }
        case 4:
            box(0, 0, W, H, CGColor(gray: 0.05, alpha: 1))
            cartoonAnimation(t: local, UnitBox(x: 0, top: 0, w: W, h: H), seed: 9)
        default:
            box(0, 0, W, H, CGColor(gray: 0.02, alpha: 1))
            for line in 0..<30 {
                let y = H - CGFloat(local) * 60 + CGFloat(line) * 70
                guard y > -40, y < H else { continue }
                text("出演  KIKIGAKI \(line)  画面の記録", x: W * 0.36, top: y, size: 32, color: CGColor(gray: 0.9, alpha: 1))
            }
        }
    }
}
