import FluidAudio
import Foundation
import KikigakiCore

/// 画面とメニューに渡す1回分の状態
struct SessionSnapshot {
    var state: RecordingState = .idle
    var utterances: [Utterance] = []
    var names = SpeakerNames()
    /// 会議の経過秒(一時停止中は進まない)
    var elapsed: Double = 0
    /// 保存先(録音開始時に確定し、停止時と話者名の付け直し時に書く)
    var markdownURL: URL?
    /// 直近の保存・準備の結果や失敗の説明。ウィンドウに1行で出す
    var message: String?
}

/// 音声スレッド側の消費ループから読む一時停止フラグ
private final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isPaused: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// 消費ループが終了時に返すもの
private struct PipelineResult {
    var fedSamples = 0
    var frozen: [Int?] = []
}

/// 会議1本の録音〜保存の流れ。音源→(WAV)+話者判別+文字起こし→突き合わせ→表示、停止で Markdown を保存
@MainActor
final class MeetingSession {
    private(set) var snapshot = SessionSnapshot()
    var onChange: ((SessionSnapshot) -> Void)?

    private var config: ResolvedConfig
    private let models: () async throws -> SortformerModelStore.Loaded
    private let log: (String) -> Void

    private var source: AudioSource?
    private var samplesIn: AsyncStream<[Float]>.Continuation?
    private var consumer: Task<PipelineResult, Never>?
    private var transcriber: AppleTranscriber?
    private var diarizer: SpeakerDiarizer?
    private var wav: WavWriter?
    private let pause = PauseFlag()
    private var startedAt = Date()
    /// 停止後に話者名を付け直して保存し直すために持つ
    private var lastMeeting: MeetingMarkdown.Meeting?

    init(config: ResolvedConfig, models: @escaping () async throws -> SortformerModelStore.Loaded, log: @escaping (String) -> Void) {
        self.config = config
        self.models = models
        self.log = log
    }

    /// 設定の再読込。次の会議から反映する(進行中の会議の保存先は開始時に確定済み)
    func update(config: ResolvedConfig) {
        self.config = config
    }

    // MARK: - 操作

    /// 録音を始める。準備に失敗したら false(理由は snapshot.message とログ)
    @discardableResult
    func start(source: AudioSource) async -> Bool {
        guard snapshot.state.canStart else { return false }
        snapshot = SessionSnapshot(state: .preparing, message: "エンジンを準備中...")
        lastMeeting = nil
        emit()
        do {
            if source is MicSource, !(await MicSource.requestPermission()) {
                throw NSError(domain: "kikigaki", code: 3, userInfo: [NSLocalizedDescriptionKey: "マイクの使用が許可されていない。システム設定 > プライバシーとセキュリティ > マイク で KIKIGAKI を許可する"])
            }
            let models = try await models()
            let transcriber = try await AppleTranscriber(log: log)
            let diarizer = SpeakerDiarizer(models: models)
            guard snapshot.state == .preparing else { return false }  // 準備中に停止や終了が走った

            startedAt = Date()
            try FileManager.default.createDirectory(at: config.outputDir, withIntermediateDirectories: true)
            // 同じ分に2回開始すると同名になり前の会議を上書きするが、1分未満で止めた会議は捨ててよいとみなす
            let markdownURL = MeetingFiles.markdownURL(in: config.outputDir, startedAt: startedAt)
            if config.saveRecording {
                wav = try WavWriter(url: MeetingFiles.recordingURL(in: config.outputDir, startedAt: startedAt))
            }
            self.transcriber = transcriber
            self.diarizer = diarizer

            // バッファは無制限のまま。実時間より遅れると溜まるが、音声を捨てると時刻がずれて
            // 書き起こしが壊れるので、遅れは受け入れて停止時に全部処理する(M4 Pro で Sortformer fast +
            // SpeechTranscriber は実時間に十分追いつく。プロトで実測)
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            samplesIn = continuation
            pause.isPaused = false
            consumer = makeConsumer(stream: stream, transcriber: transcriber, diarizer: diarizer, wav: wav)
            let pause = self.pause
            // 一時停止の判定は収録時(音声スレッド)に行う。消費側で判定すると、処理が遅れている間に
            // 収録した分が利用者の操作した境界とずれる
            try source.start { chunk in
                if !pause.isPaused { continuation.yield(chunk) }
            }
            self.source = source

            snapshot.state = .recording
            snapshot.markdownURL = markdownURL
            snapshot.message = nil
            emit()
            return true
        } catch {
            log("開始に失敗: \(error)")
            await tearDown()
            snapshot = SessionSnapshot(state: .idle, message: "開始に失敗: \(error.localizedDescription)")
            emit()
            return false
        }
    }

    func stop() async {
        guard snapshot.state.canStop else { return }
        snapshot.state = .finishing
        snapshot.message = "最終判定と保存中..."
        emit()

        source?.stop()
        source = nil
        samplesIn?.finish()
        samplesIn = nil
        let result = await consumer?.value ?? PipelineResult()
        consumer = nil
        wav?.close()
        wav = nil

        var note: String?
        var tokens: [TimedToken] = []
        if let transcriber {
            do {
                tokens = try await transcriber.finish()
            } catch {
                // 最終化に失敗しても、それまでに得た確定・暫定トークンは残す(空の Markdown を書かない)
                log("文字起こしの終了に失敗。取得済みの結果で保存する: \(error)")
                tokens = await transcriber.tokens()
                note = "文字起こしの最終化に失敗したため途中までの結果"
            }
        }
        var segments: [SpeakerSegment] = []
        if let diarizer {
            do { try diarizer.finish() } catch { log("話者判別の終了に失敗: \(error)") }
            segments = diarizer.segments()
            diarizer.cleanup()
        }
        transcriber = nil
        diarizer = nil

        // KIKIGAKI_DEBUG_LIVE=1: 停止直前の録音中表示を stderr に出す(最終結果との差を調べる用)
        if ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_LIVE"] != nil {
            log("[live]\n" + TranscriptRenderer.text(snapshot.utterances, names: snapshot.names))
        }
        // 最終結果は凍結を使わず、確定した区間で全体を判定し直す(暫定区間で凍結した表示より確定区間の
        // ほうが正確で、保存する Markdown と画面を一致させる。プロトと同じ扱い)
        let speakers = Aligner.speakers(for: tokens, segments: segments)
        let utterances = Aligner.utterances(tokens: tokens, speakers: speakers)
        // KIKIGAKI_DEBUG_PHRASES=1: フレーズ分割と話者判定の調査用。フレーズごとにトークンの
        // 生の判定(区間からの窓判定)→多数決後の判定と時刻を stderr に出す
        if ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_PHRASES"] != nil {
            let raw = tokens.map { Aligner.speaker(at: $0.midpoint, segments: segments) }
            for r in Aligner.phraseRanges(tokens) {
                let desc = r.map { i in
                    "\(tokens[i].text)[\(raw[i].map(String.init) ?? "?")→\(speakers[i].map(String.init) ?? "?") "
                        + String(format: "%.2f-%.2f", tokens[i].start, tokens[i].end) + "]"
                }.joined(separator: " ")
                log("[phrase id=\(tokens[r.lowerBound].phraseId)] \(desc)")
            }
        }
        let duration = Double(result.fedSamples) / 16000
        let meeting = MeetingMarkdown.Meeting(startedAt: startedAt, duration: duration, utterances: utterances, names: snapshot.names)
        lastMeeting = meeting

        snapshot.state = .idle
        snapshot.utterances = utterances
        snapshot.elapsed = duration
        save()
        if let note { snapshot.message = note + " / " + (snapshot.message ?? "") }
        emit()
    }

    func togglePause() {
        switch snapshot.state {
        case .recording:
            pause.isPaused = true
            snapshot.state = .paused
        case .paused:
            pause.isPaused = false
            snapshot.state = .recording
        default:
            return
        }
        emit()
    }

    /// 枡に名前を付ける。停止後なら Markdown を保存し直す
    func rename(slot: Int, to name: String) {
        var names = snapshot.names
        names.set(name, for: slot)
        guard names != snapshot.names else { return }
        snapshot.names = names
        if var meeting = lastMeeting {
            meeting.names = names
            lastMeeting = meeting
            save()
        }
        emit()
    }

    // MARK: - 内部

    private func emit() {
        onChange?(snapshot)
    }

    private func save() {
        guard let meeting = lastMeeting, let url = snapshot.markdownURL else { return }
        do {
            try MeetingMarkdown.render(meeting).write(to: url, atomically: true, encoding: .utf8)
            snapshot.message = "保存: \(url.path)"
        } catch {
            log("保存に失敗: \(error)")
            snapshot.message = "保存に失敗: \(error.localizedDescription)"
        }
    }

    private func tearDown() async {
        source?.stop()
        source = nil
        samplesIn?.finish()
        samplesIn = nil
        _ = await consumer?.value
        consumer = nil
        wav?.close()
        wav = nil
        diarizer?.cleanup()
        diarizer = nil
        transcriber = nil
    }

    /// 音声を1本の消費タスクで処理する。WAV書き出し→話者判別→文字起こしの順に同じチャンクを流し、
    /// 0.5秒ごとに突き合わせて表示へ渡す。話者判定は `SpeakerFreeze` の猶予を過ぎた分から凍結する
    private func makeConsumer(
        stream: AsyncStream<[Float]>, transcriber: AppleTranscriber, diarizer: SpeakerDiarizer, wav: WavWriter?
    ) -> Task<PipelineResult, Never> {
        let log = self.log
        // self を強く持つ。stop() が消費タスクの終了を待つので、タスクの寿命は会議の間だけ
        return Task.detached(priority: .userInitiated) {
            var result = PipelineResult()
            var lastDraw = Date.distantPast
            for await chunk in stream {
                result.fedSamples += chunk.count
                do { try wav?.write(chunk) } catch { log("WAV書き出しに失敗: \(error)") }
                do { try diarizer.process(chunk) } catch { log("話者判別に失敗: \(error)") }
                do { try transcriber.feed(chunk) } catch { log("文字起こしへの入力に失敗: \(error)") }

                guard Date().timeIntervalSince(lastDraw) >= 0.5 else { continue }
                lastDraw = Date()
                let (tokens, finalCount) = await transcriber.snapshot()
                let segments = diarizer.segments()
                let elapsed = Double(result.fedSamples) / 16000
                let speakers = Aligner.speakers(for: tokens, segments: segments, frozen: result.frozen)
                result.frozen = SpeakerFreeze.advance(
                    frozen: result.frozen, speakers: speakers, tokens: tokens, elapsed: elapsed, finalCount: finalCount)
                let utterances = Aligner.utterances(tokens: tokens, speakers: speakers)
                await MainActor.run { self.publishLive(utterances: utterances, elapsed: elapsed) }
            }
            return result
        }
    }

    private func publishLive(utterances: [Utterance], elapsed: Double) {
        guard snapshot.state == .recording || snapshot.state == .paused else { return }
        snapshot.utterances = utterances
        snapshot.elapsed = elapsed
        emit()
    }
}
