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
    /// `AudioRecorder` が作る形式（WhisperKit の入力の決まり）。
    static let sampleRate = 16_000
    /// 判定の窓。HUD の棒と同じ 20fps（50ms）。
    static let windowSamples = sampleRate / 20
    /// 声とみなす窓の音量（写した値）。-47dB、RMS でおよそ 0.0045。
    static let voicedLevel: Float = 0.06
    /// 声とみなす窓が**続けて**これだけ（150ms）あれば話したとみなす。
    /// 20ms ほどの机やキーを叩いた音は、窓の区切りをまたいでも続けて 2 つまでにしかならない。
    /// 150ms の声は区切りの位置によらず 3 つ続く（端の窓の片方は半分以上埋まる）。
    static let minimumVoicedRun = 3

    /// 開始音の長さに足す余裕。HUD の棒を隠す余裕（0.25 秒）より広い。Bluetooth のヘッドホンでは
    /// 開始音が 150〜300ms 遅れて鳴るので、その末尾まで判定から外す。
    static let startSoundMargin: TimeInterval = 0.5

    /// 判定から外す先頭の長さ。開始音を鳴らさなかったら 0。
    static func excludedSeconds(forSoundOf duration: TimeInterval) -> TimeInterval {
        duration > 0 ? duration + startSoundMargin : 0
    }

    /// 先頭 `seconds`（開始音の区間）を除いて、声とみなせる窓が続いた最長の数。
    ///
    /// 開始音の区間は**判定から外すだけ**で、エンジンへはそのまま渡す。渡す音から消すと、
    /// 開始音に重ねて話した声の頭が欠ける。音量だけでは「開始音だけ」と「開始音に重ねた声」を
    /// 見分けられないので、開始音が鳴り終わる前に話し終えて止めた録音は無音として扱われる。
    static func longestVoicedRun(_ samples: [Float], ignoringLeading seconds: TimeInterval = 0) -> Int {
        let first = min(samples.count, Int((seconds * Double(sampleRate)).rounded(.up)))
        var longest = 0
        var current = 0
        for start in stride(from: first, to: samples.count, by: windowSamples) {
            let window = samples[start..<min(start + windowSamples, samples.count)]
            if AudioLevel.normalized(rms: AudioLevel.rms(window)) >= voicedLevel {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
