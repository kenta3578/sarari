import Foundation

/// テスト用の音（16kHz / mono / Float32）。
enum SignalFixtures {
    static let sampleRate = 16_000

    /// 220Hz の正弦波。振幅 0.05 で RMS ≒ 0.035（普通の声より少し大きい）。
    static func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * 220 * Double(i) / Double(sampleRate)))
        }
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    /// 静かな部屋の床ノイズ（±0.001 の一様乱数。-65dB 前後）。種を固定して毎回同じにする。
    static func roomNoise(seconds: Double) -> [Float] {
        var state: UInt64 = 0x2545F4914F6CDD1D
        return (0..<Int(seconds * Double(sampleRate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)   // 0…1
            return (unit * 2 - 1) * 0.001
        }
    }
}
