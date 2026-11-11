import Foundation
import Testing
@testable import KikigakiCore

/// 画面の記録の行が、手入力と共通にする経路・専用の枝・声に限る経路のそれぞれで正しく扱われること。
@Suite struct ScreenEntriesTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let start = Date(timeIntervalSince1970: 0)
    private var timeline: MeetingTimeline { .init(startedAt: start) }
    private let imagePath = "/tmp/会議.captures/000140.webp"
    private func screen(at: Double = 60, observed: Double = 100, label: String = "EV3895 · Keynote「提案資料」") throws -> Utterance {
        try Utterance(screenLabel: label, imagePath: imagePath, at: at, postedAt: start.addingTimeInterval(observed))
    }
    private func voice(_ text: String, at: Double, speaker: Int? = 0) -> Utterance {
        Utterance(speaker: speaker, start: at, end: at + 1, text: text)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-entries-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func 画像の行とイベントの行を往復し由来の値を保つ() throws {
        let image = try screen()
        let event = try Utterance(screenEvent: .unavailable("ディスプレイが外れました"), at: 70, postedAt: start.addingTimeInterval(110))
        for entry in [image, event] {
            #expect(try JSONDecoder().decode(Utterance.self, from: JSONEncoder().encode(entry)) == entry)
            #expect(try AIJSON.decode(Utterance.self, from: AIJSON.encode(entry)) == entry)
            #expect(entry.isEntry && entry.speaker == nil && entry.start == entry.end)
        }
        #expect(image.screenEvent == nil)
        #expect(event.screenEvent == .unavailable("ディスプレイが外れました"))
        #expect(try Utterance(screenEvent: .stopped, at: 0, postedAt: start).text == "記録を停止")
        #expect(try Utterance(screenEvent: .resumed, at: 0, postedAt: start).text == "記録を再開")
    }

    @Test func 見出しの改行と制御文字を空白へ寄せる() throws {
        #expect(try screen(label: "EV3895 · Chrome「長い\nタイトル\t付き」").text == "EV3895 · Chrome「長い タイトル 付き」")
    }

    @Test(arguments: [
        // 画像の行: 画像は1枚だけ、見出しは空にしない、話者・幅・投稿日時を持つ値は不正
        #"{"kind":"screen","postedAt":0,"start":1,"end":1,"text":"EV3895","imagePaths":["/tmp/a.webp","/tmp/b.webp"]}"#,
        #"{"kind":"screen","postedAt":0,"start":1,"end":1,"text":"","imagePaths":["/tmp/a.webp"]}"#,
        #"{"kind":"screen","postedAt":0,"speaker":0,"start":1,"end":1,"text":"EV3895","imagePaths":["/tmp/a.webp"]}"#,
        #"{"kind":"screen","postedAt":0,"start":1,"end":2,"text":"EV3895","imagePaths":["/tmp/a.webp"]}"#,
        #"{"kind":"screen","start":1,"end":1,"text":"EV3895","imagePaths":["/tmp/a.webp"]}"#,
        #"{"kind":"screen","postedAt":0,"start":1,"end":1,"text":"EV3895","imagePaths":["relative.webp"]}"#,
        #"{"kind":"screen","postedAt":0,"start":1,"end":1,"text":"改\n行","imagePaths":["/tmp/a.webp"]}"#,
        // イベントの行: 決まった文言だけ
        #"{"kind":"screen","postedAt":0,"start":1,"end":1,"text":"自由な文"}"#,
        #"{"kind":"screen","postedAt":0,"start":1,"end":1,"text":"記録できません: "}"#,
    ]) func 不正な画面の行を拒否する(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Utterance.self, from: Data(json.utf8)) }
    }

    @Test func 声と手入力の間へ観測位置で併合する() throws {
        let typed = try Utterance(typedText: "手入力", at: 60, postedAt: start.addingTimeInterval(101))
        let shot = try screen(at: 60, observed: 100)
        let merged = TranscriptEntries.merge(voice: [voice("前", at: 50), voice("後", at: 70)], typed: [shot, typed],
                                             timeline: timeline, unconfirmedVoiceRows: [1])
        #expect(merged.utterances.map(\.kind) == [.voice, .screen, .typed, .voice])
        #expect(merged.unconfirmedRows == [3])
    }

    @Test func 会議Markdownと会話ファイルへ画面の行を書く() throws {
        let shot = try screen(at: 0, observed: 5)
        let event = try Utterance(screenEvent: .unavailable("許可がありません"), at: 0, postedAt: start.addingTimeInterval(9))
        let markdown = MeetingMarkdown.render(.init(startedAt: start, duration: 10, utterances: [shot, event], names: .init()), timeZone: utc)
        #expect(markdown.contains("- [00:00:05] 画面: EV3895 · Keynote「提案資料」 ![画面1](<\(URL(fileURLWithPath: imagePath).absoluteString)>)"))
        #expect(markdown.contains("- [00:00:09] 画面: 記録できません: 許可がありません"))
        #expect(TranscriptRenderer.line(shot, names: .init(), timeline: timeline, timeZone: utc)
            == "[00:00:05] 画面: EV3895 · Keynote「提案資料」 画像1: `\(imagePath)`")
    }

    @Test func 話者の付け替えでも画面の行を一度だけ残す() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let shot = try screen(at: 2, observed: 2)
        let merged = TranscriptEntries.merge(voice: [voice("本文", at: 0), voice("続き", at: 3)], typed: [shot], timeline: timeline).utterances
        var archive = MeetingArchive(original: .init(startedAt: start, duration: 4, utterances: merged, names: .init()),
                                     markdownURL: dir.appendingPathComponent("meeting.md"))
        let result = MeetingResult(speakers: [1, 1], utterances: [voice("本文", at: 0, speaker: 1), voice("続き", at: 3, speaker: 1)])
        archive.replaceResult(result)
        archive.replaceResult(result)
        #expect(archive.save().utterances.map(\.kind) == [.voice, .screen, .voice])
        archive = try AIJSON.decode(MeetingArchive.self, from: AIJSON.encode(archive))
        #expect(archive.original.utterances.filter { $0.kind == .screen } == [shot])
    }

    @Test func AI文脈へ画面の行を含め声の問いには混ぜない() throws {
        let tokens = [TimedToken(text: "この図を見て", phraseId: 0, start: 0, end: 1)]
        let shot = try screen(at: 0.5, observed: 0.5)
        let late = try screen(at: 3, observed: 3)
        let capture = try AICapture(tokens: tokens, speakers: [0], finalCount: 1, processedUntil: 2, cutoff: 2,
                                    names: SpeakerNames(), timeline: timeline, typed: [shot, late])
        #expect(capture.lines.count == 2 && capture.lines[1].contains("画面: ") && capture.lines[1].contains("画像1: `"))
        #expect(capture.voice == "この図を見て")
    }

    @Test func 表示名と絞り込みの種別と音量の対象を分ける() throws {
        let shot = try screen()
        #expect(SpeakerNames().displayName(for: shot) == "画面")
        #expect(TranscriptFilter.subject(for: shot) == .screen)
        // 選ぶ一覧には出さず、話者で絞り込んでも畳まない。
        #expect(!TranscriptFilter.subjects(utterances: [shot, voice("声", at: 0)], aiNames: []).contains(.screen))
        let layout = TranscriptFilter.layout(subjects: [.speaker(0), .screen, .speaker(1)], keys: [0, 1, 2],
                                             selected: [.speaker(0)], expanded: [])
        #expect(layout == [.row(0), .row(1), .gap(rows: [2], count: 1)])
        #expect(AudioExclusion(enabled: true).excludes(shot, track: nil) == false)
        #expect(!UtterancePlayback.isPlayable(shot))
    }
}

private extension ScreenChangeDetector {
    /// 保存を受け付けて成功を返す。受付の番号を省くと、自動だけの検証としてフレームの番号と同じ値を振る。
    /// 番号は呼び出し側が振る受付の番号で、判定器はフレームの番号と比べない。
    mutating func succeed(_ frame: Int, order: Int? = nil) {
        accepted(frame: frame, order: order ?? frame)
        saveSucceeded(frame: frame)
    }
}

@Suite struct ScreenChangeDetectorTests {
    private func thumbnail(_ fill: UInt8, patch: (Int, UInt8)? = nil) -> ScreenThumbnail {
        var luma = [UInt8](repeating: fill, count: 100)
        if let (count, value) = patch { for cell in 0..<count { luma[cell * 7 % 100] = value } }
        return ScreenThumbnail(width: 10, height: 10, luma: luma)
    }
    /// 比較の基準と受付の番号の契約だけを見るので、動き続ける画面と直近の画面の規則は切る。
    /// 2つの規則を入れた振る舞いは `ScreenChangeMotionTests` で確かめる。
    private var parameters: ScreenChangeParameters {
        var value = ScreenChangeParameters()
        value.motion = 0.02; value.save = 0.05; value.cellDelta = 10
        value.movingSeconds = 0; value.recentSeconds = 0
        return value
    }

    @Test func 既定値は検証記録の初期値() {
        let value = ScreenChangeParameters()
        #expect(value.thumbnailWidth == 128 && value.cellDelta == 8 && value.motion == 0.0002 && value.save == 0.001 && value.settle == 1.5)
        #expect(value.movingSeconds == 12 && value.excludeWindow == 10 && value.excludeGrow == 1 && value.excludeRelease == 3)
        #expect(value.recentSeconds == 12 && value.recentExcludeLimit == 0.5)
    }

    @Test func 最初は待たずに保存し落ち着いたページ送りを観測したフレームで保存する() {
        var detector = ScreenChangeDetector(parameters: parameters)
        #expect(detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200)) == .init(frame: 0, reason: .first))
        #expect(detector.observe(frame: 1, at: 10, thumbnail: thumbnail(50)) == nil)
        #expect(detector.tick(at: 11.25) == nil)
        #expect(detector.tick(at: 11.5) == .init(frame: 1, reason: .settled))
        #expect(detector.tick(at: 20) == nil)
    }

    @Test func 時計のような小さな変化では保存せず積もった変化は一度だけ拾う() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        for second in 1...10 {
            #expect(detector.observe(frame: second, at: Double(second), thumbnail: thumbnail(200, patch: (1, UInt8(second * 20)))) == nil)
        }
        detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        var saves = 0
        for step in 1...8 where detector.observe(frame: step, at: Double(step) * 2, thumbnail: thumbnail(200, patch: (step, 0))) != nil { saves += 1 }
        #expect(saves == 1)
    }

    @Test func メニューバーの高さを比較から外す() {
        var value = parameters
        value.excludedTopFraction = 0.1
        var detector = ScreenChangeDetector(parameters: value)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        var top = [UInt8](repeating: 200, count: 100)
        for cell in 0..<10 { top[cell] = 0 }
        _ = detector.observe(frame: 1, at: 1, thumbnail: ScreenThumbnail(width: 10, height: 10, luma: top))
        #expect(detector.tick(at: 5) == nil)
    }

    @Test func 保存に失敗したら間隔をおいて同じ画面をもう一度保存する() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        detector.succeed(0)
        _ = detector.observe(frame: 1, at: 1, thumbnail: thumbnail(50))
        #expect(detector.tick(at: 2.5)?.frame == 1)
        #expect(detector.tick(at: 3) == nil)
        detector.saveFailed(frame: 1, at: 3)
        #expect(detector.tick(at: 7.75) == nil)
        #expect(detector.tick(at: 8) == .init(frame: 1, reason: .settled))
    }

    @Test func 最初の保存に失敗しても新しいフレームなしで撮り直す() {
        var detector = ScreenChangeDetector(parameters: parameters)
        #expect(detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))?.reason == .first)
        detector.saveFailed(frame: 0, at: 0.5)
        #expect(detector.tick(at: 1) == nil)
        #expect(detector.tick(at: 5.5) == .init(frame: 0, reason: .first))
    }

    @Test func 保存中の結果がどの順で返っても未保存の画像を基準に残さない() {
        // 保存済みS(200)の後に、A(50)・B(120)を続けて決め、両方の結果を待つ。
        func pending() -> ScreenChangeDetector {
            var detector = ScreenChangeDetector(parameters: parameters)
            _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
            detector.succeed(0)
            _ = detector.observe(frame: 1, at: 1, thumbnail: thumbnail(50))
            #expect(detector.tick(at: 2.5)?.frame == 1)
            _ = detector.observe(frame: 2, at: 3, thumbnail: thumbnail(120))
            #expect(detector.tick(at: 4.5)?.frame == 2)
            return detector
        }
        // Aが失敗、Bが失敗: 基準はSへ戻り、画面がAへ戻って静止すれば保存する。
        var detector = pending()
        detector.saveFailed(frame: 1, at: 5)
        detector.saveFailed(frame: 2, at: 5)
        _ = detector.observe(frame: 3, at: 6, thumbnail: thumbnail(50))
        #expect(detector.tick(at: 10) == .init(frame: 3, reason: .settled))
        // Bが先に失敗し、Aが後で成功: 基準はA。画面がAのままなら保存しない。
        detector = pending()
        detector.saveFailed(frame: 2, at: 5)
        detector.succeed(1)
        _ = detector.observe(frame: 3, at: 6, thumbnail: thumbnail(50))
        #expect(detector.tick(at: 10) == nil)
        // Bが先に成功し、Aが後で失敗: Aの結果を待つ間もBを撮り直さず、基準はBのまま。
        detector = pending()
        detector.succeed(2)
        #expect(detector.tick(at: 5) == nil)
        #expect(detector.tick(at: 9) == nil)
        detector.saveFailed(frame: 1, at: 5)
        _ = detector.observe(frame: 3, at: 6, thumbnail: thumbnail(120))
        #expect(detector.tick(at: 10) == nil)
    }

    @Test func 撮れない期間の後は古いフレームを保存せず次を最初の1枚にする() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        _ = detector.observe(frame: 1, at: 1, thumbnail: thumbnail(50))
        detector.reset()
        #expect(detector.tick(at: 10) == nil)
        // reset の前に決めた保存の結果は無視する。
        detector.succeed(0)
        #expect(detector.observe(frame: 2, at: 11, thumbnail: thumbnail(50))?.reason == .first)
    }

    @Test func 一時停止をまたいで比較の基準を引き継ぎ_同じ画面を続けて保存しない() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        detector.succeed(0)
        // 再開の直後が一時停止の前と同じ画面なら保存しない。
        detector.restart()
        #expect(detector.observe(frame: 1, at: 30, thumbnail: thumbnail(200)) == nil)
        #expect(detector.tick(at: 40) == nil)
        // 違えば落ち着きを待たずに保存する。動きは再開の後から数え直す。
        detector.restart()
        #expect(detector.observe(frame: 2, at: 60, thumbnail: thumbnail(50)) == .init(frame: 2, reason: .settled))
        // 一時停止の前に決めた保存の結果は、再開の後に返っても基準に入る。
        detector.restart()
        detector.succeed(2)
        #expect(detector.observe(frame: 3, at: 90, thumbnail: thumbnail(50)) == nil)
        // 基準を持たないまま再開したら、最初の1枚として撮る。
        var fresh = ScreenChangeDetector(parameters: parameters)
        fresh.restart()
        #expect(fresh.observe(frame: 0, at: 0, thumbnail: thumbnail(200))?.reason == .first)
    }

    @Test func いま撮るの画像を基準に採った後_押す前の観測を何度も保存しない() {
        var detector = ScreenChangeDetector(parameters: parameters)
        #expect(detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))?.frame == 0)
        detector.succeed(0, order: 0)
        // 手動の画像の受付は1。新しい観測を挟まずに、時間と保存の結果だけを進める。
        detector.adopt(order: 1, thumbnail: thumbnail(50))
        for second in 1...5 {
            #expect(detector.tick(at: Double(second) * 10) == nil)
            detector.succeed(0, order: 0)
        }
        // 新しい観測は、手動の画像と比べる。
        #expect(detector.observe(frame: 1, at: 60, thumbnail: thumbnail(50)) == nil)
        #expect(detector.tick(at: 65) == nil)
        #expect(detector.observe(frame: 2, at: 70, thumbnail: thumbnail(200)) == nil)
        #expect(detector.tick(at: 72) == .init(frame: 2, reason: .settled))
    }

    @Test func 保存しなかった再観測は_いま撮るの後に保存して基準を古い画面へ戻さない() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200), acceptedBefore: 0)
        detector.succeed(0, order: 0)
        // 同じ画面Aを新しく観測した。基準と同じなので保存しない。観測までに受け付けた保存は1件。
        #expect(detector.observe(frame: 1, at: 10, thumbnail: thumbnail(200), acceptedBefore: 1) == nil)
        // 手動の画像Bを受付1で撮った。押す前の観測Aは、以後の判定で使わない。
        detector.adopt(order: 1, thumbnail: thumbnail(50))
        for second in 1...5 { #expect(detector.tick(at: 10 + Double(second) * 10) == nil) }
        // 新しい観測は手動の画像と比べる。Aのままの画面を観測したら撮る。
        #expect(detector.observe(frame: 2, at: 70, thumbnail: thumbnail(200), acceptedBefore: 2) == .init(frame: 2, reason: .settled))
    }

    @Test func いま撮るより後の観測は_手動の画像を基準に採っても残す() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200), acceptedBefore: 0)
        detector.succeed(0, order: 0)
        // 手動を受付1で押した後に、別の画面Cを観測した。観測までに受け付けた保存は2件。落ち着く前に手動の画像が完成した。
        #expect(detector.observe(frame: 1, at: 10, thumbnail: thumbnail(120), acceptedBefore: 2) == nil)
        detector.adopt(order: 1, thumbnail: thumbnail(50))
        // Cは手動の撮影より後の観測なので、落ち着いたら手動の画像と比べて撮る。
        #expect(detector.tick(at: 12) == .init(frame: 1, reason: .settled))
    }

    @Test func 保存中の自動の画像より後に受け付けたいま撮るを基準にし_捨てた自動の画像へ戻れば撮る() {
        // 自動の画像Aを受付0で保存中に、手動の画像Bを受付1で押した。Aの成功が先に返っても、基準はB。
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        detector.accepted(frame: 0, order: 0)
        detector.saveSucceeded(frame: 0)
        detector.adopt(order: 1, thumbnail: thumbnail(50))
        for second in 1...5 { #expect(detector.tick(at: Double(second) * 10) == nil) }
        // Aのままの画面を新しく観測したら、Bと違うので撮る。動きは無いので待たない。
        #expect(detector.observe(frame: 1, at: 60, thumbnail: thumbnail(200)) == .init(frame: 1, reason: .settled))
        // 手動の画像より後に受け付けた自動の画像の成功が後から返ったら、そちらが新しい基準になる。
        var later = ScreenChangeDetector(parameters: parameters)
        _ = later.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        later.succeed(0, order: 0)
        _ = later.observe(frame: 1, at: 1, thumbnail: thumbnail(120))
        #expect(later.tick(at: 2.5)?.frame == 1)
        later.accepted(frame: 1, order: 2)
        later.adopt(order: 1, thumbnail: thumbnail(50))
        later.saveSucceeded(frame: 1)
        #expect(later.observe(frame: 2, at: 10, thumbnail: thumbnail(120)) == nil)
        #expect(later.tick(at: 20) == nil)
    }

    @Test(arguments: [false, true])
    func 同じ間に押したいま撮るは受付の新しい方を基準にし_遅い完了で上書きしない(reversed: Bool) {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        detector.succeed(0, order: 0)
        // 新しい観測を挟まずに、B(受付1)とC(受付2)を続けて押した。完了は順方向か逆方向。
        let completions: [(Int, UInt8)] = [(1, 50), (2, 120)]
        for (order, fill) in reversed ? completions.reversed() : completions { detector.adopt(order: order, thumbnail: thumbnail(fill)) }
        // 基準はC。Cのままなら撮らず、Bへ戻れば撮る。
        #expect(detector.observe(frame: 1, at: 10, thumbnail: thumbnail(120)) == nil)
        #expect(detector.tick(at: 20) == nil)
        #expect(detector.observe(frame: 2, at: 30, thumbnail: thumbnail(50)) == nil)
        #expect(detector.tick(at: 32) == .init(frame: 2, reason: .settled))
    }

    @Test func 引き継いだ基準と寸法が違えば最初の1枚から数え直す() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        detector.succeed(0)
        detector.restart()
        let wide = ScreenThumbnail(width: 20, height: 5, luma: [UInt8](repeating: 200, count: 100))
        #expect(detector.observe(frame: 1, at: 1, thumbnail: wide) == .init(frame: 1, reason: .first))
    }

    @Test func 縮小画像の寸法が変わったら最初の1枚から数え直す() {
        var detector = ScreenChangeDetector(parameters: parameters)
        _ = detector.observe(frame: 0, at: 0, thumbnail: thumbnail(200))
        detector.succeed(0)
        let wide = ScreenThumbnail(width: 20, height: 5, luma: [UInt8](repeating: 200, count: 100))
        #expect(detector.observe(frame: 1, at: 1, thumbnail: wide) == .init(frame: 1, reason: .first))
    }

    @Test func 輝度をマスごとの平均で縮める() {
        let source: [UInt8] = [0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let result = ScreenThumbnail.average(width: 4, height: 4, to: 2) { source[$1 * 4 + $0] }
        #expect(result.luma == [0, 255, 0, 255])
    }
}
