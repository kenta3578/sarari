import Foundation
import Testing
@testable import sarari

/// 文字起こし → 辞書置換 → フィラー除去（Issue #66 / #102）。
/// **実モデルを使わない。** フェイクのエンジンと固定した時計で、順序と計時だけを確かめる。
struct DictationPipelineTests {

    /// 与えた文字列をそのまま返すエンジン。`error` を持たせれば投げる。
    private struct FakeEngine: SpeechEngine {
        var text: String = ""
        var error: (any Error)?
        func load() async throws {}
        func unload() async {}
        func transcribe(_ samples: [Float]) async throws -> String {
            if let error { throw error }
            return text
        }
    }

    private struct Boom: Error {}

    /// 呼ばれるたびに 0ms, 100ms, 250ms … と進む時計。
    private final class FakeClock: @unchecked Sendable {
        private let base = Date(timeIntervalSince1970: 0)
        private var offsets: [TimeInterval]
        private var index = 0
        init(_ offsets: [TimeInterval]) { self.offsets = offsets }
        func now() -> Date {
            defer { index += 1 }
            return base.addingTimeInterval(offsets[min(index, offsets.count - 1)])
        }
    }

    private let rule = ReplacementRule(from: "アットマーク", to: "@")

    @Test("生テキストは上書きせず、置換後と両方を返す")
    func keepsRawAndReplaced() async throws {
        let output = try await DictationPipeline.run(
            samples: [],
            engine: FakeEngine(text: "メールはテスト アットマーク example.com です"),
            rules: [rule],
            fillers: nil)

        #expect(output.rawText == "メールはテスト アットマーク example.com です")
        #expect(output.replacedText == "メールはテスト @ example.com です")
    }

    /// 逆順にすると「アットマーク」の「まあ」がフィラーとして落ちて置換に当たらなくなる。
    @Test("辞書置換がフィラー除去より先に走る")
    func replacementRunsBeforeFillerRemoval() async throws {
        let output = try await DictationPipeline.run(
            samples: [],
            engine: FakeEngine(text: "えーと アットマーク を入れて"),
            rules: [rule],
            fillers: .default)

        #expect(output.replacedText.contains("@"))
        #expect(!output.replacedText.contains("えーと"))
    }

    @Test("fillers が nil ならフィラー除去そのものを飛ばす（設定 OFF）")
    func nilFillersSkipsRemoval() async throws {
        let output = try await DictationPipeline.run(
            samples: [],
            engine: FakeEngine(text: "えーと そうですね"),
            rules: [],
            fillers: nil)

        #expect(output.replacedText == "えーと そうですね")
    }

    @Test("ルールが空でも素通しする（置換しないだけで落ちない）")
    func emptyRulesPassThrough() async throws {
        let output = try await DictationPipeline.run(
            samples: [], engine: FakeEngine(text: "そのまま"), rules: [], fillers: nil)
        #expect(output.replacedText == "そのまま")
    }

    @Test("所要時間は 文字起こし / 後処理 の 2 区間に分かれて記録される")
    func durationsSplitTranscribeAndReplace() async throws {
        // now() は transcribeStart → replaceStart → replaceEnd の順に 3 回呼ばれる。
        let clock = FakeClock([0, 0.25, 0.30])
        let output = try await DictationPipeline.run(
            samples: [], engine: FakeEngine(text: "あ"), rules: [], fillers: nil,
            now: clock.now)

        #expect(output.durations.transcribeMs == 250)
        #expect(output.durations.replaceMs == 50)
    }

    @Test("文字起こしが投げたらそのまま外へ出る（呼び出し側が「文字起こし失敗」にする）")
    func transcriptionErrorPropagates() async {
        await #expect(throws: Boom.self) {
            try await DictationPipeline.run(
                samples: [], engine: FakeEngine(error: Boom()), rules: [], fillers: nil)
        }
    }

    @Test("空の認識結果でも落ちず、空のまま返る（無音は呼び出し側で弾く）")
    func emptyTranscriptionIsFine() async throws {
        let output = try await DictationPipeline.run(
            samples: [], engine: FakeEngine(text: ""), rules: [rule], fillers: .default)
        #expect(output.rawText.isEmpty)
        #expect(output.replacedText.isEmpty)
    }
}
