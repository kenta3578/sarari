import Testing
@testable import sarari

/// 世代番号ガード（Issue #97 / #100）の判定。実モデルもタイマーも使わず、追い越しの順序を手で組む。
struct PipelineGuardTests {

    private let failed = AppStatus.failed(reason: "挿入できませんでした")
    /// 控えるときに前置きが付くので、期待値もそちらで作る。
    private var deferredFailed: AppStatus { failed.prefixed(PipelineGuard.deferredLabel) }

    @Test("begin は世代を進め、その世代は現行として扱われる")
    func beginAdvancesGeneration() {
        var g = PipelineGuard()
        let a = g.begin()
        #expect(a == 1)
        #expect(!g.isSuperseded(a))
        let b = g.begin()
        #expect(b == 2)
        #expect(g.isSuperseded(a))
        #expect(!g.isSuperseded(b))
    }

    @Test("世代 A の処理中に B が始まると、A の「結果を残す」表示は控えられる")
    func supersededKeepResultIsDeferred() {
        var g = PipelineGuard()
        let a = g.begin()
        _ = g.begin()  // B が始まった

        let completion = g.finish(generation: a, status: failed, hud: .keepResult,
                                  text: "言い残し", outcome: .failed(reason: "x"))
        #expect(completion == .superseded)
        #expect(g.deferred == [PipelineGuard.Deferred(
            status: deferredFailed,
            result: .init(text: "言い残し", outcome: .failed(reason: "x")))])
    }

    @Test("控えた状態文には「以前の発話」が前置きされ、今の発話と混ざらない")
    func deferredStatusIsPrefixed() {
        var g = PipelineGuard()
        let a = g.begin()
        _ = g.begin()
        _ = g.fail(generation: a, status: .failed(reason: "文字起こし失敗"))

        // 前置きは表示文（reason）側に入る。accessibilityLabel は状態の種別を読むだけなので見ない。
        guard case .failed(let reason, _) = g.deferred.first?.status else {
            Issue.record("控えた状態が failed でない")
            return
        }
        #expect(reason.hasPrefix(PipelineGuard.deferredLabel))
        #expect(reason.contains("文字起こし失敗"))
    }

    @Test("追い越された成功は控えない。挿入された文字が見えているので失うものが無い")
    func supersededSuccessIsDropped() {
        var g = PipelineGuard()
        let a = g.begin()
        _ = g.begin()

        let completion = g.finish(generation: a, status: .done(message: "挿入しました ✓"),
                                  hud: .finish, text: "ok", outcome: .succeeded)
        #expect(completion == .superseded)
        #expect(g.deferred.isEmpty)
    }

    @Test("追い越された挿入失敗は、結果パネルを出さない設定（hide）でも状態だけ控える")
    func supersededHiddenFailureIsDeferred() {
        var g = PipelineGuard()
        let a = g.begin()
        _ = g.begin()

        let completion = g.finish(generation: a, status: failed, hud: .hide,
                                  text: "言い残し", outcome: .failed(reason: "x"))
        #expect(completion == .superseded)
        #expect(g.deferred == [PipelineGuard.Deferred(status: deferredFailed, result: nil)])
    }

    @Test("追い越された文字起こし失敗は必ず控える（結果テキストは無い）")
    func supersededFailureIsDeferred() {
        var g = PipelineGuard()
        let a = g.begin()
        _ = g.begin()

        let status = AppStatus.failed(reason: "文字起こし失敗")
        #expect(g.fail(generation: a, status: status) == .superseded)
        #expect(g.deferred == [PipelineGuard.Deferred(
            status: status.prefixed(PipelineGuard.deferredLabel), result: nil)])
    }

    @Test("次のパイプラインが完了表示なら、控えた結果を代わりに出してキューから抜ける")
    func currentFinishReplaysDeferred() {
        var g = PipelineGuard()
        let a = g.begin()
        let b = g.begin()
        _ = g.finish(generation: a, status: failed, hud: .keepResult,
                     text: "A", outcome: .failed(reason: "x"))

        let completion = g.finish(generation: b, status: .done(message: "ok"),
                                  hud: .finish, text: "B", outcome: .succeeded)
        #expect(completion == .present(replay: PipelineGuard.Deferred(
            status: deferredFailed, result: .init(text: "A", outcome: .failed(reason: "x")))))
        #expect(g.deferred.isEmpty)
    }

    @Test("B 自身も結果を残す表示なら新しい方を優先し、A の退避は取り出さない")
    func currentKeepResultDoesNotReplay() {
        var g = PipelineGuard()
        let a = g.begin()
        let b = g.begin()
        _ = g.finish(generation: a, status: failed, hud: .keepResult,
                     text: "A", outcome: .failed(reason: "x"))

        let completion = g.finish(generation: b, status: failed, hud: .keepResult,
                                  text: "B", outcome: .failed(reason: "y"))
        #expect(completion == .present(replay: nil))
        #expect(g.deferred.first?.result?.text == "A")
    }

    @Test("現行世代の失敗は replay を伴わない（失敗表示を前の結果で潰さない）")
    func currentFailureDoesNotReplay() {
        var g = PipelineGuard()
        let a = g.begin()
        let b = g.begin()
        _ = g.fail(generation: a, status: failed)

        #expect(g.fail(generation: b, status: .failed(reason: "B 失敗")) == .present(replay: nil))
        #expect(g.deferred.first?.status == deferredFailed)
    }

    @Test("take は控えた結果を古い順に 1 件返す（録音破棄時に「閉じる代わりに出す」）")
    func takeDrainsInOrder() {
        var g = PipelineGuard()
        let a = g.begin()
        _ = g.begin()
        _ = g.fail(generation: a, status: failed)

        #expect(g.take()?.status == deferredFailed)
        #expect(g.take() == nil)
    }

    /// Issue #100 の芯。単一スロットだと 3 世代重なったときに最初の失敗が黙って消える。
    @Test("3 世代の追い越しでも前の退避は上書きされず、古い順に出る")
    func queueKeepsEveryDeferred() {
        var g = PipelineGuard()
        let a = g.begin()
        let b = g.begin()
        _ = g.begin()
        _ = g.finish(generation: a, status: failed, hud: .keepResult, text: "A", outcome: .failed(reason: "a"))
        _ = g.finish(generation: b, status: failed, hud: .keepResult, text: "B", outcome: .failed(reason: "b"))

        #expect(g.deferred.count == 2)
        #expect(g.take()?.result?.text == "A")
        #expect(g.take()?.result?.text == "B")
        #expect(g.take() == nil)
    }
}
