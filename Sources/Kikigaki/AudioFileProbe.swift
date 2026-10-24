import AVFoundation
import Foundation
import KikigakiCore

/// 音声ファイルの長さと録音日時を、変換せずに読む。開始シートを出す前に使う。仕様は docs/audio-file.md
enum AudioFileProbe {
    static func load(_ url: URL) async throws -> AudioFile {
        let duration: Double
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            guard rate > 0, file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
            duration = Double(file.length) / rate
        } catch {
            throw NSError(domain: "kikigaki", code: 4, userInfo: [NSLocalizedDescriptionKey: "音声として読めません: \(url.lastPathComponent)"])
        }
        let metadata = await metadataCreationDate(url)
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        return AudioFile(url: url, duration: duration,
                         recordedAt: AudioFile.recordedAt(metadata: metadata, fileCreation: created, fallback: Date()))
    }

    /// ボイスメモなどが書くメタデータの作成日時。無い形式も多いので、読めなければnil。
    private static func metadataCreationDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// ドロップやファイル選択で受け付けるか。読めるかどうかは `load` で確かめる。
    static func isAudio(_ url: URL) -> Bool {
        guard url.isFileURL, let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .audio)
    }
}
