#if DEBUG
import Foundation
import KikigakiCore

/// `--align-compare <dumpDir>`: 書き出した入力へ本番の判定とフレーズ固定を当て、Markdown・JSON・全文を書く。
/// UIもモデルも起動しない。別のビルドとの比較は全文の `diff` で行う。使い方は docs/speaker-correction-trial.md
enum SpeakerTrialCompare {
    static let usage = """
        usage: Kikigaki --align-compare <dumpDir> [--out <dir>] [--source <名前>]
               [--expect <開始秒>-<終了秒>=<枠>]... [--names 0=司会,1=堀田] [--no-live]
        """

    static func run(arguments: [String]) -> Int32 {
        guard let dump = arguments.first, !dump.hasPrefix("--") else { return fail(usage) }
        var out = URL(fileURLWithPath: dump).appendingPathComponent("compare")
        var source = URL(fileURLWithPath: dump).lastPathComponent
        var expectations: [SpeakerTrial.Expectation] = []
        var names: [Int: String] = [:]
        var live = true
        var index = 1
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--out": guard let v = value() else { return fail(usage) }; out = URL(fileURLWithPath: v)
            case "--source": guard let v = value() else { return fail(usage) }; source = v
            case "--expect":
                guard let v = value(), let expectation = SpeakerTrial.Expectation(argument: v) else { return fail(usage) }
                expectations.append(expectation)
            case "--names":
                guard let v = value() else { return fail(usage) }
                for pair in v.split(separator: ",") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, let slot = Int(parts[0]) else { return fail(usage) }
                    names[slot] = String(parts[1])
                }
            case "--no-live": live = false
            default: return fail(usage)
            }
            index += 1
        }

        let directory = URL(fileURLWithPath: dump)
        do {
            let final = try JSONDecoder().decode(SpeakerTrial.FinalRecord.self,
                                                 from: Data(contentsOf: directory.appendingPathComponent("final.json")))
            let meta = try? JSONDecoder().decode(SpeakerTrial.Meta.self,
                                                 from: Data(contentsOf: directory.appendingPathComponent("meta.json")))
            var snapshots: [SpeakerTrial.Snapshot] = []
            let liveURL = directory.appendingPathComponent("live.jsonl")
            if live, FileManager.default.fileExists(atPath: liveURL.path) {
                let decoder = JSONDecoder()
                let records = try String(contentsOf: liveURL, encoding: .utf8).split(separator: "\n").map {
                    try decoder.decode(SpeakerTrial.LiveRecord.self, from: Data($0.utf8))
                }
                // 確定済み接頭辞が変わった記録は比較を無効にする
                snapshots = try SpeakerTrial.snapshots(from: records, final: final)
            }
            let (comparison, speakers) = SpeakerTrial.compare(source: source, final: final, snapshots: snapshots,
                                                              expectations: expectations, recorded: meta)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(comparison).write(to: out.appendingPathComponent("comparison.json"), options: .atomic)
            try SpeakerTrial.markdown(comparison, names: names, meta: meta)
                .write(to: out.appendingPathComponent("comparison.md"), atomically: true, encoding: .utf8)
            try SpeakerTrial.transcript(tokens: final.tokens, speakers: speakers, names: names)
                .write(to: out.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            print("Kikigaki (align-compare): \(out.path)/comparison.md")
            return 0
        } catch {
            return fail("比較できない: \(error)")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Kikigaki: \(message)\n".utf8))
        return 2
    }
}
#endif
