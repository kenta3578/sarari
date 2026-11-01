import Combine
import CoreAudio
import Foundation

/// 録音に使える入力デバイス（Issue #140）。
struct InputDevice: Identifiable, Hashable, Sendable {
    /// 保存に使う。`AudioDeviceID` は再接続や再起動で変わるので保存しない。
    let uid: String
    let name: String
    var id: String { uid }
}

/// CoreAudio から入力デバイスを引く。
enum InputDevices {
    /// 今つながっている入力デバイス（入力チャンネルを持つものだけ）。
    nonisolated static func all() -> [InputDevice] {
        deviceIDs().compactMap { id in
            guard hasInput(id), let uid = uid(of: id), let name = name(of: id) else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    /// UID から今の `AudioDeviceID` を引く。つながっていない・入力を持たないなら nil。
    nonisolated static func deviceID(uid: String) -> AudioDeviceID? {
        deviceIDs().first { self.uid(of: $0) == uid && hasInput($0) }
    }

    /// システムの既定の入力デバイス。
    nonisolated static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    // MARK: CoreAudio

    private nonisolated static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private nonisolated static func uid(of id: AudioDeviceID) -> String? {
        string(kAudioDevicePropertyDeviceUID, of: id)
    }

    private nonisolated static func name(of id: AudioDeviceID) -> String? {
        string(kAudioObjectPropertyName, of: id)
    }

    private nonisolated static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// 設定画面の選択肢。デバイスの抜き差しで作り直す。
///
/// 設定画面の `.onDisappear` はウィンドウを閉じても発火しないので（SettingsView 参照）、
/// 監視は画面に結びつけず 1 つだけ持ち続ける。
@MainActor
final class InputDeviceList: ObservableObject {
    static let shared = InputDeviceList()

    @Published private(set) var devices: [InputDevice] = InputDevices.all()

    private init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // ブロックは main キューで呼ばれる。
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devices = InputDevices.all() }
        }
    }
}
