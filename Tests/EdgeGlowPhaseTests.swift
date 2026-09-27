import Testing
@testable import sarari

/// 画面の縁の光が、どの状態で何を見せるか（Issue #48）。
struct EdgeGlowPhaseTests {
    @Test func 録音から挿入までの流れだけ光る() {
        #expect(EdgeGlowPhase.phase(for: .recording) == .recording)
        #expect(EdgeGlowPhase.phase(for: .processing) == .processing)
        #expect(EdgeGlowPhase.phase(for: .done(message: "挿入しました")) == .done)
    }

    @Test func 待機_警告_失敗では光らない() {
        #expect(EdgeGlowPhase.phase(for: .idle) == .off)
        #expect(EdgeGlowPhase.phase(for: .loadingModel(step: "読み込み中")) == .off)
        #expect(EdgeGlowPhase.phase(for: .warned(message: "注意")) == .off)
        #expect(EdgeGlowPhase.phase(for: .failed(reason: "失敗")) == .off)
    }

    @Test func 明滅するのは録音中と文字起こし中だけで_文字起こし中の方が速い() throws {
        let recording = try #require(EdgeGlowPhase.recording.breathHalfPeriod)
        let processing = try #require(EdgeGlowPhase.processing.breathHalfPeriod)
        #expect(processing < recording)
        #expect(EdgeGlowPhase.done.breathHalfPeriod == nil)
        #expect(EdgeGlowPhase.off.color == nil)
    }
}
