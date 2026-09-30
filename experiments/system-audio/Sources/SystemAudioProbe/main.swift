import AVFoundation
import AppKit
import CoreAudio
import Foundation

let usage = """
SystemAudioProbe devices
SystemAudioProbe processes
SystemAudioProbe self-check
SystemAudioProbe inspect <wav>
SystemAudioProbe lag <system.wav> <mic.wav>
SystemAudioProbe record --seconds <1...120> --out <new-directory> [--mic] [--play <wav>] [--play-only]

recordはシステム音声をsystem.wavへ保存します。
--micはmic.wavとmixed.wavも保存します。全て16kHz mono Float32。
--playは取り込み開始後にafplayで再生します。必要秒数は音声長+1秒以上。
--play-onlyはafplayだけを取得します。先頭に5秒の無音を足し、再生開始後にタップを作ります。
--play-onlyの録音時間は元の音声長+6秒以上が必要です。
出力先の既存WAVは上書きしません。全ゼロのsystem.wavは終了コード3。
"""

func run() throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { print(usage); return 0 }
    if command == "--help" || command == "help" { print(usage); return 0 }
    if command == "self-check", args.count == 1 { try runSelfChecks(); return 0 }
    if command == "devices" {
        print(try OutputDevice.current().summary)
        let input = try HAL.read(HAL.system, kAudioHardwarePropertyDefaultInputDevice, UInt32(0))
        print("input=\(try HAL.string(input, kAudioObjectPropertyName)) id=\(input) nominalRate=\(try HAL.read(input, kAudioDevicePropertyNominalSampleRate, Double(0)))")
        return 0
    }
    if command == "processes", args.count == 1 { try HAL.printProcesses(); return 0 }
    if command == "inspect", args.count == 2 { try Wave.inspect(URL(fileURLWithPath: args[1])); return 0 }
    if command == "lag", args.count == 3 {
        try Lag.run(system: URL(fileURLWithPath: args[1]), mic: URL(fileURLWithPath: args[2])); return 0
    }
    guard command == "record" else { throw ProbeError(usage) }
    var seconds: Double?
    var output: String?
    var play: String?
    var mic = false
    var playOnly = false
    var index = 1
    while index < args.count {
        let option = args[index]
        if option == "--mic" { mic = true; index += 1; continue }
        if option == "--play-only" { playOnly = true; index += 1; continue }
        guard index + 1 < args.count else { throw ProbeError("\(option)の値がありません") }
        switch option {
        case "--seconds": seconds = Double(args[index + 1])
        case "--out": output = args[index + 1]
        case "--play": play = args[index + 1]
        default: throw ProbeError("不明な引数: \(option)")
        }
        index += 2
    }
    guard let seconds, seconds.isFinite, seconds >= 1, seconds <= 120, let output else { throw ProbeError(usage) }
    guard !playOnly || play != nil else { throw ProbeError("--play-onlyには--playが必要です") }
    if let play, !FileManager.default.isReadableFile(atPath: play) { throw ProbeError("再生音声を読めません: \(play)") }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["system.wav", "mic.wav", "mixed.wav", "capture.log", "playback.wav"] {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw ProbeError("既存WAVがあります。新しい出力先を指定してください: \(name)")
        }
    }
    let logURL = directory.appendingPathComponent("capture.log")
    guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw ProbeError("ログを作成できません") }
    captureLog = try FileHandle(forWritingTo: logURL)
    log("pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "none") bundlePath=\(Bundle.main.bundleURL.path)")
    // LaunchServices-launched .app remains a separate TCC subject. Merely executing
    // Contents/MacOS from a terminal does not guarantee attribution to that .app.
    if Bundle.main.bundleURL.pathExtension == "app" { _ = NSApplication.shared }
    if mic { try ensureMicrophonePermission() }
    var outputDevice = try OutputDevice.current()
    log(outputDevice.summary)
    let recorder = Recorder()
    defer { recorder.stop() }
    let player = Process()
    defer { if player.isRunning { player.terminate(); player.waitUntilExit() } }
    var playerLaunchHost: UInt64?
    var includedProcess: UInt32?
    if playOnly, let play {
        let source = try Wave.readMono16k(URL(fileURLWithPath: play))
        guard seconds >= Double(source.count) / 16000 + 6 else {
            throw ProbeError("--play-onlyは原音全体を保つため、元の音声長+6秒以上で録音してください")
        }
        let padded = directory.appendingPathComponent("playback.wav")
        try Wave.write(Wave.paddedPlayback(source, paddingSeconds: 5), to: padded)
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [padded.path]
        log("play-only paddingSeconds=5 sourceSeconds=\(Double(source.count) / 16000)")
        playerLaunchHost = mach_absolute_time()
        try player.run()
        log("afplay pid=\(player.processIdentifier) file=\(padded.path)")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var firstLookup = true
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard player.isRunning else { throw ProbeError("タップ作成前にafplayが終了しました") }
            let id = try HAL.process(pid: player.processIdentifier)
            if firstLookup { log("afplay first HAL lookup=\(id)"); firstLookup = false }
            if id != 0 { includedProcess = id; break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard let includedProcess else { throw ProbeError("再生プロセスが3秒以内にHALへ登録されませんでした") }
        log("afplay registered HAL process=\(includedProcess)")
    }
    try recorder.prepare(seconds: seconds, withMic: mic, includedProcess: includedProcess)
    try recorder.start()
    let start = ProcessInfo.processInfo.systemUptime
    if !playOnly, let play {
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [play]
        try player.run()
        log("afplay pid=\(player.processIdentifier) file=\(play)")
    }
    while ProcessInfo.processInfo.systemUptime - start < seconds {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let next = try OutputDevice.current()
        if next.signature != outputDevice.signature {
            log("output changed elapsed=\(ProcessInfo.processInfo.systemUptime - start) \(next.summary)")
            outputDevice = next
        }
    }
    if player.isRunning {
        log("afplay still running at recording end")
        player.terminate(); player.waitUntilExit()
    }
    if play != nil { log("afplay terminationStatus=\(player.terminationStatus)") }
    recorder.stop()
    if let launch = playerLaunchHost, let first = recorder.memory?.firstHost {
        let delta = first >= launch ? AVAudioTime.seconds(forHostTime: first - launch)
                                   : -AVAudioTime.seconds(forHostTime: launch - first)
        let missing = max(0, delta - 5) * 1000
        log("play-only captureStartAfterLaunchSeconds=\(delta) sourcePrefixMissingUpperBoundMs=\(missing)")
        guard missing == 0 else { throw ProbeError("前置き5秒を超えて開始が遅れました。原音の欠けを否定できないため比較を止めます") }
    }
    let nonzero = try recorder.save(to: directory, withMic: mic, seconds: seconds)
    if !nonzero {
        log("SYSTEM SILENT: 全ゼロです。既知の音声を再生していたなら許可待ちの可能性があります。回避せず停止してください。無音だけではTCC拒否と断定できません。")
        return 3
    }
    return 0
}

do {
    let status = try run()
    try? captureLog?.close()
    exit(status)
} catch {
    log("ERROR: \(error)")
    try? captureLog?.close()
    exit(1)
}
