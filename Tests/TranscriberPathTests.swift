import Foundation
import Testing
@testable import sarari

/// モデルの保存先（Issue #23）。**書類フォルダに置くと、壊れたときアプリが直せない。**
struct TranscriberPathTests {

    @Test("モデルは Application Support に置き、書類フォルダには置かない")
    func downloadBaseIsNotInDocuments() throws {
        let base = try #require(Transcriber.downloadBase)
        #expect(base.path.contains("/Library/Application Support/"))
        #expect(!base.path.contains("/Documents/"))
    }

    /// HubApi は `<downloadBase>/models/<repo id>/` に展開する。ここがズレると、
    /// 取得先と検証先が食い違って「あるのに無い」ことになる（切り替え前の不具合）。
    @Test("モデルのディレクトリは downloadBase から HubApi の並びで決まる")
    func modelDirectoryFollowsHubLayout() throws {
        let base = try #require(Transcriber.downloadBase)
        let directory = try #require(Transcriber.modelDirectory)
        #expect(directory.path.hasPrefix(base.path))
        #expect(directory.path.hasSuffix("models/argmaxinc/whisperkit-coreml/openai_whisper-\(Transcriber.model)"))
    }

    /// トークナイザも HubApi の並び（`<downloadBase>/models/<repo id>/`）に置かれる。
    /// WhisperKit はまずここを探すので、照合する場所と読む場所が一致する。
    @Test("トークナイザのディレクトリは downloadBase から HubApi の並びで決まる")
    func tokenizerDirectoryFollowsHubLayout() throws {
        let base = try #require(Transcriber.downloadBase)
        let directory = try #require(Transcriber.tokenizerDirectory)
        #expect(directory.path == base.appendingPathComponent("models/openai/whisper-large-v3").path)
    }

    /// 照合する組（ディレクトリとマニフェスト）。片方だけ照合しても他のテストは通ってしまうので、
    /// 組そのものを確かめる。揃っているかの判定（取得するか）も同じ組から作る。
    @Test("照合の対象はモデルとトークナイザの 2 組")
    func verificationTargetsCoverModelAndTokenizer() throws {
        let base = try #require(Transcriber.downloadBase)
        let targets = Transcriber.verificationTargets(base: base)
        #expect(targets.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: targets.map { ($0.directory.path, $0.entries.map(\.path)) })
        #expect(byPath[try #require(Transcriber.modelDirectory).path]
                == ModelIntegrity.largeV3Turbo.map(\.path))
        #expect(byPath[try #require(Transcriber.tokenizerDirectory).path]
                == ModelIntegrity.whisperLargeV3Tokenizer.map(\.path))
    }

    /// トークナイザだけ欠けているのに「揃っている」と判定すると、取得されないまま照合で落ち続ける。
    @Test("モデルが揃っていてもトークナイザが欠けていれば取得する")
    func isCachedRequiresTokenizer() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let targets = Transcriber.verificationTargets(base: base)
        let model = try #require(targets.first { $0.entries.map(\.path) == ModelIntegrity.largeV3Turbo.map(\.path) })
        for entry in model.entries {
            let url = model.directory.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        #expect(!Transcriber.isCached(base: base))

        let tokenizer = try #require(targets.first { $0.directory != model.directory })
        try FileManager.default.createDirectory(at: tokenizer.directory, withIntermediateDirectories: true)
        for entry in tokenizer.entries {
            try Data().write(to: tokenizer.directory.appendingPathComponent(entry.path))
        }
        #expect(Transcriber.isCached(base: base))
    }

    /// 完了条件「照合の対象が読み込むファイルと一致している」の、読む側の半分。
    /// 読み込みは**照合したディレクトリだけ**を指し、取得（通信）を許さない。
    /// 照合する側の半分（ディレクトリにマニフェスト外のファイルがあれば落ちる）は ModelIntegrityTests。
    @Test("読み込みは照合したディレクトリを指し、取得はしない")
    func localLoadConfigPointsAtVerifiedDirectories() throws {
        let base = try #require(Transcriber.downloadBase)
        let config = Transcriber.localLoadConfig(base: base)
        #expect(config.download == false)
        #expect(config.load == true)
        #expect(config.modelFolder == Transcriber.modelDirectory?.path)
        // WhisperKit はトークナイザを `<tokenizerFolder>/models/<repo id>/` から探す。
        let tokenizerFolder = try #require(config.tokenizerFolder)
        #expect(tokenizerFolder.appendingPathComponent("models/openai/whisper-large-v3").path
                == Transcriber.tokenizerDirectory?.path)
    }
}
