import Testing
@testable import sarari

/// 録音の上限で止めた発話の見せ方（Issue #17）。
struct RecordingLimitTests {

    /// `SettingsStore.resultLocationDescription(isFailure:)` の「HUD に残す」設定と同じ返し方。
    private func make(showResultPanel: Bool = true) -> InsertionPresentation {
        InsertionPresentation.make(outcome: RecordingLimit.outcome,
                                   text: "こんにちは",
                                   showResultPanel: showResultPanel,
                                   resultLocation: RecordingLimit.resultLocation { $0 ? "クリップボード" : "HUD・履歴" })
    }

    @Test("上限で止めた発話は挿入していないので、結果パネルに残す")
    func keepsResult() {
        let p = make()
        #expect(p.status.isFailed)
        #expect(p.hud == .keepResult)
    }

    /// 上限で止めた発話はクリップボードに置かない。置いていない場所を案内すると嘘になる。
    @Test("残し先にクリップボードを案内しない")
    func doesNotPointToClipboard() throws {
        guard case .failed(let reason, let hint) = make().status else {
            Issue.record("失敗として表示されていない")
            return
        }
        #expect(reason.contains("挿入していません"))
        #expect(reason.hasSuffix("結果はHUD・履歴に残しています"))
        #expect(!reason.contains("クリップボード"))
        // アプリ側から直せる原因ではないので、設定へ飛ぶボタンは出さない。
        #expect(hint == nil)
    }

    @Test("上限は通常の発話（長くても 2〜3 分）を切らない長さ")
    func limitOutlastsSpeech() {
        #expect(RecordingLimit.maxDuration >= .seconds(300))
    }
}
