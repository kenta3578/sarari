import CoreAudio
import IOKit

/// 録音に使うマイク（Issue #94）。
struct InputDevice: Equatable {
    let id: AudioDeviceID
    /// 公称サンプルレート。AirPods のように同じ機器のままレートだけ変わる（48kHz ⇄ 16kHz）
    /// こともあるので、機器の比較に含める（Issue #91）。
    let sampleRate: Float64
    /// 既定のマイクではなく、こちらから指定した機器か。
    let isPinned: Bool
}

/// 録音に使うマイクを決める。
///
/// **既定のマイクが Bluetooth のときは内蔵マイクで録る。** Bluetooth のヘッドホンはマイクを
/// 開いた瞬間に通話モード（HFP、16kHz）へ切り替わり、そのあいだ音楽も効果音も通話用の経路に
/// 回って聞こえなくなる。切り替えで構成変更の通知も飛ぶので、録音が 0.25 秒で切れていた。
enum InputDeviceSelector {
    enum Transport: Equatable {
        case bluetooth
        case other
    }

    /// 内蔵マイクへ差し替えるか。差し替えないときは既定のマイクをそのまま使う。
    ///
    /// 蓋を閉じているあいだ内蔵マイクは無音になるので、そのときは差し替えない。
    nonisolated static func shouldUseBuiltIn(defaultTransport: Transport,
                                             builtInAvailable: Bool,
                                             lidClosed: Bool) -> Bool {
        defaultTransport == .bluetooth && builtInAvailable && !lidClosed
    }

    /// 今の状況で録音に使う機器。既定のマイクが取れなければ nil。
    static func current() -> InputDevice? {
        guard let defaultID = defaultInputID() else { return nil }
        let builtIn = builtInInputID()
        let pin = shouldUseBuiltIn(
            defaultTransport: isBluetooth(defaultID) ? .bluetooth : .other,
            builtInAvailable: builtIn != nil,
            lidClosed: isLidClosed()
        )
        let id = pin ? builtIn! : defaultID
        guard let rate: Float64 = property(id, kAudioDevicePropertyNominalSampleRate) else { return nil }
        return InputDevice(id: id, sampleRate: rate, isPinned: pin)
    }

    // MARK: - CoreAudio

    private static func defaultInputID() -> AudioDeviceID? {
        guard let id: AudioDeviceID = property(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
            id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        guard let transport: UInt32 = property(id, kAudioDevicePropertyTransportType) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// 入力を持つ内蔵の機器（MacBook の内蔵マイク）。デスクトップの Mac など、無ければ nil。
    private static func builtInInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }

        return ids.first { id in
            guard let transport: UInt32 = property(id, kAudioDevicePropertyTransportType),
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    // MARK: - 蓋

    /// MacBook の蓋が閉じているか。取れなければ（デスクトップの Mac など）false。
    private static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }
}
