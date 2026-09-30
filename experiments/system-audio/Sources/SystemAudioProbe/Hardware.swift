import CoreAudio
import Foundation
import IOKit.audio

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ProbeError("\(operation): OSStatus=\(status) [\(fourCC(UInt32(bitPattern: status)))]") }
}

func fourCC(_ value: UInt32) -> String {
    let bytes = (0..<4).map { UInt8((value >> (24 - 8 * $0)) & 255) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        ? String(bytes: bytes, encoding: .ascii)! : String(value)
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var value = initial
        var address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        // Only fixed-size HAL value types call this helper; CF objects use string().
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }, "read \(id).\(fourCC(selector))")
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString = "" as CFString
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }, "read string \(id).\(fourCC(selector))")
        return value as String
    }

    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "array size")
        guard size > 0 else { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        try check(values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
        }, "array read")
        return values
    }

    static func selfProcess() throws -> AudioObjectID {
        // Qualifier: POSIX PID. Result: HAL process object ID, NOT a PID.
        let result = try process(pid: getpid())
        guard result != kAudioObjectUnknown else { throw ProbeError("自プロセスのHAL IDを取得できません") }
        return result
    }

    static func process(pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &result), "translate self PID")
        return result
    }

    static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Stream] {
        try ids(device, kAudioDevicePropertyStreams, scope: scope).map { id in
            Stream(id: id,
                   start: Int(try read(id, kAudioStreamPropertyStartingChannel, UInt32(0))) - 1,
                   format: try read(id, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()))
        }.sorted { $0.start < $1.start }
    }

    static func printProcesses() throws {
        for id in try ids(system, kAudioHardwarePropertyProcessObjectList) {
            let pid = try read(id, kAudioProcessPropertyPID, pid_t(0))
            let bundle = (try? string(id, kAudioProcessPropertyBundleID)) ?? "unknown"
            let output = try read(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))
            print("HAL process=\(id) pid=\(pid) bundle=\(bundle) runningOutput=\(output)")
        }
    }
}

struct Stream {
    let id: AudioObjectID
    let start: Int
    let format: AudioStreamBasicDescription
    var end: Int { start + Int(format.mChannelsPerFrame) }
}

struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let terminals: [UInt32]
    let sources: [UInt32]
    let sourceKinds: [UInt32]

    static func current() throws -> OutputDevice {
        let id = try HAL.read(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, UInt32(0))
        let streams = try HAL.streams(id, scope: kAudioObjectPropertyScopeOutput)
        let terminals = streams.compactMap { try? HAL.read($0.id, kAudioStreamPropertyTerminalType, UInt32(0)) }
        let sources = (try? HAL.ids(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)) ?? []
        let kinds = sources.compactMap { source -> UInt32? in
            var source = source
            var result: UInt32 = 0
            return withUnsafeMutablePointer(to: &source) { input in
                withUnsafeMutablePointer(to: &result) { output in
                    var translation = AudioValueTranslation(mInputData: input, mInputDataSize: 4,
                                                            mOutputData: output, mOutputDataSize: 4)
                    var address = HAL.address(kAudioDevicePropertyDataSourceKindForID, kAudioObjectPropertyScopeOutput)
                    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &translation)
                    return status == noErr ? output.pointee : nil
                }
            }
        }
        return OutputDevice(id: id, uid: try HAL.string(id, kAudioDevicePropertyDeviceUID),
                            name: try HAL.string(id, kAudioObjectPropertyName),
                            transport: try HAL.read(id, kAudioDevicePropertyTransportType, UInt32(0)),
                            terminals: terminals, sources: sources, sourceKinds: kinds)
    }

    var classification: String {
        if terminals.contains(kAudioStreamTerminalTypeHeadphones) || terminals.contains(UInt32(OUTPUT_HEADPHONES))
            || terminals.contains(UInt32(BIDIRECTIONAL_HEADSET))
            || sourceKinds.contains(kAudioStreamTerminalTypeHeadphones)
            || sources.contains(UInt32(kIOAudioSelectorControlSelectionValueHeadphones)) {
            return "headphones"
        }
        if transport == kAudioDeviceTransportTypeBuiltIn
            && (sources.contains(UInt32(kIOAudioSelectorControlSelectionValueInternalSpeaker))
                || terminals.contains(kAudioStreamTerminalTypeSpeaker) || terminals.contains(UInt32(OUTPUT_SPEAKER))) {
            return "built-in-speaker"
        }
        // Transport identifies a connection, not the acoustic endpoint.
        // Bluetooth speakers and USB interfaces must not be assumed to be headphones.
        return "unknown"
    }

    var signature: String { "\(uid):\(sources):\(terminals):\(sourceKinds)" }
    var summary: String {
        "output=\(name) id=\(id) transport=\(fourCC(transport)) class=\(classification) " +
        "terminals=\(terminals.map(fourCC)) dataSources=\(sources.map(fourCC)) sourceKinds=\(sourceKinds.map(fourCC))"
    }
}

var captureLog: FileHandle?

func log(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
    captureLog?.write(data)
}
