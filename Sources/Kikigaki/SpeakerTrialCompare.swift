#if DEBUG
import Foundation
import KikigakiCore

/// `--align-compare <dumpDir>`: 書き出した入力へ全条件を当て、比較Markdown・JSON・全文を書く。
/// UIもモデルも起動しない。使い方は docs/speaker-correction-trial.md
enum SpeakerTrialCompare {
    static let usage = """
        usage: Kikigaki --align-compare <dumpDir> [--out <dir>] [--source <名前>]
               [--expect <開始秒>-<終了秒>=<枠>]... [--names 0=司会,1=堀田]
               [--presets a,b] [--live-presets a,b] [--no-live]
        """

    static func run(arguments: [String]) -> Int32 {
        guard let dump = arguments.first, !dump.hasPrefix("--") else { return fail(usage) }
        var out = URL(fileURLWithPath: dump).appendingPathComponent("compare")
        var source = URL(fileURLWithPath: dump).lastPathComponent
        var expectations: [SpeakerTrial.Expectation] = []
        var names: [Int: String] = [:]
        var presets = Aligner.Options.presetNames
        var livePresets = ["current", "window", "point"]
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
            case "--presets": guard let v = value() else { return fail(usage) }; presets = v.split(separator: ",").map(String.init)
            case "--live-presets": guard let v = value() else { return fail(usage) }; livePresets = v.split(separator: ",").map(String.init)
            case "--no-live": livePresets = []
            default: return fail(usage)
            }
            index += 1
        }
        if let unknown = (presets + livePresets).first(where: { Aligner.Options.preset($0) == nil }) {
            return fail("不明なプリセット: \(unknown)")
        }
        if !presets.contains("current") { presets.insert("current", at: 0) }

        let directory = URL(fileURLWithPath: dump)
        do {
            let final = try JSONDecoder().decode(SpeakerTrial.FinalRecord.self,
                                                 from: Data(contentsOf: directory.appendingPathComponent("final.json")))
            let meta = try? JSONDecoder().decode(SpeakerTrial.Meta.self,
                                                 from: Data(contentsOf: directory.appendingPathComponent("meta.json")))
            var snapshots: [SpeakerTrial.Snapshot] = []
            let liveURL = directory.appendingPathComponent("live.jsonl")
            if !livePresets.isEmpty, FileManager.default.fileExists(atPath: liveURL.path) {
                let decoder = JSONDecoder()
                let records = try String(contentsOf: liveURL, encoding: .utf8).split(separator: "\n").map {
                    try decoder.decode(SpeakerTrial.LiveRecord.self, from: Data($0.utf8))
                }
                // 確定済み接頭辞が変わった記録は比較を無効にする
                snapshots = try SpeakerTrial.snapshots(from: records, final: final)
            }
            let comparison = SpeakerTrial.compare(source: source, final: final, snapshots: snapshots, presets: presets,
                                                  livePresets: snapshots.isEmpty ? [] : livePresets,
                                                  expectations: expectations, names: names, recorded: meta)
            try FileManager.default.createDirectory(at: out.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(comparison).write(to: out.appendingPathComponent("comparison.json"), options: .atomic)
            try SpeakerTrial.markdown(comparison, names: names, meta: meta)
                .write(to: out.appendingPathComponent("comparison.md"), atomically: true, encoding: .utf8)
            for preset in presets {
                let speakers = Aligner.speakers(for: final.tokens, segments: final.segments, options: Aligner.Options.preset(preset)!)
                try SpeakerTrial.transcript(tokens: final.tokens, speakers: speakers, names: names)
                    .write(to: out.appendingPathComponent("transcripts/\(preset).md"), atomically: true, encoding: .utf8)
            }
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
