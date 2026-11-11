import CoreGraphics
import Foundation
import ImageIO

/// 本体が保存した画面の記録(`<会議名>.captures/`)を観測の記録へ写す。2026-11-11の「交互に変わる画面」の試作で使う。
/// 保存した画像を保存の順に1枚ずつ観測として並べ、次の画像までは同じ画面が続いたとみなす。
/// - 時刻: ファイル名の HHmmss。同じ秒の `_2` 以降は0.5秒ずつ後ろへずらす
/// - 限界: 保存しなかった観測は残っていないので、落ち着きの判定は当て直せない。比べられるのは「保存した画像どうしが同じか」だけ
enum ImportCapturesCommand {
    static func main(_ args: inout Arguments) throws {
        let out = URL(fileURLWithPath: try args.required("--out"))
        guard let input = args.rest.first else { throw ProbeError.message("<会議名>.captures のディレクトリを渡す") }
        let files = try captures(in: URL(fileURLWithPath: input))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let writer = try RecordWriter(url: out.appendingPathComponent("frames.jsonl"))
        var names: [String] = []
        for (index, file) in files.enumerated() {
            writer.frame(index: index, time: file.time, thumb: try thumbnail(file.url))
            names.append(file.url.lastPathComponent)
        }
        writer.write(RecordLine(kind: "end", t: (files.last?.time ?? 0) + 10))
        writer.close()
        try names.joined(separator: "\n").write(to: out.appendingPathComponent("names.txt"), atomically: true, encoding: .utf8)
        print("\(out.path): 観測 \(files.count) 枚")
    }

    /// 同じ秒の連番は数で並べる。文字列で並べると `_10` が `_2` より先になる。
    /// 日付をまたぐ記録は扱わない。名前の順と書き込みの時刻の順が食い違ったら止める。
    static func captures(in directory: URL) throws -> [(url: URL, time: Double)] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "webp" }
        let parsed: [(url: URL, seconds: Int, serial: Int, written: Date)] = try urls.map { url in
            let stem = url.deletingPathExtension().lastPathComponent
            let parts = stem.split(separator: "_")
            guard let clock = parts.first, clock.count == 6, let hhmmss = Int(clock) else { throw ProbeError.message("HHmmssの名前でない: \(stem)") }
            let serial = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            let written = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return (url, hhmmss / 10000 * 3600 + hhmmss / 100 % 100 * 60 + hhmmss % 100, serial, written)
        }.sorted { ($0.seconds, $0.serial) < ($1.seconds, $1.serial) }
        if let start = parsed.first?.written, let end = parsed.last?.written, end.timeIntervalSince(start) < 0 || end.timeIntervalSince(start) > 86_400 / 2 {
            throw ProbeError.message("日付をまたぐ記録は扱わない: 名前の順と書き込みの時刻の順が合わない")
        }
        for (earlier, later) in zip(parsed, parsed.dropFirst()) where later.written < earlier.written.addingTimeInterval(-2) {
            throw ProbeError.message("日付をまたぐ記録は扱わない: \(later.url.lastPathComponent) が \(earlier.url.lastPathComponent) より先に書かれている")
        }
        // 同じ秒の中の順序は、その秒の中で等間隔に並べる。秒の時刻を越えない。
        // 理由: 連番ごとに一定の秒数を足すと、`_4` が翌秒の画像より後になる。
        let start = parsed.first?.seconds ?? 0
        return parsed.map { item in
            let sameSecond = parsed.filter { $0.seconds == item.seconds }.map(\.serial).sorted()
            let rank = sameSecond.firstIndex(of: item.serial) ?? 0
            return (item.url, Double(item.seconds - start) + Double(rank) / Double(sameSecond.count))
        }
    }

    static func thumbnail(_ url: URL) throws -> Thumb {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let thumb = Thumbnail.make(image, width: Thumbnail.recordWidth) else { throw ProbeError.message("読めない: \(url.path)") }
        return thumb
    }
}

/// 保存済みの画像どうしの差を出す。圧縮の差で「同じ画面」を外さないかを見る。
/// 各画像について、それより前の画像のうち最も近いものとの、変わったマスの割合を出す。
enum PairDiffCommand {
    static func main(_ args: inout Arguments) throws {
        let width = args.int("--width") ?? 128
        let cell = args.int("--cell") ?? 8
        let top = args.double("--top") ?? 0
        guard let input = args.rest.first else { throw ProbeError.message("<会議名>.captures のディレクトリを渡す") }
        let files = try ImportCapturesCommand.captures(in: URL(fileURLWithPath: input))
        let thumbs = try files.map { Thumbnail.resized(try ImportCapturesCommand.thumbnail($0.url), width: width) }
        func fraction(_ a: Thumb, _ b: Thumb) -> Double {
            let rows = min(a.height, Int((top * Double(a.height)).rounded(.up)))
            let range = (rows * a.width)..<(a.width * a.height)
            let changed = range.filter { abs(Int(a.luma[$0]) - Int(b.luma[$0])) > cell }.count
            return Double(changed) / Double(range.count)
        }
        for (index, file) in files.enumerated() {
            let name = file.url.lastPathComponent
            guard index > 0 else { print("\(name) t=0"); continue }
            let diffs = (0..<index).map { (other: $0, diff: fraction(thumbs[$0], thumbs[index])) }
            let nearest = diffs.min { $0.diff < $1.diff }!
            print(String(format: "%@ t=%.0f 直前との差%.4f 最も近い%@ 差%.4f", name, file.time, diffs.last!.diff,
                         files[nearest.other].url.lastPathComponent, nearest.diff))
        }
    }
}
