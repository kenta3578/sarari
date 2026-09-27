import Foundation
import Testing
@testable import sarari

/// 設定ファイルを外で編集したときの読み直しと、外の編集を踏まない書き込み（Issue #7）。
/// 監視（DispatchSource）自体は実機で確かめる。ここは読み書きの判定だけ。
@MainActor
struct JSONFileSyncTests {

    private struct Sample: Codable, Equatable {
        var words: [String]
    }

    private let url: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sarari-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("sample.json")

    private func writeExternally(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("ファイルが無ければ既定値を返し、書き出せる")
    func missingFileUsesDefault() throws {
        let sync = JSONFileSync<Sample>(url: url)
        #expect(sync.loadAtStartup(default: Sample(words: ["既定"])) == Sample(words: ["既定"]))
        guard case .written = sync.write(Sample(words: ["既定"])) else { Issue.record("書けなかった"); return }
        #expect(sync.fileExists)
    }

    @Test("自分で書いた内容は «変化» として拾わない")
    func ownWriteIsUnchanged() {
        let sync = JSONFileSync<Sample>(url: url)
        _ = sync.write(Sample(words: ["あの"]))
        guard case .unchanged = sync.readIfChanged() else { Issue.record("自分の書き込みを変化と見なした"); return }
    }

    @Test("外で書き換えたら読み直せる")
    func externalEditIsPickedUp() throws {
        let sync = JSONFileSync<Sample>(url: url)
        _ = sync.write(Sample(words: ["あの"]))
        try writeExternally(#"{ "words": ["あの", "えっと"] }"#)
        guard case .changed(let value) = sync.readIfChanged() else { Issue.record("読み直さなかった"); return }
        #expect(value == Sample(words: ["あの", "えっと"]))
        // 読み直した内容はもう «変化» ではない。
        guard case .unchanged = sync.readIfChanged() else { Issue.record("同じ内容を二度読んだ"); return }
    }

    @Test("外で壊れた JSON を保存しても、退避せず理由を返す")
    func brokenExternalEditIsReported() throws {
        let sync = JSONFileSync<Sample>(url: url)
        _ = sync.write(Sample(words: ["あの"]))
        try writeExternally(#"{ "words": ["あの", "#)
        guard case .broken = sync.readIfChanged() else { Issue.record("壊れた JSON を読めたことにした"); return }
        // 実行中は退避しない（直している最中のファイルを動かさない）。
        #expect(sync.fileExists)
    }

    @Test("外で編集された直後の書き込みは、外の編集を踏まずに止まる")
    func writeDoesNotClobberExternalEdit() throws {
        let sync = JSONFileSync<Sample>(url: url)
        _ = sync.write(Sample(words: ["あの"]))
        let external = #"{ "words": ["外で足した"] }"#
        try writeExternally(external)
        guard case .conflict = sync.write(Sample(words: ["画面で足した"])) else { Issue.record("上書きした"); return }
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
        // 読み直したあとなら書ける。
        _ = sync.readIfChanged()
        guard case .written = sync.write(Sample(words: ["画面で足した"])) else { Issue.record("読み直し後に書けない"); return }
    }

    @Test("起動時に壊れていたら退避して既定値に戻す（従来どおり）")
    func brokenAtStartupIsBackedUp() throws {
        try writeExternally("not json")
        let sync = JSONFileSync<Sample>(url: url)
        #expect(sync.loadAtStartup(default: Sample(words: [])) == Sample(words: []))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("broken").path))
        #expect(!sync.fileExists)
    }
}
