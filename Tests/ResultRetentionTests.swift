import Testing
@testable import sarari

/// 挿入できなかった結果の残し先（Issue #67 / #143）。
///
/// 旧 2 トグル（`showResultPanel` / `keepResultOnClipboardWhenUnsure`）を 1 つに畳んだので、
/// **既存の設定が同じ挙動のまま移ること**と、**どれを選んでも履歴には残ること**を固定する。
@MainActor
struct ResultRetentionTests {

    private typealias Retention = SettingsStore.ResultRetention

    @Test("どの選択でも履歴には必ず残る")
    func historyIsAlwaysIncluded() {
        for retention in Retention.allCases {
            #expect(retention.locations.contains("履歴"))
        }
    }

    @Test("HUD に残す選択だけが showResultPanel を立てる")
    func onlyHudShowsPanel() {
        #expect(Retention.hud.locations.contains("HUD"))
        #expect(!Retention.clipboard.locations.contains("HUD"))
        #expect(!Retention.historyOnly.locations.contains("HUD"))
    }

    @Test("クリップボードに残す選択だけがクリップボードを挙げる")
    func onlyClipboardKeepsClipboard() {
        #expect(Retention.clipboard.locations.contains("クリップボード"))
        #expect(!Retention.hud.locations.contains("クリップボード"))
        #expect(!Retention.historyOnly.locations.contains("クリップボード"))
    }

    /// UserDefaults に入る値なので、**綴りが変わると設定が黙って既定へ戻る**。
    @Test("保存される値が変わっていない")
    func rawValuesAreStable() {
        #expect(Retention.hud.rawValue == "hud")
        #expect(Retention.clipboard.rawValue == "clipboard")
        #expect(Retention.historyOnly.rawValue == "historyOnly")
    }

    @Test("選択肢はちょうど 3 つで、すべて文言を持つ")
    func everyCaseHasLabel() {
        #expect(Retention.allCases.count == 3)
        #expect(Retention.allCases.allSatisfy { !$0.label.isEmpty })
    }
}
