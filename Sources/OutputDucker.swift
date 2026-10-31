import AudioToolbox
import CoreAudio
import Foundation

/// 出力装置の音量の読み書き。装置は UID で指す（再起動をまたいでも同じ装置を指せるように）。
protocol OutputVolumeControl {
    /// 既定の出力装置の UID。取れなければ nil。
    func defaultOutputUID() -> String?
    /// 音量（0〜1）。音量を持たない装置・見つからない装置は nil。
    func volume(of uid: String) -> Double?
    /// 音量を書く。書けなかったら false。
    func setVolume(_ volume: Double, of uid: String) -> Bool
}

/// 下げる前の音量の控え。下げたまま落ちたとき、次の起動で戻すために残しておく。
protocol DuckRecordStore {
    func load() -> OutputDucker.Record?
    func save(_ record: OutputDucker.Record?)
}

/// 録音中だけ Mac 本体の出力音量を 0 にし、終わったら戻す（Issue #133）。
///
/// #88 は再生/一時停止キーを送って音楽を止めていたが、キーに反応しないアプリ（環境音など）は
/// 止まらず、別のアプリが鳴っていると止まっていた音楽を鳴らしてしまった（#124）。
/// 音量ならどのアプリの音にも効き、トグルでもないので逆に鳴らすことがない。
@MainActor
final class OutputDucker {
    struct Record: Equatable {
        /// 下げた装置。録音中に出力先が変わっても、下げた装置を戻す。
        var uid: String
        /// 下げる前の音量。
        var original: Double
    }

    /// これ以下なら「自分が下げたまま」とみなす。録音中に本人が音量を上げていたら戻さない。
    nonisolated static let silentThreshold = 0.001

    private let control: OutputVolumeControl
    private let store: DuckRecordStore
    private let isEnabled: () -> Bool
    private var lowered: Record?
    private var pendingLower: Task<Void, Never>?

    init(control: OutputVolumeControl = CoreAudioOutputVolume(),
         store: DuckRecordStore = UserDefaultsDuckRecordStore(),
         isEnabled: @escaping () -> Bool = { SettingsStore.shared.lowerVolumeWhileRecording }) {
        self.control = control
        self.store = store
        self.isEnabled = isEnabled
    }

    /// 録音開始時に呼ぶ。`delay` 秒後（開始音が鳴り終わってから）下げる。
    /// 下げる前に `restore()` が呼ばれたら下げない。
    func lower(after delay: TimeInterval) {
        pendingLower?.cancel()
        guard isEnabled() else { return }
        guard delay > 0 else { lowerNow(); return }
        pendingLower = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.lowerNow()
        }
    }

    /// すぐ下げる。すでに下げているとき・もともと無音のときは何もしない。
    func lowerNow() {
        pendingLower = nil
        guard lowered == nil,
              let uid = control.defaultOutputUID(),
              let current = control.volume(of: uid),
              current > Self.silentThreshold else { return }
        let record = Record(uid: uid, original: current)
        // 先に控えを残す。書いた直後に落ちても次の起動で戻せる。
        store.save(record)
        guard control.setVolume(0, of: uid) else {
            store.save(nil)
            return
        }
        lowered = record
        Log.audio.info("録音中は音量を下げます")
    }

    /// 録音の停止・破棄・開始失敗のときに呼ぶ。停止音より**前**に呼ぶこと（下げたままだと聞こえない）。
    func restore() {
        pendingLower?.cancel()
        pendingLower = nil
        guard let record = lowered else { return }
        lowered = nil
        put(back: record)
    }

    /// 起動時に呼ぶ。前回、下げたまま終わっていたら戻す。
    func recoverIfNeeded() {
        guard lowered == nil, let record = store.load() else { return }
        put(back: record)
    }

    private func put(back record: Record) {
        store.save(nil)
        // 本人が録音中に音量を変えていたら、その音量を優先する。
        guard let current = control.volume(of: record.uid),
              current <= Self.silentThreshold else { return }
        if control.setVolume(record.original, of: record.uid) {
            Log.audio.info("音量を元に戻しました")
        }
    }
}

// MARK: - 実装

/// 控えは UserDefaults に置く（数値と装置の UID だけ）。
struct UserDefaultsDuckRecordStore: DuckRecordStore {
    private let uidKey = "duckedOutputUID"
    private let volumeKey = "duckedOriginalVolume"

    func load() -> OutputDucker.Record? {
        let defaults = UserDefaults.standard
        guard let uid = defaults.string(forKey: uidKey),
              let original = defaults.object(forKey: volumeKey) as? Double else { return nil }
        return .init(uid: uid, original: original)
    }

    func save(_ record: OutputDucker.Record?) {
        let defaults = UserDefaults.standard
        if let record {
            defaults.set(record.uid, forKey: uidKey)
            defaults.set(record.original, forKey: volumeKey)
        } else {
            defaults.removeObject(forKey: uidKey)
            defaults.removeObject(forKey: volumeKey)
        }
    }
}

/// CoreAudio で既定の出力装置の音量（`VirtualMainVolume`＝音量スライダーと同じ値）を読み書きする。
struct CoreAudioOutputVolume: OutputVolumeControl {
    func defaultOutputUID() -> String? {
        Self.defaultOutputDevice().flatMap(Self.uid(of:))
    }

    func volume(of uid: String) -> Double? {
        guard let device = Self.device(uid: uid) else { return nil }
        return Self.volume(of: device)
    }

    func setVolume(_ volume: Double, of uid: String) -> Bool {
        guard let device = Self.device(uid: uid) else { return false }
        var address = Self.volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = Float32(min(max(volume, 0), 1))
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    // MARK: CoreAudio

    nonisolated static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    nonisolated static func volume(of device: AudioObjectID) -> Double? {
        var address = volumeAddress
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
        else { return nil }
        return Double(volume)
    }

    private nonisolated static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
