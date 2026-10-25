import Foundation
import os
import Testing
@testable import sarari

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

    @Test("無音 3 秒の中に小声 0.3 秒があればエンジンに渡す（録音全体の平均で判定しない）")
    func quietSpeechInLongSilenceReachesEngine() async throws {
        let engine = SpyEngine(text: "はい")
        let samples = SignalFixtures.silence(seconds: 1.5)
            + SignalFixtures.tone(seconds: 0.3, amplitude: 0.01)
            + SignalFixtures.silence(seconds: 1.5)
        _ = try await run(samples, engine: engine)
        #expect(engine.callCount == 1)
    }

    @Test("「はい」程度の短い発話（150ms）でもエンジンに渡す")
    func shortUtteranceReachesEngine() async throws {
        let engine = SpyEngine(text: "はい")
        let samples = SignalFixtures.silence(seconds: 1)
            + SignalFixtures.tone(seconds: 0.15, amplitude: 0.01)
            + SignalFixtures.silence(seconds: 1)
        _ = try await run(samples, engine: engine)
        #expect(engine.callCount == 1)
    }

    @Test("開始音に重なって話し始めても、後ろに声が続けばエンジンに渡す")
    func speechOverlappingStartSoundReachesEngine() async throws {
        let engine = SpyEngine(text: "こんにちは")
        let samples = SignalFixtures.tone(seconds: 0.3, amplitude: 0.2)
            + SignalFixtures.tone(seconds: 1, amplitude: 0.05)
        _ = try await run(samples, engine: engine, leadingSoundSeconds: 0.46)
        #expect(engine.callCount == 1)
    }

    /// 開始音を消すのは判定のときだけ。エンジンに渡す音から消すと、開始音に重ねて話した声の頭が欠ける。
    @Test("声があれば、開始音の区間も含めて録音をそのままエンジンに渡す")
    func recordingReachesEngineUntouched() async throws {
        let engine = SpyEngine(text: "こんにちは")
        let samples = SignalFixtures.tone(seconds: 0.3, amplitude: 0.2)
            + SignalFixtures.silence(seconds: 0.3)
            + SignalFixtures.tone(seconds: 1, amplitude: 0.05)
        _ = try await run(samples, engine: engine, leadingSoundSeconds: 0.46)
        let received = try #require(engine.received.withLock { $0.first })
        #expect(received == samples)
    }

    @Test("Bluetooth の遅れで開始音が 0.3 秒遅れて入っても、開始音だけなら無音として扱う")
    func delayedStartSoundIsSilence() async throws {
        let engine = SpyEngine()
        // 0.21 秒の開始音が 0.3 秒遅れて入る（判定から外す区間を固定の 0.46 秒にすると末尾がはみ出す）。
        let samples = SignalFixtures.silence(seconds: 0.3)
            + SignalFixtures.tone(seconds: 0.21, amplitude: 0.2)
            + SignalFixtures.silence(seconds: 1.5)
        _ = try await run(samples, engine: engine,
                          leadingSoundSeconds: SilenceGate.excludedSeconds(forSoundOf: 0.21))
        #expect(engine.callCount == 0)
    }

    @Test("50ms の区切りをまたいだ短い音 1 つは無音として扱う")
    func clickAcrossWindowBoundaryIsSilence() async throws {
        let engine = SpyEngine()
        // 790 サンプル目から 20ms。窓 0 と窓 1 の両方に掛かる。
        let samples = [Float](repeating: 0, count: 790)
            + SignalFixtures.tone(seconds: 0.02, amplitude: 0.3)
            + SignalFixtures.silence(seconds: 1)
        _ = try await run(samples, engine: engine)
        #expect(engine.callCount == 0)
    }

    @Test("離れた短い音 2 つ（キーを 2 回叩いた）は無音として扱う")
    func separateClicksAreSilence() async throws {
        let engine = SpyEngine()
        let click = SignalFixtures.tone(seconds: 0.02, amplitude: 0.3)
        let samples = SignalFixtures.silence(seconds: 0.5) + click
            + SignalFixtures.silence(seconds: 1) + click + SignalFixtures.silence(seconds: 0.5)
        _ = try await run(samples, engine: engine)
        #expect(engine.callCount == 0)
    }

    @Test("無音で返った結果は履歴に残さない")
    func silentOutputIsNotRecorded() async throws {
        let output = try await run(SignalFixtures.silence(seconds: 2), engine: SpyEngine())
        #expect(!HistoryStore.shouldRecord(rawText: output.rawText, replacedText: output.replacedText))
        #expect(HistoryStore.shouldRecord(rawText: "こんにちは", replacedText: "こんにちは"))
    }
}
