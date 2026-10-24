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
