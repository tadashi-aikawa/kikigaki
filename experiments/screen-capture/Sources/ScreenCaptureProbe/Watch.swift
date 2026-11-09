import AppKit
import CoreMedia
import Darwin
import ScreenCaptureKit
import VideoToolbox

/// 選んだディスプレイのSCStreamを1秒間隔で開き、判定・保存・負荷を記録する。
/// - `frames.jsonl`: 観測の縮小画像。`sweep` でしきい値を当て直す
/// - `events.jsonl`: 保存、負荷の標本、ストリームの異常
/// - `captures/HHmmss.webp`: 保存した画像。`--no-write` なら符号化だけして書かない
/// - `all/`: `--keep-all` のとき、観測した全フレーム。取りこぼしを人が数えるために使う
enum WatchCommand {
    static func main(_ args: inout Arguments) async throws {
        let display = try DisplayInfo.find(try args.required("--display"))
        let seconds = args.double("--seconds") ?? 60
        let out = URL(fileURLWithPath: try args.required("--out"))
        var params = DetectorParams()
        if let value = args.int("--width") { params.thumbWidth = value }
        if let value = args.int("--cell") { params.cellDelta = value }
        if let value = args.double("--motion") { params.motion = value }
        if let value = args.double("--save") { params.save = value }
        if let value = args.double("--settle") { params.settle = value }
        if let value = args.double("--volatile") { params.volatileSeconds = value }
        params.excludeTopFraction = args.flag("--include-menubar") ? 0 : display.menuBar / display.points.height
        let options = Watcher.Options(quality: args.double("--quality") ?? 80, write: !args.flag("--no-write"), keepAll: args.flag("--keep-all"),
                                      excludedBundles: Set(args.strings("--exclude-bundle") ?? ["com.tadashi-aikawa.kikigaki"]))
        guard !FileManager.default.fileExists(atPath: out.path) else { throw ProbeError.message("出力先が既にある。毎回新しい出力先を渡す: \(out.path)") }
        try FileManager.default.createDirectory(at: out.appendingPathComponent("captures"), withIntermediateDirectories: true)
        if options.keepAll { try FileManager.default.createDirectory(at: out.appendingPathComponent("all"), withIntermediateDirectories: true) }

        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ProbeError.message("画面収録の許可がありません。許可してから、必要ならこのプロセスを起動し直す")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { throw ProbeError.message("SCShareableContentにディスプレイが無い") }
        let excludedApps = content.applications.filter { options.excludedBundles.contains($0.bundleIdentifier) || $0.processID == getpid() }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        // 1x寸法。Retinaでは半分に縮めて受け取る。
        config.width = Int(display.points.width)
        config.height = Int(display.points.height)
        config.captureResolution = .nominal
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3

        let watcher = try Watcher(out: out, display: display, params: params, options: options,
                                  excludedPIDs: Set(excludedApps.map { pid_t($0.processID) }))
        let stream = SCStream(filter: filter, configuration: config, delegate: watcher)
        try stream.addStreamOutput(watcher, type: .screen, sampleHandlerQueue: watcher.queue)
        print("監視: \(display.name) \(config.width)x\(config.height) \(Int(seconds))秒 \(params)")
        print("除外: " + (excludedApps.map(\.bundleIdentifier).joined(separator: ", ")))
        watcher.begin()
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try? await stream.stopCapture()
        watcher.finish()
    }
}

final class Watcher: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Options {
        var quality: Double
        var write: Bool
        var keepAll: Bool
        var excludedBundles: Set<String>
    }

    let queue = DispatchQueue(label: "probe.capture")
    private let encodeQueue = DispatchQueue(label: "probe.encode")
    private let out: URL
    private let display: DisplayInfo
    private let options: Options
    private let excludedPIDs: Set<pid_t>
    private let detector: ChangeDetector
    private let frames: RecordWriter
    private let events: RecordWriterJSON
    private var startMach: UInt64 = 0
    private var startDate = Date()
    private var timer: DispatchSourceTimer?
    /// 保存の候補にする最新のフレーム。題の候補も同じフレームを受け取った時点で取り、画像と一組で持つ。
    private var latestImage: (index: Int, image: CGImage, windows: [FrontWindow])?
    /// blank・suspended・停止の後、次のcompleteが届くまでは保存を判定しない。
    private var unavailable = false
    private var startCPU = 0.0
    private var frameIndex = 0
    private var statusCounts: [String: Int] = [:]
    private var lastCompleteTime: Double?
    private var intervals: [Double] = []
    private var savedCount = 0
    private var encodeMillis: [Double] = []
    private var thumbMillis: [Double] = []
    private var bytes: [Int] = []
    private var usedNames: Set<String> = []
    private var peakFootprint: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info }()

    init(out: URL, display: DisplayInfo, params: DetectorParams, options: Options, excludedPIDs: Set<pid_t>) throws {
        self.out = out; self.display = display; self.options = options; self.excludedPIDs = excludedPIDs
        detector = ChangeDetector(params: params)
        frames = try RecordWriter(url: out.appendingPathComponent("frames.jsonl"))
        events = try RecordWriterJSON(url: out.appendingPathComponent("events.jsonl"))
    }

    func begin() {
        startMach = mach_absolute_time()
        startDate = Date()
        startCPU = Self.cpuSeconds()
        events.write(["kind": "start", "display": display.name, "params": detector.params.description, "wall": ISO8601DateFormatter().string(from: startDate)])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var lastSample = 0.0
        timer.schedule(deadline: .now() + Simulation.tickInterval, repeating: Simulation.tickInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.seconds(mach_absolute_time())
            if !self.unavailable, let decision = self.detector.tick(now: now) { self.save(decision) }
            if now - lastSample >= 5 { lastSample = now; self.sampleResources(now: now) }
        }
        timer.resume()
        self.timer = timer
    }

    /// 停止後に呼ぶ。新しい判定を止め、符号化を待ち、符号化から戻った記録まで済んでから集計して閉じる。
    func finish() {
        queue.sync {
            timer?.cancel()
            unavailable = true
            frames.write(RecordLine(kind: "end", t: seconds(mach_absolute_time())))
        }
        encodeQueue.sync {}
        let summary: [String: Any] = queue.sync {
            sampleResources(now: seconds(mach_absolute_time()))
            let elapsed = seconds(mach_absolute_time())
            // 起動処理を混ぜないよう、監視を始めた時点からの差で測る。
            let cpu = Self.cpuSeconds() - startCPU
            let summary: [String: Any] = [
                "kind": "summary", "seconds": elapsed, "status": statusCounts, "saved": savedCount,
                "cpuSeconds": cpu, "cpuPercent": cpu / elapsed * 100, "sampledPeakFootprintMB": Double(peakFootprint) / 1_048_576,
                "thumbMsAvg": Self.average(thumbMillis), "encodeMsAvg": Self.average(encodeMillis), "encodeMsMax": encodeMillis.max() ?? 0,
                "bytesAvg": Self.average(bytes.map(Double.init)), "bytesMax": bytes.max() ?? 0,
                "intervalMedian": intervals.sorted().dropFirst(intervals.count / 2).first ?? 0, "intervalMax": intervals.max() ?? 0,
            ]
            events.write(summary)
            events.close(); frames.close()
            return summary
        }
        for key in summary.keys.sorted() { print("\(key)\t\(summary[key]!)") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = attachments[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let name = Self.name(status)
        statusCounts[name, default: 0] += 1
        let displayMach = attachments[.displayTime] as? UInt64 ?? mach_absolute_time()
        let time = seconds(displayMach)
        switch status {
        case .complete:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            guard let image else { return }
            let started = mach_absolute_time()
            guard let record = Thumbnail.make(image, width: Thumbnail.recordWidth) else { return }
            let thumb = Thumbnail.resized(record, width: detector.params.thumbWidth)
            thumbMillis.append(seconds(mach_absolute_time()) * 1000 - seconds(started) * 1000)
            let dirty = (attachments[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) }
                .reduce(0.0) { $0 + $1.width * $1.height } ?? 0
            // --no-write は負荷を測るためのもの。画面の中身は縮小画像も残さない。
            if options.write {
                frames.frame(index: frameIndex, time: time, thumb: record, dirty: dirty / Double(image.width * image.height))
            } else {
                frames.write(RecordLine(kind: "frame", t: time, i: frameIndex, dirty: dirty / Double(image.width * image.height)))
            }
            if let last = lastCompleteTime { intervals.append(time - last) }
            lastCompleteTime = time
            if unavailable {
                // 撮れない期間の後の最初の1枚は、最初のフレームと同じく待たずに保存する(判定はmarkUnavailableで初期化済み)。
                unavailable = false
                events.write(["kind": "recovered", "t": time])
            }
            latestImage = (frameIndex, image, FrontWindow.candidates(display: display.id, excludedPIDs: excludedPIDs))
            if options.keepAll { write(image: image, name: String(format: "%05d-%07.2f", frameIndex, time), directory: "all", event: nil) }
            let (_, decision) = detector.frame(index: frameIndex, time: time, thumb: thumb)
            frameIndex += 1
            if let decision { save(decision) }
        case .idle:
            frames.write(RecordLine(kind: "idle", t: time))
            if !unavailable, let decision = detector.tick(now: time) { save(decision) }
        default:
            // blank・suspended・stoppedは撮れていない。保留中のフレームを後から保存しない。
            if status != .started { markUnavailable(at: time) }
            events.write(["kind": "status", "status": name, "t": time])
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            markUnavailable(at: seconds(mach_absolute_time()))
            events.write(["kind": "stopped", "error": "\(error)"])
        }
        print("ストリームが止まった: \(error)")
    }

    /// 判定を初期化し、観測ログにも残す。`sweep` が同じ時点で同じ初期化を再現する。
    private func markUnavailable(at time: Double) {
        if !unavailable { frames.write(RecordLine(kind: "unavailable", t: time)) }
        unavailable = true
        latestImage = nil
        detector.reset()
    }

    private func save(_ decision: SaveDecision) {
        guard let latest = latestImage, latest.index == decision.frameIndex else { return }
        let wall = startDate.addingTimeInterval(decision.frameTime)
        let candidates = latest.windows
        let label = [display.name, candidates.first?.label].compactMap { $0 }.joined(separator: " · ")
        let formatter = DateFormatter(); formatter.dateFormat = "HHmmss"
        var base = formatter.string(from: wall), suffix = 2
        while usedNames.contains(base) { base = formatter.string(from: wall) + "_\(suffix)"; suffix += 1 }
        usedNames.insert(base)
        savedCount += 1
        write(image: latest.image, name: base, directory: "captures", event: [
            "kind": "save", "t": decision.frameTime, "decidedAt": decision.decidedAt, "reason": decision.reason.rawValue,
            "diffSaved": decision.diffSaved, "label": label,
            "candidates": candidates.prefix(3).map { String(format: "%@ %.0f%%", $0.label, $0.coverage * 100) },
        ])
        print(String(format: "保存 %6.1f秒 (決定 %6.1f秒) %@ %@", decision.frameTime, decision.decidedAt, base, label))
    }

    private func write(image: CGImage, name: String, directory: String, event: [String: Any]?) {
        encodeQueue.async { [self] in
            let started = Date()
            do {
                let data = try WebPEncoder.encode(image, quality: options.quality)
                let millis = Date().timeIntervalSince(started) * 1000
                if options.write { try data.write(to: out.appendingPathComponent(directory).appendingPathComponent(name + ".webp")) }
                guard var event else { return }
                event["bytes"] = data.count; event["encodeMs"] = millis; event["file"] = options.write ? "\(directory)/\(name).webp" : nil
                queue.async { [self] in
                    encodeMillis.append(millis); bytes.append(data.count)
                    events.write(event)
                }
            } catch {
                queue.async { [self] in events.write(["kind": "saveError", "error": "\(error)"]) }
            }
        }
    }

    private func sampleResources(now: Double) {
        let footprint = Self.footprint()
        peakFootprint = max(peakFootprint, footprint)
        events.write(["kind": "resources", "t": now, "cpuSeconds": Self.cpuSeconds(), "footprintMB": Double(footprint) / 1_048_576])
    }

    private func seconds(_ mach: UInt64) -> Double {
        let delta = mach >= startMach ? Double(mach - startMach) : -Double(startMach - mach)
        return delta * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func name(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        @unknown default: return "unknown"
        }
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
}

final class RecordWriterJSON {
    private let handle: FileHandle
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ProbeError.message("作れません: \(url.path)") }
        handle = try FileHandle(forWritingTo: url)
    }
    func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        handle.write(data)
    }
    func close() { try? handle.close() }
}
