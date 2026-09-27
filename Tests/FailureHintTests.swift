import Testing
@testable import sarari

/// 失敗表示に添える手がかり（`.claude/rules/insertion-feedback.md`）。
/// **文言の文字列マッチで分岐しない**ための型なので、種類ごとの契約をここで固定する。
struct FailureHintTests {

    @Test("設定で直せる失敗にはボタンの文言が付く")
    func actionableHintHasTitle() {
        #expect(FailureHint.accessibilityPermission.actionTitle == "設定を開く")
    }

    /// パスワード欄・Secure Keyboard Entry はアプリ側から解除できない（Issue #104）。
    /// 押しても何も起きないボタンは、原因を読ませる邪魔にしかならない。
    @Test("アプリ側から直せない失敗にはボタンを出さない")
    func nonActionableHintHasNoTitle() {
        #expect(FailureHint.secureInput.actionTitle == nil)
    }

    @Test("hint は挿入結果からメニューバーの状態までそのまま運ばれる")
    func hintSurvivesPresentation() {
        let p = InsertionPresentation.make(
            outcome: .failed(reason: "パスワード欄には入力しません", hint: .secureInput),
            text: "秘密",
            showResultPanel: true,
            resultLocation: { _ in "履歴" })
        #expect(p.status.isFailed)
        guard case .failed(_, let hint) = p.status else {
            Issue.record("failed でない")
            return
        }
        #expect(hint == .secureInput)
    }
}
