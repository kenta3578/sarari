import CryptoKit
import Foundation
import Testing
@testable import sarari

/// モデル重みとトークナイザの照合（Issue #106）。**実モデル（約630MB）は使わない。**
/// 一時ディレクトリに小さなファイルを置いて、判定そのものを確かめる。
struct ModelIntegrityTests {

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarari-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// 中身から期待値を作る（テスト側でハッシュを手書きしない）。
    private func entry(for data: Data, at path: String) -> ModelIntegrity.Entry {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(path: path, sha256: hex, size: data.count)
    }

    private func write(_ data: Data, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test("一致すれば通る（入れ子のファイルも）")
    func matchingPasses() throws {
        try withTempDirectory { dir in
            let a = Data("sarari".utf8)
            let b = Data("weights".utf8)
            try write(a, "a.bin", in: dir)
            try write(b, "Model.mlmodelc/weights/weight.bin", in: dir)
            try ModelIntegrity.verify(directory: dir, entries: [
                entry(for: a, at: "a.bin"),
                entry(for: b, at: "Model.mlmodelc/weights/weight.bin"),
            ])
        }
    }

    @Test("ファイルが無ければ落ちる")
    func missingFails() throws {
        try withTempDirectory { dir in
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(
                    directory: dir,
                    entries: [.init(path: "無い.bin", sha256: String(repeating: "0", count: 64), size: 1)])
            }
        }
    }

    @Test("サイズが違えば落ちる")
    func sizeMismatchFails() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            try write(data, "a.bin", in: dir)
            let base = entry(for: data, at: "a.bin")
            let wrong = ModelIntegrity.Entry(path: base.path, sha256: base.sha256, size: base.size + 1)
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir, entries: [wrong])
            }
        }
    }

    /// **サイズを保ったまま中身だけ差し替える**のが、この検証で捕まえたい形。
    @Test("サイズが同じでも中身が違えば落ちる")
    func digestMismatchFails() throws {
        try withTempDirectory { dir in
            let original = Data("sarari".utf8)
            let tampered = Data("sararI".utf8)  // 同じ長さ
            try write(tampered, "a.bin", in: dir)
            let expected = entry(for: original, at: "a.bin")
            #expect(expected.size == tampered.count)
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir, entries: [expected])
            }
        }
    }

    /// 完了条件「照合済みのあとにファイルが変わったら検出される」。
    /// 以前は一度通ると印を残し、以後はファイルを読まずに通していた。
    @Test("一度通ったあとにファイルが変わったら、次の照合で落ちる")
    func detectsChangeAfterSuccessfulVerification() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            try write(data, "a.bin", in: dir)
            let entries = [entry(for: data, at: "a.bin")]
            try ModelIntegrity.verify(directory: dir, entries: entries)
            try ModelIntegrity.verify(directory: dir, entries: entries)

            try write(Data("SARARI".utf8), "a.bin", in: dir)  // 同じ長さで中身だけ変える
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir, entries: entries)
            }
        }
    }

    /// 読み込む側はディレクトリの中をファイル名で探す（例: トークナイザは
    /// `chat_template.jinja` があれば読む）。**マニフェストに無いファイルは、
    /// 照合していないのに読まれうる**ので、置かれていたら通さない。
    @Test("マニフェストに無いファイルが置かれていたら落ちる")
    func unexpectedFileFails() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            try write(data, "tokenizer.json", in: dir)
            try write(Data("extra".utf8), "chat_template.jinja", in: dir)
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir, entries: [entry(for: data, at: "tokenizer.json")])
            }
        }
    }

    @Test("入れ子に足されたファイルも、マニフェストに無ければ落ちる")
    func unexpectedNestedFileFails() throws {
        try withTempDirectory { dir in
            let data = Data("weights".utf8)
            try write(data, "Model.mlmodelc/weights/weight.bin", in: dir)
            try write(Data("extra".utf8), "Model.mlmodelc/weights/.extra.bin", in: dir)
            #expect(throws: ModelIntegrity.VerificationError.self) {
                try ModelIntegrity.verify(directory: dir,
                                          entries: [entry(for: data, at: "Model.mlmodelc/weights/weight.bin")])
            }
        }
    }

    /// 取得ライブラリが置く `.cache`（取得時のメタデータ）と Finder の `.DS_Store` は
    /// 読み込みでは使われないので、照合の対象外にする。
    @Test("取得時のメタデータと .DS_Store は対象外")
    func ignoresDownloadMetadata() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            try write(data, "tokenizer.json", in: dir)
            try write(Data("{}".utf8), ".cache/huggingface/download/tokenizer.json.metadata", in: dir)
            try write(Data("x".utf8), ".DS_Store", in: dir)
            try ModelIntegrity.verify(directory: dir, entries: [entry(for: data, at: "tokenizer.json")])
        }
    }

    @Test("全ファイルが揃っているかを、中身を読まずに判定できる")
    func hasAllFiles() throws {
        try withTempDirectory { dir in
            let data = Data("sarari".utf8)
            let entries = [entry(for: data, at: "a.bin"), entry(for: data, at: "sub/b.bin")]
            #expect(!ModelIntegrity.hasAllFiles(directory: dir, entries: entries))
            try write(data, "a.bin", in: dir)
            #expect(!ModelIntegrity.hasAllFiles(directory: dir, entries: entries))
            try write(data, "sub/b.bin", in: dir)
            #expect(ModelIntegrity.hasAllFiles(directory: dir, entries: entries))
        }
    }

    /// 貼り替えミスで検証が素通りするのを防ぐ。
    @Test("同梱のモデルのマニフェストが 22 ファイルぶん揃っている")
    func bundledModelManifestIsComplete() {
        #expect(ModelIntegrity.largeV3Turbo.count == 22)
        #expect(ModelIntegrity.largeV3Turbo.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    }

    /// トークナイザの読み込み（swift-transformers の `LanguageModelConfigurationFromHub`）が
    /// 必ず読む 3 ファイル。認識結果の文字列はここで決まるので、重みと同じく照合する。
    @Test("同梱のトークナイザのマニフェストが、読み込まれる 3 ファイルを持つ")
    func bundledTokenizerManifestCoversLoadedFiles() {
        let paths = Set(ModelIntegrity.whisperLargeV3Tokenizer.map(\.path))
        #expect(paths == ["config.json", "tokenizer.json", "tokenizer_config.json"])
        #expect(ModelIntegrity.whisperLargeV3Tokenizer.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    }
}
