import Testing
@testable import sarari

/// WhisperKit のモデルを読むときの順番（Issue #106）。
///
/// - 取得（通信）は、手元にファイルが揃っていないときだけ
/// - 照合は、取得したかどうかに関わらず毎回、**読み込みより先に**
/// - 照合に落ちたら読み込まない
struct ModelLoadSequenceTests {

    /// 呼ばれた順を記録する。
    private final class Recorder {
        var steps: [String] = []
    }

    private struct Tampered: Error {}

    @Test("揃っていれば取得せず、照合してから読み込む")
    func cachedSkipsFetch() async throws {
        let rec = Recorder()
        let value = try await ModelLoadSequence.run(
            isCached: true,
            fetch: { rec.steps.append("fetch") },
            verify: { rec.steps.append("verify") },
            load: { rec.steps.append("load"); return 7 })
        #expect(value == 7)
        #expect(rec.steps == ["verify", "load"])
    }

    @Test("揃っていなければ取得し、照合してから読み込む")
    func missingFetchesThenVerifies() async throws {
        let rec = Recorder()
        _ = try await ModelLoadSequence.run(
            isCached: false,
            fetch: { rec.steps.append("fetch") },
            verify: { rec.steps.append("verify") },
            load: { rec.steps.append("load") })
        #expect(rec.steps == ["fetch", "verify", "load"])
    }

    @Test("照合に落ちたら読み込まない")
    func verifyFailureStopsLoad() async {
        let rec = Recorder()
        await #expect(throws: Tampered.self) {
            try await ModelLoadSequence.run(
                isCached: true,
                fetch: { rec.steps.append("fetch") },
                verify: { rec.steps.append("verify"); throw Tampered() },
                load: { rec.steps.append("load") })
        }
        #expect(rec.steps == ["verify"])
    }

    @Test("取得のあとでも、照合に落ちたら読み込まない")
    func verifyFailureAfterFetchStopsLoad() async {
        let rec = Recorder()
        await #expect(throws: Tampered.self) {
            try await ModelLoadSequence.run(
                isCached: false,
                fetch: { rec.steps.append("fetch") },
                verify: { rec.steps.append("verify"); throw Tampered() },
                load: { rec.steps.append("load") })
        }
        #expect(rec.steps == ["fetch", "verify"])
    }
}
