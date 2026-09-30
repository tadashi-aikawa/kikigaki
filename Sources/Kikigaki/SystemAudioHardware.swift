import CoreAudio
import Foundation
import IOKit.audio
import KikigakiCore

struct SystemAudioError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// 読取だけを提供する。物理デバイスのレート・音量・既定値を書き換える口は持たない。
enum SystemAudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status == kAudioDevicePermissionsError {
            throw SystemAudioError(reason: "\(operation)が許可されていません。システム設定のプライバシーとセキュリティでKIKIGAKIの許可を確認してください")
        }
        guard status == noErr else { throw SystemAudioError(reason: "\(operation)に失敗しました (OSStatus \(status))") }
    }
    static func requireMicrophone() throws {
        let id = try read(system, kAudioHardwarePropertyDefaultInputDevice, UInt32(0))
        guard id != 0, try read(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) != 0,
              try streams(id, scope: kAudioObjectPropertyScopeInput).contains(where: { $0.format.mChannelsPerFrame > 0 && $0.format.mSampleRate > 0 }) else {
            throw SystemAudioError(reason: "既定マイクがまだ接続されていません")
        }
    }
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var value = initial, address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }, "音声デバイス情報の取得")
        return value
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString = "" as CFString
        var address = address(selector), size = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }, "音声デバイス識別子の取得")
        return value as String
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
        var address = address(selector, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "音声デバイス配列の取得")
        guard size > 0 else { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / 4)
        try check(values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
        }, "音声デバイス配列の取得")
        return values
    }
    struct Stream {
        let start: Int
        let format: AudioStreamBasicDescription
        var end: Int { start + Int(format.mChannelsPerFrame) }
    }
    static func streams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Stream] {
        try ids(id, kAudioDevicePropertyStreams, scope: scope).map {
            Stream(start: Int(try read($0, kAudioStreamPropertyStartingChannel, UInt32(0))) - 1,
                   format: try read($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()))
        }.sorted { $0.start < $1.start }
    }
    static func ownProcess() throws -> AudioObjectID {
        var pid = getpid(), value: AudioObjectID = 0
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &value), "自プロセスの音声ID取得")
        guard value != 0 else { throw SystemAudioError(reason: "自プロセスの音声IDを取得できません") }
        return value
    }
}

enum SystemAudioOutput {
    static func classify(transport: UInt32, terminals: [UInt32], sources: [UInt32], kinds: [UInt32]) -> AudioOutputKind {
        if terminals.contains(kAudioStreamTerminalTypeHeadphones) || terminals.contains(UInt32(OUTPUT_HEADPHONES))
            || terminals.contains(UInt32(BIDIRECTIONAL_HEADSET)) || kinds.contains(kAudioStreamTerminalTypeHeadphones)
            || sources.contains(UInt32(kIOAudioSelectorControlSelectionValueHeadphones)) { return .headphones }
        if transport == kAudioDeviceTransportTypeBuiltIn
            && (sources.contains(UInt32(kIOAudioSelectorControlSelectionValueInternalSpeaker))
                || terminals.contains(kAudioStreamTerminalTypeSpeaker) || terminals.contains(UInt32(OUTPUT_SPEAKER))) {
            return .builtInSpeaker
        }
        // USBやBluetoothの接続方式と製品名だけでは、先のスピーカーとイヤホンを区別できない。
        return .unknown
    }
    static func current() -> AudioOutputKind {
        do {
            let id = try SystemAudioHAL.read(SystemAudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice, UInt32(0))
            let streams = try SystemAudioHAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            let terminals = streams.compactMap { try? SystemAudioHAL.read($0, kAudioStreamPropertyTerminalType, UInt32(0)) }
            let sources = (try? SystemAudioHAL.ids(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)) ?? []
            let kinds = sources.compactMap { source -> UInt32? in
                var source = source, result: UInt32 = 0
                return withUnsafeMutablePointer(to: &source) { input in
                    withUnsafeMutablePointer(to: &result) { output in
                        var translation = AudioValueTranslation(mInputData: input, mInputDataSize: 4, mOutputData: output, mOutputDataSize: 4)
                        var address = SystemAudioHAL.address(kAudioDevicePropertyDataSourceKindForID, kAudioObjectPropertyScopeOutput)
                        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &translation) == noErr ? output.pointee : nil
                    }
                }
            }
            return classify(transport: try SystemAudioHAL.read(id, kAudioDevicePropertyTransportType, UInt32(0)),
                            terminals: terminals, sources: sources, kinds: kinds)
        } catch { return .unknown }
    }
}
