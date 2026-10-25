import Foundation
import os
import Testing
@testable import sarari

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

/// 何も話さずに止めたら、エンジンに関わらず何も入れない（Issue #122）。
/// WhisperKit は無音に「ご視聴ありがとうございました」のような定型文を返すことがあるので、
/// **エンジンに渡す前に**弾く。
struct SilenceGateTests {

    /// 渡されたサンプルを控え、無音に定型文を返す WhisperKit を真似るエンジン。
    private struct SpyEngine: SpeechEngine {
        let received = OSAllocatedUnfairLock<[[Float]]>(initialState: [])
        var text = "ご視聴ありがとうございました"
        func load() async throws {}
        func unload() async {}
        func transcribe(_ samples: [Float]) async throws -> String {
            received.withLock { $0.append(samples) }
            return text
        }
        var callCount: Int { received.withLock { $0.count } }
    }

    private func run(_ samples: [Float], engine: SpyEngine,
                     leadingSoundSeconds: TimeInterval = 0) async throws -> DictationPipeline.Output {
        try await DictationPipeline.run(
            samples: samples, engine: engine, rules: [], fillers: .default,
            leadingSoundSeconds: leadingSoundSeconds)
    }

    @Test("無音（全部 0）はエンジンに渡さず、空を返す")
    func digitalSilenceSkipsEngine() async throws {
        let engine = SpyEngine()
        let output = try await run(SignalFixtures.silence(seconds: 2), engine: engine)
        #expect(engine.callCount == 0)
        #expect(output.rawText.isEmpty)
        #expect(output.replacedText.isEmpty)
    }

    @Test("静かな部屋の床ノイズだけなら無音として扱う")
    func roomNoiseIsSilence() async throws {
        let engine = SpyEngine()
        let output = try await run(SignalFixtures.roomNoise(seconds: 2), engine: engine)
        #expect(engine.callCount == 0)
        #expect(output.replacedText.isEmpty)
    }

    @Test("録音 0 件（押してすぐ止めた）も無音として扱う")
    func emptySamplesAreSilence() async throws {
        let engine = SpyEngine()
        let output = try await run([], engine: engine)
        #expect(engine.callCount == 0)
        #expect(output.replacedText.isEmpty)
    }

    @Test("机を叩いた程度の短い音（20ms）だけなら無音として扱う")
    func shortClickIsSilence() async throws {
        let engine = SpyEngine()
        let samples = SignalFixtures.silence(seconds: 1)
            + SignalFixtures.tone(seconds: 0.02, amplitude: 0.3)
            + SignalFixtures.silence(seconds: 1)
        _ = try await run(samples, engine: engine)
        #expect(engine.callCount == 0)
    }

    @Test("開始音だけが入った録音は無音として扱う（開始音の区間は判定に入れない）")
    func startSoundOnlyIsSilence() async throws {
        let engine = SpyEngine()
        // 開始音（0.3 秒の大きな音）が鳴り、そのあと何も話さない。
        let samples = SignalFixtures.tone(seconds: 0.3, amplitude: 0.2)
            + SignalFixtures.silence(seconds: 1.5)
        let output = try await run(samples, engine: engine, leadingSoundSeconds: 0.46)
        #expect(engine.callCount == 0)
        #expect(output.replacedText.isEmpty)
    }

    @Test("普通の声はエンジンに渡す")
    func speechReachesEngine() async throws {
        let engine = SpyEngine(text: "こんにちは")
        let output = try await run(
            SignalFixtures.silence(seconds: 0.5) + SignalFixtures.tone(seconds: 1, amplitude: 0.05),
            engine: engine)
        #expect(engine.callCount == 1)
        #expect(output.replacedText == "こんにちは")
    }

    /// 実測の «普通の声» の下側（RMS 0.006 前後、Issue #187）でも弾かない。
    /// 無音と取り違えて発話を捨てる方が、定型文が入るより悪い。
    @Test("小さな声（RMS ≒ 0.007）でもエンジンに渡す")
    func quietSpeechReachesEngine() async throws {
        let engine = SpyEngine(text: "はい")
        _ = try await run(SignalFixtures.tone(seconds: 0.3, amplitude: 0.01), engine: engine)
        #expect(engine.callCount == 1)
    }

    @Test("開始音の区間はエンジンに渡す音から消してある（声の部分はそのまま）")
    func startSoundIsMutedBeforeEngine() async throws {
        let engine = SpyEngine(text: "こんにちは")
        let beep = SignalFixtures.tone(seconds: 0.3, amplitude: 0.2)
        let gap = SignalFixtures.silence(seconds: 0.3)
        let voice = SignalFixtures.tone(seconds: 1, amplitude: 0.05)
        _ = try await run(beep + gap + voice, engine: engine, leadingSoundSeconds: 0.46)

        let received = try #require(engine.received.withLock { $0.first })
        #expect(received.count == beep.count + gap.count + voice.count)
        let muted = Int(0.46 * Double(SignalFixtures.sampleRate))
        #expect(received[..<muted].allSatisfy { $0 == 0 })
        #expect(Array(received[(beep.count + gap.count)...]) == voice)
    }

    @Test("無音で返った結果は履歴に残さない")
    func silentOutputIsNotRecorded() async throws {
        let output = try await run(SignalFixtures.silence(seconds: 2), engine: SpyEngine())
        #expect(!HistoryStore.shouldRecord(rawText: output.rawText, replacedText: output.replacedText))
        #expect(HistoryStore.shouldRecord(rawText: "こんにちは", replacedText: "こんにちは"))
    }
}
