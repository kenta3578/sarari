import CryptoKit
import Foundation
import Testing
@testable import sarari

/// モデル重みの照合（Issue #106）。**実モデル（約630MB）は使わない。**
/// 一時ディレクトリに小さなファイルを置いて、判定そのものを確かめる。
struct ModelIntegrityTests {

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarari-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// 「検証済み」の記録が実際の設定を汚さないよう、テスト専用の suite を使う。
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sarari.tests.\(UUID().uuidString)")!
    }

    /// 中身から期待値を作る（テスト側でハッシュを手書きしない）。
    private func entry(for data: Data, at path: String) -> ModelIntegrity.Entry {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(path: path, sha256: hex, size: data.count)
    }

    @Test("一致すれば通る")
    func matchingPasses() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            try data.write(to: dir.appendingPathComponent("a.bin"))
            try ModelIntegrity.verify(directory: dir,
                                      entries: [entry(for: data, at: "a.bin")],
                                      defaults: scratchDefaults())
        }
    }

    @Test("ファイルが無ければ落ちる")
    func missingFails() throws {
        try withTempDirectory { dir in
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(
                    directory: dir,
                    entries: [.init(path: "無い.bin", sha256: String(repeating: "0", count: 64), size: 1)],
                    defaults: scratchDefaults())
            }
        }
    }

    /// サイズを先に見るのは、数百 MB を読まずに落とすため。
    @Test("サイズが違えば落ちる")
    func sizeMismatchFails() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            try data.write(to: dir.appendingPathComponent("a.bin"))
            let base = entry(for: data, at: "a.bin")
            let wrong = ModelIntegrity.Entry(path: base.path, sha256: base.sha256, size: base.size + 1)
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir, entries: [wrong], defaults: scratchDefaults())
            }
        }
    }

    /// **サイズを保ったまま中身だけ差し替える**のが、この検証で捕まえたい形。
    @Test("サイズが同じでも中身が違えば落ちる")
    func digestMismatchFails() throws {
        try withTempDirectory { dir in
            let original = Data("sarari".utf8)
            let tampered = Data("sararI".utf8)  // 同じ長さ
            try tampered.write(to: dir.appendingPathComponent("a.bin"))
            let expected = entry(for: original, at: "a.bin")
            #expect(expected.size == tampered.count)
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir, entries: [expected], defaults: scratchDefaults())
            }
        }
    }

    /// 一度通ったら読み飛ばすが、**マニフェストを差し替えたら必ず再検証**されること。
    @Test("同じマニフェストなら 2 回目は読み飛ばし、変えれば読み直す")
    func revalidatesWhenManifestChanges() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            let url = dir.appendingPathComponent("a.bin")
            try data.write(to: url)
            let defaults = scratchDefaults()
            let entries = [entry(for: data, at: "a.bin")]
            try ModelIntegrity.verify(directory: dir, entries: entries, defaults: defaults)

            // 記録があるので、中身を壊しても同じマニフェストなら通ってしまう（＝読み飛ばし）。
            try Data("SARARI".utf8).write(to: url)
            try ModelIntegrity.verify(directory: dir, entries: entries, defaults: defaults)

            // マニフェストを変えれば版が変わるので、今度は読み直して落ちる。
            let other = [ModelIntegrity.Entry(path: "a.bin",
                                              sha256: String(repeating: "a", count: 64),
                                              size: data.count)]
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir, entries: other, defaults: defaults)
            }
        }
    }

    @Test("マニフェストを 1 文字でも変えれば版が変わる")
    func manifestDigestChanges() {
        let a = [ModelIntegrity.Entry(path: "a", sha256: "aa", size: 1)]
        let b = [ModelIntegrity.Entry(path: "a", sha256: "ab", size: 1)]
        #expect(ModelIntegrity.manifestDigest(a) != ModelIntegrity.manifestDigest(b))
    }

    @Test("版は並び順に依存しない")
    func manifestDigestIsOrderIndependent() {
        let a = [ModelIntegrity.Entry(path: "a", sha256: "aa", size: 1),
                 ModelIntegrity.Entry(path: "b", sha256: "bb", size: 2)]
        #expect(ModelIntegrity.manifestDigest(a) == ModelIntegrity.manifestDigest(a.reversed()))
    }

    /// 貼り替えミスで検証が素通りするのを防ぐ。
    @Test("同梱のマニフェストが 22 ファイルぶん揃っている")
    func bundledManifestIsComplete() {
        #expect(ModelIntegrity.largeV3Turbo.count == 22)
        #expect(ModelIntegrity.largeV3Turbo.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    }
}
