import Foundation

// 出力JSONの突き合わせ。10ms格子で話者番号の置換を最適化して比べる。
// 参照RTTMが無い比較は片方を基準にした「不一致率」であり、正解に対するDERではない。

private let frame = 0.01

private struct DiarFile: Decodable {
    let engine: String
    let variant: String
    let fluidAudio: String
    let wav: String
    let start: Double
    let audioSeconds: Double
    let segments: [Segment]
    var label: String { "\(engine)/\(variant)@\(fluidAudio)" }
}

private struct AsrFile: Decodable {
    let engine: String
    let variant: String
    let wav: String
    let start: Double
    let audioSeconds: Double
    let text: String
    let tokens: [TimedToken]
    var label: String { "\(engine) \(variant)" }
}

private struct Source { let wav: String; let start: Double; let audioSeconds: Double; let label: String }

private func decode<T: Decodable>(_ path: String) -> T {
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
    catch { fail("\(path) を読めない: \(error)") }
}

/// 別の音源・別の区間を黙って比べない
private func requireSameSource(_ items: [Source]) {
    guard let first = items.first else { return }
    for s in items.dropFirst() {
        guard s.wav == first.wav, abs(s.start - first.start) < 1e-6, abs(s.audioSeconds - first.audioSeconds) < 1e-3 else {
            fail("入力の音源・区間が一致しない: \(first.label) [\(first.wav) start=\(first.start) len=\(first.audioSeconds)] と \(s.label) [\(s.wav) start=\(s.start) len=\(s.audioSeconds)]")
        }
    }
}

private typealias Tracks = [String: [Bool]]

private func frames(_ segments: [(speaker: String, start: Double, end: Double)], count n: Int) -> Tracks {
    var tracks: Tracks = [:]
    for s in segments {
        let a = max(0, Int((s.start / frame).rounded())), b = min(n, Int((s.end / frame).rounded()))
        guard a < b else { continue }
        var t = tracks[s.speaker] ?? [Bool](repeating: false, count: n)
        for i in a..<b { t[i] = true }
        tracks[s.speaker] = t
    }
    return tracks
}

private func frames(_ file: DiarFile, count n: Int) -> Tracks {
    frames(file.segments.map { (String($0.speaker), $0.start, $0.end) }, count: n)
}

/// 仮説話者→参照話者の単射で重なりフレーム数を最大化する。8×8 でも総当たりで足りる
private func bestMapping(ref: Tracks, hyp: Tracks) -> [String: String] {
    let rk = ref.keys.sorted(), hk = hyp.keys.sorted()
    var overlap: [String: [String: Int]] = [:]
    for h in hk {
        for r in rk { overlap[h, default: [:]][r] = zip(hyp[h]!, ref[r]!).reduce(0) { $0 + ($1.0 && $1.1 ? 1 : 0) } }
    }
    var best = -1, bestMap: [String: String] = [:]
    func search(_ i: Int, _ used: Set<String>, _ score: Int, _ map: [String: String]) {
        if i == hk.count {
            if score > best { best = score; bestMap = map }
            return
        }
        // 重なりは非負なので、対応を増やして損はしない。参照側の枠が足りないときだけ対応しない仮説話者を許す
        if hk.count - i > rk.count - used.count {
            search(i + 1, used, score, map)
        }
        for r in rk where !used.contains(r) {
            var m = map
            m[hk[i]] = r
            search(i + 1, used.union([r]), score + overlap[hk[i]]![r]!, m)
        }
    }
    search(0, [], 0, [:])
    return bestMap
}

private func turns(_ tracks: Tracks, count n: Int) -> Int {
    var last: String?, count = 0
    for i in 0..<n {
        let active = tracks.filter { $0.value[i] }.map(\.key)
        if active.count == 1, active[0] != last { count += 1; last = active[0] }
    }
    return max(0, count - 1)
}

private func speakers(_ tracks: Tracks, minSeconds: Double = 1) -> Int {
    tracks.values.filter { Double($0.filter { $0 }.count) * frame >= minSeconds }.count
}

private func readRTTM(_ path: String, id: String?, offset: Double, duration: Double) -> (segments: [(speaker: String, start: Double, end: Double)], id: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("RTTMを読めない: \(path)") }
    // 空白・タブのどちらの区切りも受ける。列不足・非有限・負の時刻は黙って捨てずに止める
    let rows = text.split(whereSeparator: \.isNewline)
        .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }) }
        .filter { $0.first == "SPEAKER" }
    for (k, p) in rows.enumerated() {
        guard p.count >= 8 else { fail("RTTMの \(k + 1) 件目のSPEAKER行の列が足りない(\(p.count)列)") }
        guard let s = Double(p[3]), let d = Double(p[4]), s.isFinite, d.isFinite, s >= 0, d >= 0 else {
            fail("RTTMの \(k + 1) 件目のSPEAKER行の時刻が不正: start=\(p[3]) duration=\(p[4])")
        }
    }
    let ids = Set(rows.map { String($0[1]) })
    let chosen: String
    if let id {
        guard ids.contains(id) else { fail("RTTMに recording ID \(id) が無い: \(ids.sorted())") }
        chosen = id
    } else {
        guard ids.count == 1, let only = ids.first else { fail("RTTMに複数の recording ID がある。--ref-id で選ぶ: \(ids.sorted())") }
        chosen = only
    }
    var segments: [(speaker: String, start: Double, end: Double)] = []
    for p in rows where String(p[1]) == chosen {
        let s = Double(p[3])!, e = s + Double(p[4])!
        guard e > offset, s < offset + duration else { continue }
        segments.append((String(p[7]), max(s, offset) - offset, min(e, offset + duration) - offset))
    }
    return (segments, chosen)
}

private func printJSON(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

/// compare diar <A.json> <B.json> [--ref-rttm file [--ref-id id] [--ref-offset s]]
func compareDiar(_ paths: [String], _ options: Options) {
    guard paths.count == 2 else { fail("compare diar <A.json> <B.json>") }
    let a: DiarFile = decode(paths[0]), b: DiarFile = decode(paths[1])
    requireSameSource([a, b].map { Source(wav: $0.wav, start: $0.start, audioSeconds: $0.audioSeconds, label: $0.label) })
    let duration = a.audioSeconds
    let n = Int((duration / frame).rounded(.up))
    var out: [String: Any] = ["wav": a.wav, "start": a.start, "audioSeconds": duration]
    let ref: Tracks
    let hyps: [(String, DiarFile)]
    if let rttm = options.string("ref-rttm") {
        // 既定の参照offsetは結果の start。区間の取り違えを避けるため明示値も結果へ残す
        let offset = options.double("ref-offset", a.start)
        let r = readRTTM(rttm, id: options.string("ref-id"), offset: offset, duration: duration)
        ref = frames(r.segments, count: n)
        hyps = [("A", a), ("B", b)]
        out["reference"] = [
            "kind": "参照RTTM", "path": rttm, "recordingId": r.id, "offset": offset,
            "scoring": "collar=0、重なり発話を含む、10ms量子化、UEMなし(区間全体を採点)。md-eval/dscore 等の公式採点器ではない自前集計",
        ] as [String: Any]
    } else {
        ref = frames(a, count: n)
        hyps = [("B", b)]
        out["reference"] = ["kind": "A(正解ではない)。数値は A に対する不一致率", "label": a.label] as [String: Any]
    }
    out["referenceSpeakers(>=1s)"] = speakers(ref)
    out["referenceTurns"] = turns(ref, count: n)
    for (name, h) in hyps {
        let hyp = frames(h, count: n)
        let m = bestMapping(ref: ref, hyp: hyp)
        var miss = 0, fa = 0, conf = 0, total = 0, singleBoth = 0, singleAgree = 0
        for i in 0..<n {
            let r = Set(ref.filter { $0.value[i] }.map(\.key))
            let hy = hyp.filter { $0.value[i] }.map(\.key)
            let mapped = Set(hy.compactMap { m[$0] })
            total += r.count
            miss += max(0, r.count - hy.count)
            fa += max(0, hy.count - r.count)
            conf += min(r.count, hy.count) - mapped.intersection(r).count
            if r.count == 1, hy.count == 1 {
                singleBoth += 1
                if mapped == r { singleAgree += 1 }
            }
        }
        // 参照側に発話が無ければ率は定義できない。分母を1へ置き換えて数字を作らない
        func rate(_ v: Int) -> Any { total > 0 ? round4(Double(v) / Double(total)) : NSNull() }
        out[name] = [
            "label": h.label,
            "speakers(>=1s)": speakers(hyp),
            "speechSecondsBySpeaker": hyp.mapValues { round4(Double($0.filter { $0 }.count) * frame) },
            "mapping": m,
            "turns": turns(hyp, count: n),
            "referenceSpeechFrames": total,
            "missRate": rate(miss),
            "falseAlarmRate": rate(fa),
            "confusionRate": rate(conf),
            "errorRate(miss+fa+conf)": rate(miss + fa + conf),
            "singleSpeakerAgreement": singleBoth > 0 ? round4(Double(singleAgree) / Double(singleBoth)) : NSNull(),
            "singleSpeakerFramesCompared": singleBoth,
        ] as [String: Any]
    }
    printJSON(out)
}

private func normalized(_ text: String) -> [Character] {
    text.precomposedStringWithCompatibilityMapping.filter { c in
        !c.isWhitespace && !c.isPunctuation && !c.isSymbol
    }.map { $0 }
}

private func editDistance(_ x: [Character], _ y: [Character]) -> Int {
    var prev = Array(0...y.count)
    for (i, cx) in x.enumerated() {
        var cur = [i + 1] + [Int](repeating: 0, count: y.count)
        for (j, cy) in y.enumerated() {
            cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (cx == cy ? 0 : 1))
        }
        prev = cur
    }
    return prev[y.count]
}

/// compare asr <A.json> <B.json>
func compareAsr(_ paths: [String]) {
    guard paths.count == 2 else { fail("compare asr <A.json> <B.json>") }
    let a: AsrFile = decode(paths[0]), b: AsrFile = decode(paths[1])
    requireSameSource([a, b].map { Source(wav: $0.wav, start: $0.start, audioSeconds: $0.audioSeconds, label: $0.label) })
    let x = normalized(a.text), y = normalized(b.text)
    let d = editDistance(x, y)
    printJSON([
        "wav": a.wav, "start": a.start, "audioSeconds": a.audioSeconds,
        "A": a.label, "B": b.label, "charsA": x.count, "charsB": y.count, "editDistance": d,
        "diffRateVsA": round4(Double(d) / Double(max(1, x.count))),
        "note": "空白・句読点・記号を除きNFKC正規化した文字の編集距離。A は正解ではなく、CERではない",
    ])
}

/// compare attrib <ASR.json> <DIAR_A.json> <DIAR_B.json>
func compareAttrib(_ paths: [String]) {
    guard paths.count == 3 else { fail("compare attrib <ASR.json> <DIAR_A.json> <DIAR_B.json>") }
    let tr: AsrFile = decode(paths[0]), a: DiarFile = decode(paths[1]), b: DiarFile = decode(paths[2])
    requireSameSource([
        Source(wav: tr.wav, start: tr.start, audioSeconds: tr.audioSeconds, label: tr.label),
        Source(wav: a.wav, start: a.start, audioSeconds: a.audioSeconds, label: a.label),
        Source(wav: b.wav, start: b.start, audioSeconds: b.audioSeconds, label: b.label),
    ])
    let n = Int((a.audioSeconds / frame).rounded(.up)) + 1
    let ta = frames(a, count: n), tb = frames(b, count: n)
    let m = bestMapping(ref: ta, hyp: tb)
    func speaker(_ tracks: Tracks, _ start: Double, _ end: Double) -> String? {
        let lo = min(n - 1, max(0, Int(start / frame)))
        let hi = min(n, max(lo + 1, Int((end / frame).rounded(.up))))
        var best: String?, bestCount = 0
        for (k, t) in tracks.sorted(by: { $0.key < $1.key }) {
            let c = t[lo..<hi].filter { $0 }.count
            if c > bestCount { best = k; bestCount = c }
        }
        return best
    }
    var chars = 0, agree = 0, unknownA = 0, unknownB = 0
    for tok in tr.tokens {
        let c = normalized(tok.text).count
        guard c > 0 else { continue }
        let sa = speaker(ta, tok.start, tok.end), sb = speaker(tb, tok.start, tok.end)
        chars += c
        if sa == nil { unknownA += c }
        if sb == nil { unknownB += c }
        if let sa, let sb, m[sb] == sa { agree += c }
    }
    printJSON([
        "tokens": tr.label, "A": a.label, "B": b.label, "chars": chars,
        "charAgreement": chars > 0 ? round4(Double(agree) / Double(chars)) : NSNull(),
        "unknownCharsA": unknownA, "unknownCharsB": unknownB,
        "note": "トークン区間で最も長く重なる話者を採る単純な割り当て。アプリの Aligner(フレーズ多数決・島の処理)ではない",
    ])
}
