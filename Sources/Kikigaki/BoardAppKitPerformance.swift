#if DEBUG
import AppKit
import WebKit
import ObjectiveC
import KikigakiCore

/// opt-inの独立アプリイベントループ。NSWindowへの入力配送を通し、OSへイベントを送らない。
/// 通常の起動・swift testでは実行しない。設定、音声、AI、利用者の会議データは使わない。
@MainActor final class BoardAppKitPerformance: NSObject, NSApplicationDelegate {
    private let output: URL
    private let suite = "kikigaki-board-perf-" + UUID().uuidString
    private var controller: TranscriptWindowController!
    private var store: MinutesStore!
    private var results: [[String: Any]] = []
    private var active = false
    private var sent: [[String: Any]] = []
    private var queueDelays: [Double] = []
    private var sendCosts: [Double] = []
    private var updateCosts: [Double] = []
    private var updates = 0
    private var near60FPS: Bool?
    private var eventSerial = 0
    private var inputTimer: DispatchSourceTimer?
    private var heartbeat: DispatchSourceTimer?
    private var transcriptTimer: Timer?
    private let queue = DispatchQueue(label: "kikigaki.board.perf.clock", qos: .userInteractive)
    private let environment = ProcessInfo.processInfo.environment
    init(output: String) { self.output = URL(fileURLWithPath: output).standardizedFileURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard output.path.hasPrefix("/tmp/") || output.path.hasPrefix("/private/tmp/") else {
            fail("出力先は/tmp配下だけ"); return
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(100, forKey: TranscriptWindowController.textScaleDefaultsKey)
            controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
            controller.window!.setFrameAutosaveName("")
            controller.window!.title = "KIKIGAKI ボードAppKit入力計測"
            store = MinutesStore(meetingID: UUID(), outputDirectory: output)
            controller.connectMinutes(store)
            try store.bindBoard("## ボード")
            controller.show()
            controller.showMinutes()
            controller.window!.setContentSize(NSSize(width: 1500, height: 900))
            if let name = environment["KIKIGAKI_BOARD_PERF_SCREEN"] {
                guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else { throw CocoaError(.featureUnsupported) }
                let size = NSSize(width: min(1500, screen.visibleFrame.width), height: min(900, screen.visibleFrame.height))
                controller.window!.setContentSize(size)
                controller.window!.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - controller.window!.frame.width / 2,
                                                         y: screen.visibleFrame.midY - controller.window!.frame.height / 2))
            } else { controller.window!.center() }
            NSApp.activate(ignoringOtherApps: true)
            Task {
                do { try await run(); NSApp.terminate(nil) }
                catch { fail(String(describing: error)) }
            }
        } catch { fail(String(describing: error)) }
    }

    private func run() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../web/minutes")
        let script = try String(contentsOf: root.appendingPathComponent("measure-appkit.js"), encoding: .utf8)
        try configureFrameRate(controller.minutesSplit.preview.boardDocument.webView.configuration.preferences)
        if environment["KIKIGAKI_BOARD_PERF_HIGH_FPS"] != nil, near60FPS == nil {
            throw CocoaError(.featureUnsupported)
        }
        let counts = environment["KIKIGAKI_BOARD_PERF_QUICK"] == "1" ? [30] : [30, 60]
        let mapFilter = environment["KIKIGAKI_BOARD_PERF_MAP"]
        if let mapFilter, !["coarse", "detailed", "none"].contains(mapFilter) { throw CocoaError(.coderInvalidValue) }
        let maps = mapFilter.map { [$0] } ?? (environment["KIKIGAKI_BOARD_PERF_QUICK"] == "1" ? ["coarse"] : ["coarse", "detailed", "none"])
        let repeats = Int(environment["KIKIGAKI_BOARD_PERF_REPEATS"] ?? "3") ?? 3
        let duration = Double(environment["KIKIGAKI_BOARD_PERF_SECONDS"] ?? "3") ?? 3
        let idleOnly = environment["KIKIGAKI_BOARD_PERF_IDLE"] == "1"
        let inputs = idleOnly ? ["idle"] : ["scroll", "drag"]
        let layerFlag = environment["KIKIGAKI_BOARD_PERF_LAYER"]
        guard layerFlag == nil || ["0", "1"].contains(layerFlag!) else { throw CocoaError(.coderInvalidValue) }
        let layers = layerFlag.map { [$0 == "1"] } ?? [false, true]
        guard (1...10).contains(repeats), duration.isFinite, (1...30).contains(duration) else { throw CocoaError(.coderInvalidValue) }
        for repeatIndex in 0..<repeats {
            for count in counts {
                for flowing in idleOnly ? [false] : [false, true] {
                    // 反復ごとに順序を反転し、ウォームアップと温度による偏りを減らす。
                    for map in repeatIndex % 2 == 0 ? maps : maps.reversed() {
                        for layer in repeatIndex % 2 == 0 ? layers : layers.reversed() {
                            for input in inputs {
                                try await measure(count: count, flowing: flowing, map: map, layer: layer,
                                                  input: input, repeatIndex: repeatIndex, duration: duration, script: script)
                                try save()
                            }
                        }
                    }
                }
            }
        }
    }

    private func measure(count: Int, flowing: Bool, map: String, layer: Bool, input: String,
                         repeatIndex: Int, duration: Double, script: String) async throws {
        let nodes = (1...count).map { "T\($0)[\"T\($0) 論点の確認と運用の判断\"]" }
        let edges = (1...count).filter { $0 % 6 != 0 }.map { "T\($0) --> T\($0+1)" }
        let definitions = BoardPrompt.builtIn.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("classDef ") }
        let classes = (1...count).compactMap { index -> String? in
            let names = ["done", "hold", "now", "rejected", ""]
            let name = names[(index - 1) % names.count]
            return name.isEmpty ? nil : "class T\(index) \(name)"
        }
        let diagram = "```mermaid\nflowchart TB\n" + (definitions + nodes + edges + classes).joined(separator: "\n") + "\n```"
        let source = "# 使い捨て会議\n## ボード\n" + diagram
        let file = output.appendingPathComponent("fixture.md")
        if (try? String(contentsOf: file, encoding: .utf8)) != source {
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
        if store.state.participantMinutesPath == nil { try store.select(file.path) }
        let preview = controller.minutesSplit.preview
        var rendered = false
        var renderError: String?
        let originalRendered = preview.boardDocument.onRendered
        let originalError = preview.boardDocument.onError
        defer {
            preview.boardDocument.onRendered = originalRendered
            preview.boardDocument.onError = originalError
        }
        preview.boardDocument.onRendered = { text in originalRendered?(text); rendered = true }
        preview.boardDocument.onError = { message in renderError = message; originalError?(message) }
        preview.receive(.body(source, [], modifiedAt: Date()))
        // ファイル監視の初回読み取りと直接描画を重ねない。計測する入力区間の外で待つ。
        try await Task.sleep(for: .milliseconds(350))
        rendered = false
        // 同一本文は再描画されないので、計測の各条件では明示して描き直す。
        preview.boardDocument.render(diagram, reset: true)
        preview.selectBoard(true)
        for _ in 0..<500 {
            if rendered || renderError != nil { break }; try await Task.sleep(for: .milliseconds(20))
        }
        guard rendered, renderError == nil else {
            throw NSError(domain: "BoardAppKitPerformance.render", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: renderError ?? "\(count)ノードの描画完了通知が10秒以内に届きませんでした"])
        }
        let web = preview.boardDocument.webView
        controller.window!.makeKeyAndOrderFront(nil)
        controller.window!.makeFirstResponder(web)
        var snapshot = SessionSnapshot()
        snapshot.state = .recording
        snapshot.markdownURL = output.appendingPathComponent("transcript.md")
        snapshot.utterances = (0..<300).map { utterance($0) }
        controller.apply(snapshot)
        try await Task.sleep(for: .milliseconds(500))
        NSApp.activate()
        controller.window!.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        print("入力準備 active=\(NSApp.isActive) key=\(controller.window!.isKeyWindow)")
        guard let point = try await web.callAsyncJavaScript(script, arguments: ["variant": map, "layer": layer], contentWorld: .page) as? [String: Double] else {
            throw CocoaError(.coderReadCorrupt)
        }
        try await Task.sleep(for: .milliseconds(300))
        sent = []; queueDelays = []; sendCosts = []; updateCosts = []; updates = 0
        active = true
        _ = try await web.evaluateJavaScript("boardPerf.begin()")
        let cpuStart = cpuTimes(web)
        let local = web.convert(NSPoint(x: point["x"]!, y: web.bounds.height - point["y"]!), to: nil)
        if input == "drag" { try send(type: .leftMouseDown, local: local) }
        var step = 0
        let clock = DispatchSource.makeTimerSource(queue: queue)
        clock.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .microseconds(100))
        clock.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                step += 1
                // 同一方向へ大きく移動し続けず、図が画面に残る滑らかな往復入力。
                let x = 80 * sin(Double(step) / 120 * .pi * 2)
                do {
                    if input == "scroll" { try self.send(type: .scrollWheel, local: local, delta: step % 120 < 60 ? 2 : -2) }
                    else { try self.send(type: .leftMouseDragged, local: NSPoint(x: local.x + x, y: local.y)) }
                } catch { self.fail(String(describing: error)) }
            }
        }
        if input != "idle" { inputTimer = clock; clock.resume() }
        else { clock.setEventHandler {}; clock.cancel(); clock.resume() }
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(100))
        ping.setEventHandler { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                self.queueDelays.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        if input != "idle" { heartbeat = ping; ping.resume() }
        else { ping.setEventHandler {}; ping.cancel(); ping.resume() }
        if flowing {
            let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active else { return }
                    let start = ProcessInfo.processInfo.systemUptime
                    self.updates += 1
                    if self.updates % 4 == 0 { snapshot.utterances.append(self.utterance(snapshot.utterances.count)) }
                    snapshot.elapsed += 0.125
                    snapshot.tentativeText = String(repeating: "流れている発言の内容を確認します。", count: self.updates % 4 + 1)
                    self.controller.apply(snapshot)
                    self.updateCosts.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
            }
            RunLoop.main.add(timer, forMode: .common); transcriptTimer = timer
        }
        try await Task.sleep(for: .seconds(duration))
        let cpu = cpuDelta(cpuStart, cpuTimes(web))
        inputTimer?.cancel(); heartbeat?.cancel(); transcriptTimer?.invalidate()
        inputTimer = nil; heartbeat = nil; transcriptTimer = nil
        if input == "drag" { try send(type: .leftMouseUp, local: local) }
        active = false
        try await Task.sleep(for: .milliseconds(200))
        guard let page = try await web.evaluateJavaScript("boardPerf.finish()") as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        var idleCPU: [String: Double]?
        if input == "idle" {
            // rAF計測ループ自体が静止時の負荷を増やすため、停止して別区間を測る。
            _ = try await web.evaluateJavaScript("boardPerf.stop()")
            try await Task.sleep(for: .milliseconds(500))
            let start = cpuTimes(web)
            try await Task.sleep(for: .seconds(duration))
            idleCPU = cpuDelta(start, cpuTimes(web))
        }
        let screen = controller.window!.screen!
        let intervals = page["intervals"] as? [Double] ?? []
        let events = page["events"] as? [[String: Any]] ?? []
        // DOM event.timeStampをネイティブイベントの時刻と対応付ける。coalesceされたイベントは最後の時刻を持つ。
        var latencies: [Double] = []
        var transformLatencies: [Double] = []
        var unmatched = 0
        for event in events where event["type"] as? String == (input == "scroll" ? "wheel" : "pointermove") {
            guard let timestamp = event["timestamp"] as? Double, let received = event["received"] as? Double,
                  let match = sent.filter({ $0["type"] as? String == input }).min(by: {
                      abs(($0["eventEpoch"] as! Double) - timestamp) < abs(($1["eventEpoch"] as! Double) - timestamp)
                  }), abs((match["eventEpoch"] as! Double) - timestamp) < 3 else { unmatched += 1; continue }
            // Date.nowは1ms単位。切捨てによる負の端数は0に丸め、生値はpage/sentへ残す。
            latencies.append(max(0, received - (match["sendEpoch"] as! Double)))
        }
        for transform in page["transforms"] as? [[String: Any]] ?? [] {
            guard let timestamp = transform["inputTimestamp"] as? Double, let received = transform["time"] as? Double,
                  let match = sent.filter({ $0["type"] as? String == input }).min(by: {
                      abs(($0["eventEpoch"] as! Double) - timestamp) < abs(($1["eventEpoch"] as! Double) - timestamp)
                  }), abs((match["eventEpoch"] as! Double) - timestamp) < 3 else { continue }
            transformLatencies.append(max(0, received - (match["sendEpoch"] as! Double)))
        }
        var result: [String: Any] = ["nodes": count, "flowing": flowing, "minimap": map, "layer": layer,
            "input": input, "repeat": repeatIndex, "durationSeconds": duration, "frames": intervals.count,
            "interval": stats(intervals), "slowFrames": intervals.filter { $0 > 25 }.count,
            "delivery": stats(latencies), "matchedEvents": latencies.count, "unmatchedEvents": unmatched,
            "inputToTransform": stats(transformLatencies), "transformCount": transformLatencies.count,
            "deliveryClockResolutionMs": 1,
            "mainQueueDelay": stats(queueDelays), "sendCost": stats(sendCosts), "transcriptCost": stats(updateCosts),
            "transcriptUpdates": updates, "sentEvents": sent.count, "receivedEvents": events.count,
            "maximumFramesPerSecond": screen.maximumFramesPerSecond, "screen": screen.localizedName,
            "backingScaleFactor": controller.window!.backingScaleFactor, "pageZoom": web.pageZoom,
            "webWidth": web.bounds.width, "webHeight": web.bounds.height, "page": page, "sent": sent]
        result["near60FPSPreference"] = near60FPS ?? NSNull() as Any
        result["cpuSeconds"] = cpu
        result["idleCPUSeconds"] = idleCPU
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        result["cpuTimebase"] = ["numer": timebase.numer, "denom": timebase.denom]
        result["screens"] = NSScreen.screens.map { ["name": $0.localizedName, "maximumFramesPerSecond": $0.maximumFramesPerSecond] as [String: Any] }
        result["windowKey"] = controller.window!.isKeyWindow
        result["windowVisible"] = controller.window!.occlusionState.contains(.visible)
        result["trustedEvents"] = events.filter { $0["trusted"] as? Bool == true }.count
        let valid = (input == "idle" ? events.isEmpty && !intervals.isEmpty : !latencies.isEmpty && !transformLatencies.isEmpty)
            && page["canvasCurrent"] as? Bool == true && page["canvasConnected"] as? Bool == true
            && controller.window!.isKeyWindow && events.allSatisfy { $0["trusted"] as? Bool == true }
        result["validInputPath"] = valid
        results.append(result)
        print("計測 \(repeatIndex): \(count) \(flowing ? "発言更新" : "静止") \(map) layer=\(layer) \(input) frames=\(intervals.count) received=\(events.count) matched=\(latencies.count)")
        fflush(stdout)
        guard valid else { throw CocoaError(.coderReadCorrupt) }
    }

    private func utterance(_ index: Int) -> Utterance {
        Utterance(speaker: index % 3, start: Double(index), end: Double(index + 1),
                  text: "使い捨ての発言\(index)。ボードの議論と運用の判断について確認しています。")
    }
    /// 既定は製品の設定。0だけ旧60Hz優先に戻し、1は製品と同じ高更新頻度で比較する。
    private func configureFrameRate(_ preferences: WKPreferences) throws {
        if let flag = environment["KIKIGAKI_BOARD_PERF_HIGH_FPS"] {
            guard ["0", "1"].contains(flag) else { throw CocoaError(.coderInvalidValue) }
            near60FPS = MinutesRenderingPreferences.setNear60FPS(flag == "0", on: preferences)
        } else { near60FPS = MinutesRenderingPreferences.near60FPS(on: preferences) }
        print("WebKit near60FPS=\(String(describing: near60FPS))")
    }

    private func cpuTimes(_ web: WKWebView) -> [String: Double] {
        func seconds(_ pid: pid_t) -> Double? {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            var timebase = mach_timebase_info_data_t()
            guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return nil }
            // pti_total_*はmach tick。Apple Siliconでは1tickが1nsとは限らない。
            return Double(info.pti_total_user + info.pti_total_system) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        }
        var times: [String: Double] = [:]
        times["app"] = seconds(getpid())
        // DEBUG診断だけ。WebContentはXPCプロセスなのでgetrusage(RUSAGE_CHILDREN)では測れない。
        let selector = NSSelectorFromString("_webProcessIdentifier")
        if let method = class_getInstanceMethod(type(of: web), selector), method_getNumberOfArguments(method) == 2 {
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            if String(cString: returnType) == "i" {
                typealias PID = @convention(c) (AnyObject, Selector) -> pid_t
                let get = unsafeBitCast(method_getImplementation(method), to: PID.self)
                times["webContent"] = seconds(get(web, selector))
            }
        }
        return times
    }
    private func cpuDelta(_ before: [String: Double], _ after: [String: Double]) -> [String: Double] {
        var delta: [String: Double] = [:]
        for (name, end) in after { if let start = before[name] { delta[name] = end - start } }
        return delta
    }
    private func send(type: CGEventType, local: NSPoint, delta: Int32 = 0) throws {
        let window = controller.window!
        eventSerial += 1
        // NSEvent(cgEvent:)のwindowNumberは0。sendEventのhit testへ渡す座標は窓内にする。
        let quartz = CGPoint(x: local.x, y: NSScreen.screens[0].frame.maxY - local.y)
        let cg: CGEvent?
        if type == .scrollWheel {
            cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: delta, wheel3: 0)
            cg?.location = quartz
        } else { cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: quartz, mouseButton: .left) }
        guard let cg else { throw CocoaError(.coderInvalidValue) }
        // ファクトリの時刻はWindowServerの最後の入力時刻になる場合がある。各入力に実時刻を付ける。
        cg.timestamp = DispatchTime.now().uptimeNanoseconds
        cg.setIntegerValueField(.mouseEventNumber, value: Int64(eventSerial))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let converted = NSEvent(cgEvent: cg) else { throw CocoaError(.coderInvalidValue) }
        // マウスのwindowNumber=0はAppKitのドラッグ先の選択が不安定になる。
        // 公開のfactoryで窓番号を付け直す。スクロールには同等の公開factoryがない。
        let event: NSEvent
        if type == .scrollWheel { event = converted }
        else {
            guard let attached = NSEvent.mouseEvent(with: converted.type, location: local,
                modifierFlags: converted.modifierFlags, timestamp: converted.timestamp,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventSerial,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { throw CocoaError(.coderInvalidValue) }
            event = attached
        }
        let epoch = Date().timeIntervalSince1970 * 1000
        let eventEpoch = epoch + (event.timestamp - Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000) * 1000
        let start = ProcessInfo.processInfo.systemUptime
        if type == .scrollWheel { window.sendEvent(event) } else { NSApp.sendEvent(event) }
        sendCosts.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        sent.append(["type": type == .scrollWheel ? "scroll" : type == .leftMouseDragged ? "drag" : "button",
                     "sendEpoch": epoch, "eventEpoch": eventEpoch, "windowNumber": event.windowNumber,
                     "x": event.locationInWindow.x, "y": event.locationInWindow.y])
    }
    private func stats(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        return ["mean": values.reduce(0, +) / Double(values.count), "p50": sorted[sorted.count / 2],
                "p95": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "max": sorted.last!]
    }
    private func save() throws {
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"), options: .atomic)
    }
    private func fail(_ message: String) {
        try? save()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        FileHandle.standardError.write(Data("AppKit計測失敗: \(message)\n".utf8)); exit(1)
    }
    func applicationWillTerminate(_ notification: Notification) {
        inputTimer?.cancel(); heartbeat?.cancel(); transcriptTimer?.invalidate()
        controller?.minutesSplit.preview.stop()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
#endif
