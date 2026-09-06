import CoreML
import FluidAudio
import Foundation
import KikigakiCore

/// 音声消費タスクだけが使う。追加モデルは人数指定時だけ読み込み、PCMは直近20秒に限定する。
final class SpeakerVoiceMatcher {
    private let extractor: EmbeddingExtractor
    private let maskFrames: Int
    private var samples: [Float] = []
    private var bufferOffset = 0
    private var storageStart = 0
    private var received = 0
    private var lastCheck = 0.0
    private var sampledUntil: [Int: Double] = [:]
    private(set) var identity: SpeakerIdentity
    private(set) var warning: String?
    private var failed = false
    private struct Observation {
        var range: SpeakerSegment
        var embedding: [Float]?
        var error: String?
    }
    private var job: Task<Void, Never>?
    private let lock = NSLock()
    private var completed: [Observation]?
    var needsUpdate: Bool { !failed && Double(received) / 16000 - lastCheck >= 2 }

    private init(model: MLModel, limit: Int) throws {
        guard let shape = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape,
              shape.count == 2, shape[1].intValue > 0 else {
            throw NSError(domain: "kikigaki", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "声の照合モデルの入力形式を確認できません"])
        }
        maskFrames = shape[1].intValue
        extractor = EmbeddingExtractor(embeddingModel: model)
        identity = SpeakerIdentity(limit: limit)
    }

    static func load(limit: Int) async throws -> SpeakerVoiceMatcher {
        let name = ModelNames.Diarizer.embeddingFile
        let directory = DiarizerModels.defaultModelsDirectory()
        let path = directory.appendingPathComponent(name)
        // loadModels(.diarizer)は不要なsegmentationまで取得するため、モデルのディレクトリだけを取得する。
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        if let model = try? MLModel(contentsOf: path, configuration: configuration) {
            return try SpeakerVoiceMatcher(model: model, limit: limit)
        }
        try await ModelHub.download(.diarizer, subdirectory: name, to: directory)
        let model = try MLModel(contentsOf: path, configuration: configuration)
        return try SpeakerVoiceMatcher(model: model, limit: limit)
    }

    func append(_ chunk: [Float]) {
        received += chunk.count
        samples.append(contentsOf: chunk)
        let excess = samples.count - storageStart - 20 * 16000
        if excess > 0 {
            storageStart += excess
            bufferOffset += excess
        }
        // 有効窓は20秒。物理配列の左詰めは2秒分を捨てるときだけで、チャンクごとには行わない。
        if storageStart >= 2 * 16000 {
            samples.removeFirst(storageStart)
            storageStart = 0
        }
    }

    func update(segments: [SpeakerSegment], final: Bool = false) {
        collectCompleted()
        guard !failed else { return }
        guard job == nil else { return } // 推論は同時に1バッチだけ。待ち行列を増やさない。
        let elapsed = Double(received) / 16000
        guard final || elapsed - lastCheck >= 2 else { return }
        lastCheck = elapsed
        // 暫定区間の端をすぐ採取せず、通常は1.2秒の猶予を置く。
        let ranges = SpeakerVoiceSamples.ranges(segments: segments, after: sampledUntil,
            bufferStart: Double(bufferOffset) / 16000, until: final ? elapsed : elapsed - 1.2)
        var requests: [(SpeakerSegment, [Float])] = []
        for range in ranges where identity.profiles[range.speaker, default: []].count < 3 {
            let start = storageStart + max(0, Int(ceil(range.start * 16000)) - bufferOffset)
            let end = min(samples.count, storageStart + Int(floor(range.end * 16000)) - bufferOffset)
            guard end - start >= 2 * 16000, end - start <= 160_000 else { continue }
            sampledUntil[range.speaker] = range.end
            requests.append((range, Array(samples[start..<end])))
        }
        guard !requests.isEmpty else { return }
        let extractor = self.extractor, maskFrames = self.maskFrames
        job = Task.detached(priority: .utility) { [self, requests] in
            let observations = requests.map { range, audio -> Observation in
                do {
                    let vectors = try extractor.getEmbeddings(audio: audio,
                        masks: [[Float](repeating: 1, count: maskFrames)])
                    return Observation(range: range, embedding: vectors.first)
                } catch { return Observation(range: range, error: error.localizedDescription) }
            }
            lock.withLock { completed = observations }
        }
    }

    func finish(segments: [SpeakerSegment]) async {
        await job?.value
        collectCompleted()
        update(segments: segments, final: true)
        await job?.value
        collectCompleted()
    }

    private func collectCompleted() {
        guard let observations = lock.withLock({ () -> [Observation]? in
            defer { completed = nil }
            return completed
        }) else { return }
        job = nil
        for observation in observations {
            let range = observation.range
            if let error = observation.error {
                failed = true
                warning = "声の照合に失敗しました。統合先を手動で指定してください: \(error)"
            } else if let vector = observation.embedding, identity.observe(slot: range.speaker, embedding: vector) {
                if ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_PHRASES"] == "1" {
                    let scores = identity.scores[range.speaker, default: [:]].sorted { $0.key < $1.key }
                        .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " ")
                    NSLog("[voice] slot=%d range=%.2f-%.2f target=%@ scores=%@", range.speaker, range.start, range.end,
                          identity.mapping[range.speaker].map(String.init) ?? "?", scores)
                }
            } else {
                warning = "声の特徴を取得できない区間がありました。判定待ちの話者は手動で指定できます。"
            }
        }
    }
}
