import Testing
@testable import sarari

/// 挿入結果 → メニューバー状態と HUD の動きの導出（Issue #64。`.claude/rules/insertion-feedback.md`）。
struct InsertionPresentationTests {

    private func make(_ outcome: InsertionOutcome,
                      text: String = "こんにちは",
                      showResultPanel: Bool = true) -> InsertionPresentation {
        InsertionPresentation.make(outcome: outcome, text: text,
                                   showResultPanel: showResultPanel,
                                   resultLocation: { $0 ? "クリップボード" : "履歴" })
    }

    @Test("空テキストは無音として完了表示")
    func silence() {
        let p = make(.succeeded, text: "")
        #expect(p.status == .done(message: "（無音）"))
        #expect(p.hud == .finish)
    }

    @Test("成功は完了表示で閉じる")
    func success() {
        let p = make(.succeeded)
        #expect(p.status == .done(message: "挿入しました ✓"))
        #expect(p.hud == .finish)
    }

    @Test("失敗だけが警告色（failed）。hint はそのまま伝わる")
    func failure() {
        let p = make(.failed(reason: "権限が無い", hint: .accessibilityPermission))
        #expect(p.status == .failed(reason: "権限が無い。結果はクリップボードに残しています",
                                    hint: .accessibilityPermission))
        #expect(p.hud == .keepResult)
    }

    @Test("失敗でパネルを出さない設定なら HUD は即閉じる（Issue #44）")
    func failureWithoutPanel() {
        let p = make(.failed(reason: "x"), showResultPanel: false)
        #expect(p.status.isFailed)
        #expect(p.hud == .hide)
    }

    @Test("確認できなかっただけ（uncertain）は失敗にしない（Issue #34）")
    func uncertainIsNotFailure() {
        let p = make(.uncertain(detail: "AX で読めない"))
        #expect(!p.status.isFailed)
        // 見出しは「何が起きたか」、括弧内が「なぜ確認できないか」、末尾に結果の残し先。
        // **残し先は「履歴」。** uncertain ではクリップボードを元に戻すので、
        // 「クリップボードに残しています」と言うと嘘になる（Issue #143）。
        #expect(p.status == .done(message: "挿入しました（AX で読めない）。結果は履歴に残しています"))
        #expect(p.hud == .keepResult)
    }

    @Test("uncertain でパネルを出さない設定なら、成功と同じく一瞬見せて閉じる")
    func uncertainWithoutPanel() {
        let p = make(.uncertain(detail: "x"), showResultPanel: false)
        #expect(p.hud == .finish)
    }

    /// Issue #143 の芯。ターミナルでは `.uncertain` が常態（実測 411 件中 409 件）なので、
    /// ここで失敗と同じ扱いをすると毎回クリップボードが壊れる。
    @Test("失敗と uncertain で結果の残し先が変わる")
    func locationDependsOnFailure() {
        let uncertain = make(.uncertain(detail: "x"))
        let failed = make(.failed(reason: "貼れませんでした"))
        #expect(uncertain.status == .done(message: "挿入しました（x）。結果は履歴に残しています"))
        #expect(failed.status == .failed(reason: "貼れませんでした。結果はクリップボードに残しています"))
    }

    /// 整形（#131 で削除）を通していた頃は、成功でも `.warned` に落ちる経路があった。
    /// いまは**確定した失敗だけが警告色**という不変条件が残っている。
    @Test("成功と uncertain は決して warned にならない",
          arguments: [InsertionOutcome.succeeded, .uncertain(detail: "x")])
    func neverWarnsOnNonFailure(outcome: InsertionOutcome) {
        if case .warned = make(outcome).status {
            Issue.record("成功・uncertain で warned になった")
        }
    }
}
