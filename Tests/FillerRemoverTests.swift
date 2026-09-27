import Foundation
import Testing
@testable import sarari

/// フィラー除去（Issue #59 / #82）。消しすぎはそのままカーソルに入るので「残す」側を重点的に見る。
struct FillerRemoverTests {

    private func apply(_ s: String) -> String { FillerRemover.apply(s) }

    @Test("どこにあっても消える語")
    func anywhere() {
        #expect(apply("えっと、明日は休みです") == "明日は休みです")
        #expect(apply("明日はえーと休みです") == "明日は休みです")
    }

    @Test("境界の語は文頭・読点直後・文末で消える")
    func boundary() {
        #expect(apply("あの、ありがとう") == "ありがとう")
        #expect(apply("行けるけど、まあ。全然") == "行けるけど、全然")
        #expect(apply("だった。あの。") == "だった。")
    }

    @Test("指示語・連語は残す（あの人・そのため・そのまま）")
    func keepsDemonstratives() {
        #expect(apply("あの人に頼む") == "あの人に頼む")
        #expect(apply("そのため遅れました") == "そのため遅れました")
        #expect(apply("そのまま送って") == "そのまま送って")
        #expect(apply("なんかあったら連絡して") == "なんかあったら連絡して")
    }

    @Test("語の左が境界でなければ消さない（「問題はその。」）")
    func leftBoundaryRequired() {
        #expect(apply("問題はその。") == "問題はその。")
    }

    @Test("1 文字の語（で）は読点を伴うときだけ消し、「でも」は崩さない")
    func shortWordNeedsComma() {
        #expect(apply("で、明日ですが") == "明日ですが")
        #expect(apply("でも行きます") == "でも行きます")
    }

    @Test("残骸の掃除: 連続読点・文頭読点・末尾の語")
    func cleanup() {
        #expect(apply("えっと、、明日") == "明日")
        #expect(apply("明日です。えっと。") == "明日です。")
    }

    @Test("数値・URL・英単語には触れない")
    func leavesNonKana() {
        let s = "https://example.com/a?b=1 の 4,217 円を pay"
        #expect(apply(s) == s)
    }

    @Test("空文字はそのまま。空のフィラー表でも壊れない")
    func edges() {
        #expect(apply("") == "")
        #expect(FillerRemover.apply("えっと、明日", fillers: FillerList(anywhere: [], atBoundary: [])) == "えっと、明日")
    }

    @Test("FillerList は JSON 往復で等しい")
    func codable() throws {
        let data = try JSONEncoder().encode(FillerList.default)
        #expect(try JSONDecoder().decode(FillerList.self, from: data) == FillerList.default)
    }
}
