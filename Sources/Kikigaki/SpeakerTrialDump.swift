import Foundation
import KikigakiCore

/// 話者の割当と固定の検証用に、録音中の snapshot 列と停止時の入力を書き出す。会話本文を含むので、
/// 出力先は `KIKIGAKI_TRIAL_DUMP` で明示したときだけ作る。環境変数を読むのはDEBUGビルドだけ。
/// 設計: docs/speaker-compare.md
final class SpeakerTrialDump: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var recorder = SpeakerTrial.Recorder()
    private let handle: FileHandle
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private var failed = false

    init(directory: URL, meta: SpeakerTrial.Meta) throws {
        self.directory = directory
        // 前の記録の final.json と新しい live が混ざらないよう、中身のある保存先は使わない
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: directory.path), !existing.isEmpty {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(meta).write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        let live = directory.appendingPathComponent("live.jsonl")
        guard FileManager.default.createFile(atPath: live.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: live)
    }

    /// 消費タスクから呼ぶ。書けなければ以後の記録をやめ、途中までの列で比較させない
    func record(_ snapshot: SpeakerTrial.Snapshot, frozenAppended: [Int?]) {
        lock.withLock {
            guard !failed else { return }
            do {
                var data = try encoder.encode(recorder.record(snapshot, frozenAppended: frozenAppended))
                data.append(0x0A)
                try handle.write(contentsOf: data)
            } catch {
                failed = true
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("live.jsonl"))
                FileHandle.standardError.write(Data("Kikigaki: [trial] live記録を書けない。記録を消した: \(error)\n".utf8))
            }
        }
    }

    func writeFinal(_ final: SpeakerTrial.FinalRecord) {
        lock.withLock {
            try? handle.close()
            do {
                try encoder.encode(final).write(to: directory.appendingPathComponent("final.json"), options: .atomic)
                FileHandle.standardError.write(Data("Kikigaki: [trial] 書き出し: \(directory.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("Kikigaki: [trial] final.json を書けない: \(error)\n".utf8))
            }
        }
    }
}
