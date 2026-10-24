import AudioToolbox
import CoreAudio

/// 効果音の大きさを Mac 本体の音量から切り離す（Issue #90）。
///
/// `NSSound.volume` は本体の出力音量に掛かる倍率なので、そのままだと本体を上げれば効果音も上がる。
/// 鳴らす直前に本体の音量を読み、聞こえる大きさが設定値になるよう倍率を下げて補う。
/// 本体の音量が設定値より小さいときは上げられないので、倍率 1（本体の音量のまま）で鳴る。
enum SoundVolume {
    /// 本体の音量スライダー（0〜1）を dB に見なす幅。macOS の音量カーブはおおむね dB で等間隔なので、
    /// スライダーの 0〜1 を -dynamicRange〜0 dB に線形に対応させて近似する。
    nonisolated static let dynamicRange: Double = 40

    /// 設定値 `target`（0〜1、本体の音量スライダーと同じ尺度）で聞こえるための `NSSound.volume`。
    /// `system` は本体の出力音量（0〜1）。読めなかったとき（nil）は補正せず `target` をそのまま使う。
    nonisolated static func gain(target: Double, system: Double?) -> Float {
        let target = min(max(target, 0), 1)
        guard target > 0 else { return 0 }
        guard let system else { return Float(target) }
        let current = min(max(system, 0), 1)
        guard current > target else { return 1 }   // 本体のほうが小さい → これ以上は上げられない
        let db = (target - current) * dynamicRange  // 負の値（下げる量）
        return Float(pow(10, db / 20))
    }

    /// 既定の出力装置の音量（0〜1）。音量を持たない装置（HDMI の一部など）は nil。
    nonisolated static func systemOutputVolume() -> Double? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }

        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
        else { return nil }
        return Double(volume)
    }
}
