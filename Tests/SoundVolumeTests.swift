import Foundation
import Testing
@testable import sarari

/// 効果音の大きさを本体の音量から切り離す計算（Issue #90）。
struct SoundVolumeTests {

    @Test("本体の音量を上げるほど倍率が下がり、聞こえる大きさ（dB）は設定値で一定")
    func louderSystemMeansLowerGain() {
        let target = 0.4
        for system in [0.5, 0.7, 1.0] {
            let gain = Double(SoundVolume.gain(target: target, system: system))
            let heard = (system - 1) * SoundVolume.dynamicRange + 20 * log10(gain)
            #expect(abs(heard - (target - 1) * SoundVolume.dynamicRange) < 0.01)
        }
        #expect(SoundVolume.gain(target: target, system: 1.0) < SoundVolume.gain(target: target, system: 0.5))
    }

    @Test("本体の音量が設定値以下なら上げられないので倍率 1")
    func quietSystemIsNotBoosted() {
        #expect(SoundVolume.gain(target: 0.4, system: 0.4) == 1)
        #expect(SoundVolume.gain(target: 0.4, system: 0.1) == 1)
    }

    @Test("設定 0 は無音、本体の音量が読めないときは設定値をそのまま使う")
    func edges() {
        #expect(SoundVolume.gain(target: 0, system: 1) == 0)
        #expect(SoundVolume.gain(target: 0.6, system: nil) == Float(0.6))
        #expect(SoundVolume.gain(target: 1, system: 1) == 1)
    }
}
