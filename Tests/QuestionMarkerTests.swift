import Testing
@testable import sarari

/// 疑問符の補完（Issue #34）。付けすぎは平叙文を疑問文に変えるので「付けない」側も見る。
struct QuestionMarkerTests {

    private func apply(_ s: String) -> String { QuestionMarker.apply(s) }

    @Test("疑問の語尾の句点・無印の文末を？にする")
    func addsQuestionMark() {
        #expect(apply("ローカルでできますか") == "ローカルでできますか？")
        #expect(apply("可能性があるということでしょうか。") == "可能性があるということでしょうか？")
        #expect(apply("手伝ってもらえませんか") == "手伝ってもらえませんか？")
        #expect(apply("これで大丈夫ですか。次に進みます。") == "これで大丈夫ですか？次に進みます。")
        #expect(apply("ありますか\n次の件") == "ありますか？\n次の件")
    }

    @Test("エンジンが付けた？の前の空白を取り、？を二重にしない")
    func normalizesExistingMark() {
        #expect(apply("ショートカットキーってありますか ？") == "ショートカットキーってありますか？")
        #expect(apply("いいですか？") == "いいですか？")
    }

    @Test("疑問と言い切れない語尾・文中の語尾には付けない")
    func leavesOthers() {
        #expect(apply("まあ大丈夫かな。") == "まあ大丈夫かな。")
        #expect(apply("行きません。") == "行きません。")
        #expect(apply("そうですかね") == "そうですかね")
        #expect(apply("行けるかどうかですか、それとも") == "行けるかどうかですか、それとも")
    }
}
