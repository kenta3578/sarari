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
}
