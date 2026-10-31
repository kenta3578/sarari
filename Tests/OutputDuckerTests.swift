import Foundation
import Testing
@testable import sarari

/// 録音中だけ音量を下げ、終わったら戻す判定（Issue #133）。
@MainActor
struct OutputDuckerTests {

    final class FakeOutput: OutputVolumeControl {
        var defaultUID: String? = "speaker"
        var volumes: [String: Double] = ["speaker": 0.6]
        var writable = true
        func defaultOutputUID() -> String? { defaultUID }
        func volume(of uid: String) -> Double? { volumes[uid] }
        func setVolume(_ volume: Double, of uid: String) -> Bool {
            guard writable, volumes[uid] != nil else { return false }
            volumes[uid] = volume
            return true
        }
    }

    final class FakeStore: DuckRecordStore {
        var record: OutputDucker.Record?
        func load() -> OutputDucker.Record? { record }
        func save(_ record: OutputDucker.Record?) { self.record = record }
    }

    private func make(enabled: Bool = true) -> (OutputDucker, FakeOutput, FakeStore) {
        let output = FakeOutput()
        let store = FakeStore()
        return (OutputDucker(control: output, store: store, isEnabled: { enabled }), output, store)
    }

    @Test("下げて戻すと元の音量になり、控えは消える")
    func lowersAndRestores() {
        let (ducker, output, store) = make()
        ducker.lower(after: 0)
        #expect(output.volumes["speaker"] == 0)
        #expect(store.record == .init(uid: "speaker", original: 0.6))
        ducker.restore()
        #expect(output.volumes["speaker"] == 0.6)
        #expect(store.record == nil)
    }

    @Test("設定が切りなら下げない")
    func disabledDoesNothing() {
        let (ducker, output, store) = make(enabled: false)
        ducker.lower(after: 0)
        #expect(output.volumes["speaker"] == 0.6)
        #expect(store.record == nil)
    }

    @Test("録音中に本人が音量を変えていたら、戻すときに上書きしない")
    func keepsUserChange() {
        let (ducker, output, _) = make()
        ducker.lower(after: 0)
        output.volumes["speaker"] = 0.3
        ducker.restore()
        #expect(output.volumes["speaker"] == 0.3)
    }

    @Test("もともと無音なら何もしない（戻すときに勝手に音を出さない）")
    func alreadySilent() {
        let (ducker, output, store) = make()
        output.volumes["speaker"] = 0
        ducker.lower(after: 0)
        ducker.restore()
        #expect(output.volumes["speaker"] == 0)
        #expect(store.record == nil)
    }

    @Test("録音中に出力先が変わっても、下げた装置を戻す")
    func restoresLoweredDevice() {
        let (ducker, output, _) = make()
        output.volumes["headphones"] = 0.5
        ducker.lower(after: 0)
        output.defaultUID = "headphones"
        ducker.restore()
        #expect(output.volumes["speaker"] == 0.6)
        #expect(output.volumes["headphones"] == 0.5)
    }

    @Test("書けない装置では控えを残さない")
    func unwritableLeavesNoRecord() {
        let (ducker, output, store) = make()
        output.writable = false
        ducker.lower(after: 0)
        #expect(output.volumes["speaker"] == 0.6)
        #expect(store.record == nil)
    }

    @Test("下げる前に止めたら下げない（開始音を待っている間に止めた）")
    func restoreBeforeDelayedLower() async throws {
        let (ducker, output, _) = make()
        ducker.lower(after: 0.05)
        ducker.restore()
        try await Task.sleep(for: .milliseconds(150))
        #expect(output.volumes["speaker"] == 0.6)
    }

    @Test("開始音の長さだけ待ってから下げる")
    func delayedLower() async throws {
        let (ducker, output, _) = make()
        ducker.lower(after: 0.05)
        #expect(output.volumes["speaker"] == 0.6)
        try await Task.sleep(for: .milliseconds(200))
        #expect(output.volumes["speaker"] == 0)
    }

    @Test("下げたまま落ちていたら、次の起動で戻す")
    func recoversAfterCrash() {
        let output = FakeOutput()
        output.volumes["speaker"] = 0
        let store = FakeStore()
        store.record = .init(uid: "speaker", original: 0.6)
        OutputDucker(control: output, store: store, isEnabled: { true }).recoverIfNeeded()
        #expect(output.volumes["speaker"] == 0.6)
        #expect(store.record == nil)
    }
}
