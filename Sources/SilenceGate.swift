import Foundation

/// 録音の音量を 0…1 に写す。HUD の棒と無音の判定が同じ尺度を使う（Issue #122）。
enum AudioLevel {
    /// RMS を -50dB…0dB で 0…1 に写す。
    /// 線形のままだと通常の発話がほぼ潰れて波形が動いて見えない。
    ///
    /// **通常の発話は、写した値で 0.1〜0.3（RMS でおよそ 0.006〜0.016）**。履歴の録音 619 件を
    /// 実測した値（声の窓の p25 0.11 / p50 0.16 / p95 0.28、Issue #187）。
    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let floorDB: Float = -50
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, (db - floorDB) / -floorDB)
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}

/// 何も話さずに止めた録音を、音声認識に渡す前に弾く（Issue #122）。
///
/// WhisperKit は無音に「ご視聴ありがとうございました」のような定型文を返すことがある。
/// エンジンの振る舞いに頼らず、**音量だけで**「話していない」と分かる録音はエンジンに渡さない。
///
/// 判定は**話した側に倒す**。取り違えて発話を捨てる方が、定型文が入るより悪いので、
/// 閾値は普通の声の下端（写した値 0.1 前後）より十分に低く置く。
enum SilenceGate {
    static let sampleRate = 16_000
    /// 判定の窓。HUD の棒と同じ 20fps（50ms）。
    static let windowSamples = sampleRate / 20
    /// 声とみなす窓の音量（写した値）。-47dB、RMS でおよそ 0.0045。
    static let voicedLevel: Float = 0.06
    /// 声とみなす窓がこれだけ（100ms ぶん）あれば話したとみなす。机を叩いた音 1 つでは足りない。
    static let minimumVoicedWindows = 2

    /// 先頭 `seconds` を 0 に潰す。開始音はマイクが録っている最中に鳴るので、
    /// その区間を判定にもエンジンにも入れない（長さは変えない）。
    ///
    /// 音量だけでは「開始音だけ」と「開始音に重ねて話した声」を見分けられないので、
    /// 開始音が鳴り終わる前に話し終えて止めた録音は無音として扱われる。開始音の後まで声が続けば渡る。
    static func muteLeading(_ samples: [Float], seconds: TimeInterval) -> [Float] {
        let count = min(samples.count, Int((seconds * Double(sampleRate)).rounded(.up)))
        guard count > 0 else { return samples }
        var muted = samples
        muted.replaceSubrange(0..<count, with: repeatElement(0, count: count))
        return muted
    }

    /// 声とみなせる窓の数。
    static func voicedWindows(_ samples: [Float]) -> Int {
        stride(from: 0, to: samples.count, by: windowSamples).reduce(0) { count, start in
            let window = samples[start..<min(start + windowSamples, samples.count)]
            return AudioLevel.normalized(rms: AudioLevel.rms(window)) >= voicedLevel ? count + 1 : count
        }
    }

    static func isSilent(_ samples: [Float]) -> Bool {
        voicedWindows(samples) < minimumVoicedWindows
    }
}
