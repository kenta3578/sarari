import Testing
@testable import sarari

/// 辞書置換の候補（Issue #40）。別の語を候補にしない側（ポスト→テスト 等）を重点的に見る。
struct RuleSuggesterTests {

    /// `word` を `n` 回含む履歴を作る。
    private func texts(_ pairs: [(String, Int)]) -> [String] {
        pairs.flatMap { word, n in Array(repeating: "\(word) の話", count: n) }
    }

    private func suggest(_ pairs: [(String, Int)], excluding: Set<String> = []) -> [String] {
        RuleSuggester.suggest(texts: texts(pairs), excluding: excluding).map { "\($0.from)→\($0.to)" }
    }

    @Test("英字の 1 文字違いを拾う")
    func latin() {
        #expect(suggest([("GitHub", 10), ("HitHub", 1)]) == ["HitHub→GitHub"])
    }

    @Test("カタカナは同じ行の置換と、軽い文字の出し入れを拾う")
    func kana() {
        #expect(suggest([("ブランチ", 10), ("プランチ", 1)]) == ["プランチ→ブランチ"])
        #expect(suggest([("ドキュメント", 10), ("ドッキュメント", 1)]) == ["ドッキュメント→ドキュメント"])
        #expect(suggest([("ドメイン", 10), ("ダメイン", 1)]) == ["ダメイン→ドメイン"])
    }

    @Test("行をまたぐ置換・重い文字の出し入れは別の語として拾わない")
    func differentWords() {
        #expect(suggest([("テスト", 10), ("ポスト", 1)]).isEmpty)
        #expect(suggest([("ルール", 10), ("メール", 1)]).isEmpty)
        #expect(suggest([("クロード", 10), ("ロード", 1)]).isEmpty)
    }

    @Test("3 文字以下の英字・頻度の差が小さいもの・登録済みは出さない")
    func thresholds() {
        #expect(suggest([("OSS", 10), ("CSS", 1)]).isEmpty)
        #expect(suggest([("GitHub", 2), ("HitHub", 1)]).isEmpty)
        #expect(suggest([("GitHub", 10), ("HitHub", 1)], excluding: ["hithub"]).isEmpty)
    }

    @Test("大文字小文字だけの違いは候補にしない")
    func caseOnly() {
        #expect(suggest([("GitHub", 10), ("github", 1)]).isEmpty)
    }
}
