import Foundation

/// 観測の記録。実画面の `watch` と合成の `synth` が同じ形で書き、`sweep` が読む。
/// 1行1件のJSON。`frame` は縮小画像を持ち、しきい値を変えた判定を後から何度でも当て直せる。
struct RecordLine: Codable {
    var kind: String          // frame / idle / end
    var t: Double             // 記録開始からの秒。frameはdisplayTimeから求めた観測時刻
    var i: Int?
    var w: Int?
    var h: Int?
    var luma: String?         // base64
    var dirty: Double?        // dirtyRectsの面積の割合。watchだけ

    var thumb: Thumb? {
        guard let w, let h, let luma, let data = Data(base64Encoded: luma) else { return nil }
        return Thumb(width: w, height: h, luma: [UInt8](data))
    }
}

/// 合成の正解。その区間に観測時刻を持つ保存の枚数が min〜max なら合格。
struct TruthWindow: Codable {
    var from: Double
    var to: Double
    var min: Int
    var max: Int
    var label: String
    /// 数え方(2026-11-11に足した)。nil は min〜max で合否を見る。
    /// - transit: 送り・切替・スクロールの途中。保存の数を「途中」として別に数え、取りこぼしにも余分にも数えない
    /// - return: 戻った画面。拾ったかを別に数え、取りこぼしにも余分にも数えない
    /// - page: 交互・巡回の1回の表示。group と page で、ページごとに初回の取りこぼしと再保存を数える
    var kind: String? = nil
    var group: String? = nil
    var page: Int? = nil
    /// 区間の始まりから最初の保存を決めるまでの秒数を数える。
    var latency: Bool? = nil

    init(from: Double, to: Double, min: Int, max: Int, label: String, kind: String? = nil, group: String? = nil, page: Int? = nil, latency: Bool? = nil) {
        self.from = from; self.to = to; self.min = min; self.max = max; self.label = label
        self.kind = kind; self.group = group; self.page = page; self.latency = latency
    }
}

final class RecordWriter {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ProbeError.message("作れません: \(url.path)") }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: RecordLine) {
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        handle.write(data)
    }

    func frame(index: Int, time: Double, thumb: Thumb, dirty: Double? = nil) {
        write(RecordLine(kind: "frame", t: time, i: index, w: thumb.width, h: thumb.height, luma: Data(thumb.luma).base64EncodedString(), dirty: dirty))
    }

    func close() { try? handle.close() }
}

enum Recording {
    static func load(_ url: URL) throws -> [RecordLine] {
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try decoder.decode(RecordLine.self, from: Data($0.utf8)) }
    }

    static func loadTruth(_ url: URL) throws -> [TruthWindow]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([TruthWindow].self, from: Data(contentsOf: url))
    }
}

enum ProbeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
