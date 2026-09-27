import Testing
@testable import sarari

/// 辞書ルールの影響の見積もり（Issue #36）。誤爆を登録前に見せるのが目的なので、それが例に出ることを見る。
struct RuleImpactTests {

    private func impact(_ from: String, _ to: String, others: [ReplacementRule] = [], texts: [String]) -> RuleImpact {
        RuleImpact.compute(rule: ReplacementRule(from: from, to: to), otherRules: others, texts: texts, fillers: nil)
    }

    @Test("出現した発話と、文が変わる発話を数える")
    func countsOccurrencesAndChanges() {
        let result = impact("ライナー", "Linear", texts: [
            "ライナーで Issue を作る",
            "ライナーノーツを読んだ",
            "今日は晴れ",
        ])
        #expect(result.occurrences == 2)
        #expect(result.changed == 2)
        #expect(result.examples.map(\.after).contains { $0.contains("Linearノーツ") })
    }

    @Test("大文字・小文字を区別せずに数える（置換と同じ）")
    func caseInsensitive() {
        #expect(impact("zen", "Zenn", texts: ["Zen のブログ"]).changed == 1)
    }

    @Test("より長い既存ルールが勝つ位置は変わらない")
    func longerRuleWins() {
        let others = [ReplacementRule(from: "バックスラッシュ", to: "\\")]
        let result = impact("スラッシュ", "/", others: others, texts: ["バックスラッシュを打つ"])
        #expect(result.occurrences == 1)
        #expect(result.changed == 0)
    }

    @Test("読みが空なら何も数えない")
    func emptyFrom() {
        #expect(impact(" ", "x", texts: ["あ"]) == RuleImpact(occurrences: 0, changed: 0, examples: []))
    }

    @Test("例は変わった箇所の前後だけを切り出す")
    func excerpt() {
        let example = RuleImpact.excerpt(
            before: "とても長い前置きの文章がここまで続いてからライナーの話をして、そのあとも長く続く文",
            after: "とても長い前置きの文章がここまで続いてからLinearの話をして、そのあとも長く続く文",
            context: 4)
        #expect(example.before == "…いてからライナーの話をし…")
        #expect(example.after == "…いてからLinearの話をし…")
    }
}
