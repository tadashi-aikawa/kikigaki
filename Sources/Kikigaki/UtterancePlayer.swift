import AVFoundation
import KikigakiCore

/// 発言の行の区間だけを元の音声から流す。仕様は docs/utterance-playback.md
///
/// `AVAudioPlayer` ではなく `AVAudioPlayerNode.scheduleSegment` を使う。
/// 前者はmp3などの可変ビットレートで位置合わせがずれることがあり、行の頭が切れる。
/// `AVAudioFile` はフレーム単位で読めるので、行の区間をそのままフレームで指せる。
@MainActor
final class UtterancePlayer {
    /// 再生中の行。終わる・止める・失敗するとnilに戻る
    private(set) var playingID: AnyHashable?
    var onChange: (() -> Void)?
    private var engine: AVAudioEngine?
    /// 再生ごとに変える。止めた後や次の再生の後に届いた古い完了通知を見分ける
    private(set) var generation = UUID()

    enum Failure: Error, LocalizedError {
        case outOfRange
        var errorDescription: String? { "この発言の位置が音声ファイルの長さを越えています" }
    }

    func play(url: URL, range: ClosedRange<Double>, id: AnyHashable) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        guard let frames = UtterancePlayback.frames(for: range, sampleRate: file.processingFormat.sampleRate,
                                                    length: file.length) else { throw Failure.outOfRange }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        let current = UUID()
        generation = current
        // 終わりの通知は音声スレッドから届く。止めた後や次の再生の後に届いた古い通知は捨てる
        node.scheduleSegment(file, startingFrame: frames.start, frameCount: AVAudioFrameCount(frames.count), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(current) }
        }
        try engine.start()
        node.play()
        self.engine = engine
        playingID = id
        onChange?()
    }

    /// 区間を流し終えた通知。今の再生の通知だけで止める
    func finished(_ generation: UUID) {
        guard self.generation == generation else { return }
        stop()
    }

    func stop() {
        generation = UUID()
        engine?.stop()
        engine = nil
        guard playingID != nil else { return }
        playingID = nil
        onChange?()
    }
}
