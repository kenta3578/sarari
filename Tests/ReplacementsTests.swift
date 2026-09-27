import Foundation
import Testing
@testable import sarari

/// 辞書置換の 1 パス最長一致（`ReplacementStore.apply`）。ファイルは触らず static 版だけを使う。
@MainActor
struct ReplacementsTests {

    private let rules = ReplacementStore.defaultRules

    @Test("同梱ルールが素直に効く")
    func defaults() {
        #expect(ReplacementStore.apply("メールはfooアットマークexampleドットコム", rules: rules)
                == "メールはfoo@example.com")
    }

    @Test("最長一致: バックスラッシュ が スラッシュ に食われない（Issue #82）")
    func longestMatchWins() {
        #expect(ReplacementStore.apply("バックスラッシュ", rules: rules) == "\\")
        #expect(ReplacementStore.apply("スラッシュ", rules: rules) == "/")
    }

    @Test("置換結果が後続ルールに再マッチしない（1 パス）")
    func noChaining() {
        let chain = [ReplacementRule(from: "あ", to: "い"), ReplacementRule(from: "い", to: "う")]
        #expect(ReplacementStore.apply("あい", rules: chain) == "いう")
    }

    @Test("大文字小文字を区別しない")
    func caseInsensitive() {
        let r = [ReplacementRule(from: "github", to: "GitHub")]
        #expect(ReplacementStore.apply("GITHUB と Github", rules: r) == "GitHub と GitHub")
    }

    @Test("from が空のルールは無視し、ルールが無ければ入力をそのまま返す")
    func emptyRules() {
        #expect(ReplacementStore.apply("そのまま", rules: [ReplacementRule(from: "", to: "x")]) == "そのまま")
        #expect(ReplacementStore.apply("そのまま", rules: []) == "そのまま")
    }

    @Test("同長のルールはリストの順序に依らず同じ結果になる")
    func deterministicTieBreak() {
        let r = [ReplacementRule(from: "ab", to: "1"), ReplacementRule(from: "ac", to: "2")]
        #expect(ReplacementStore.apply("ac ab", rules: r) == "2 1")
        #expect(ReplacementStore.apply("ac ab", rules: r.reversed()) == "2 1")
    }

    @Test("取り込み: 同じ読みは大文字小文字を問わず飛ばし、既存ルールは変えない（Issue #13）")
    func importSkipsDuplicates() throws {
        let existing = [ReplacementRule(from: "GitHub", to: "ギットハブ（自分の書き方）")]
        let data = Data(#"[{"from":"github","to":"GitHub"},{"from":"イシュー","to":"Issue"},{"from":"イシュー","to":"issue"},{"from":"","to":"x"}]"#.utf8)
        let result = try ReplacementStore.importRules(from: data, into: existing)
        #expect(result.added.map(\.from) == ["イシュー"])
        #expect(result.added.first?.to == "Issue")
        #expect(result.skipped == 2)
        #expect(existing.first?.to == "ギットハブ（自分の書き方）")
    }

    @Test("取り込み: 壊れた JSON は 1 件も足さずに投げる")
    func importRejectsBrokenJSON() {
        #expect(throws: (any Error).self) {
            try ReplacementStore.importRules(from: Data(#"[{"from":"a","to":"b"},"#.utf8), into: [])
        }
        #expect(throws: (any Error).self) {
            try ReplacementStore.importRules(from: Data(#"{"from":"a","to":"b"}"#.utf8), into: [])
        }
    }

    /// 配布用の語彙セット（`presets/engineer.json`）。アプリには同梱しない。
    private static let engineerPresetURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("presets/engineer.json")

    @Test("エンジニア用語セット: 取り込むと崩れた「プルリクエスト」が PR になる")
    func engineerPresetFixesPullRequest() throws {
        let rules = try ReplacementStore.importRules(
            from: Data(contentsOf: Self.engineerPresetURL), into: []).added
        #expect(ReplacementStore.apply("プロリクエストを出しました", rules: rules) == "PRを出しました")
        #expect(ReplacementStore.apply("プルリクエストをレビューして", rules: rules) == "PRをレビューして")
        #expect(ReplacementStore.apply("プルリクを出す", rules: rules) == "PRを出す")
    }

    @Test("エンジニア用語セット: 読みの重複が無く、一般の語を壊さない（Issue #82 と同じ基準）")
    func engineerPresetDoesNotBreakCommonWords() throws {
        let data = try Data(contentsOf: Self.engineerPresetURL)
        let result = try ReplacementStore.importRules(from: data, into: [])
        #expect(result.skipped == 0)
        #expect(!result.added.isEmpty)
        // 部分一致で当たりそうなカタカナ語を含む、エンジニア用語を含まない文。
        let untouched = [
            "ギターを弾いてティッシュを取った",
            "リアクションとアクションの違い",
            "ブランチを食べてからプールに行く",
            "ユーザーにアイスとエーデルワイスを渡す",
            "シーズン中にドッグランとドックへ行く",
            "パイの実とスイフトな対応",
            "プルーンとプロジェクトとリクエスト",
            "クロワッサンとクロールで泳ぐ",
            "エースがシーソーでエスカレーターに乗る",
            "ジェット機とタイプとスクリプト",
        ]
        for sentence in untouched {
            #expect(ReplacementStore.apply(sentence, rules: result.added) == sentence)
        }
    }

    @Test("JSON は from / to だけを持ち、id は永続化しない")
    func codable() throws {
        let data = try JSONEncoder().encode([ReplacementRule(from: "a", to: "b")])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"from\""))
        #expect(!json.contains("\"id\""))
        let decoded = try JSONDecoder().decode([ReplacementRule].self, from: data)
        #expect(decoded.first?.from == "a")
        #expect(decoded.first?.to == "b")
    }
}
